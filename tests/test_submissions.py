import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from eth_abi import encode
from eth_utils import keccak

SPEC = importlib.util.spec_from_file_location("check_hooks", Path(__file__).resolve().parents[1] / "scripts/check_hooks.py")
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)


class SubmissionBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / "sample"
        self.folder.mkdir()
        self.row = dict(schemaVersion=1, name="sample", topology="PoolBoundV4", source="Sample.sol", contract="Sample", license="MIT")
        self.save()
        (self.folder / "Sample.sol").write_text("// SPDX-License-Identifier: MIT\ncontract Sample {}\n")
        (self.folder / "review.md").write_text("Risks disclosed by contributor.\n")
        self.integration = dict(
            schemaVersion=2, kind="submission", authorId="0x1111111111111111111111111111111111111111",
            developerFeeBps=0, swapFeeModel="static", terms="No developer allocation requested.",
            bounds=dict(minimumTickSpacing=1, maximumTickSpacing=32767, maximumPositions=32,
                        maximumOracleCardinality=4096, feeModeFlags=3),
        )
        self.save_integration()

    def save_integration(self):
        (self.folder / "integration.json").write_text(json.dumps(self.integration))

    def save(self):
        (self.folder / "hook.json").write_text(json.dumps(self.row))

    def test_escape_source_rejected(self):
        self.row["source"] = "../../Sample.sol"
        self.save()
        with self.assertRaisesRegex(ValueError, "local Solidity"):
            checks.submissions(self.root)

    def test_symlink_source_rejected(self):
        source = self.folder / "Sample.sol"
        source.unlink()
        source.symlink_to(self.folder / "review.md")
        with self.assertRaisesRegex(ValueError, "regular files"):
            checks.submissions(self.root)

    def test_duplicate_fields_rejected(self):
        manifest = self.folder / "hook.json"
        manifest.write_text(manifest.read_text().replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 2'))
        with self.assertRaisesRegex(ValueError, "Duplicate JSON"):
            checks.submissions(self.root)

    def test_unknown_topology_rejected(self):
        self.row["topology"] = "ArbitraryV4"
        self.save()
        with self.assertRaisesRegex(ValueError, "Unsupported topology"):
            checks.submissions(self.root)

    def test_missing_review_rejected(self):
        (self.folder / "review.md").unlink()
        with self.assertRaisesRegex(ValueError, "review.md"):
            checks.submissions(self.root)

    def test_license_mismatch_rejected(self):
        self.row["license"] = "Apache-2.0"
        self.save()
        with self.assertRaisesRegex(ValueError, "SPDX"):
            checks.submissions(self.root)

    def test_empty_catalogue_rejected(self):
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaisesRegex(ValueError, "Empty hook catalogue"):
                checks.submissions(Path(empty))

    def test_missing_integration_rejected(self):
        (self.folder / "integration.json").unlink()
        with self.assertRaisesRegex(ValueError, "integration.json"):
            checks.submissions(self.root)

    def test_invalid_author_identity_rejected(self):
        for author in (None, "0x" + "0" * 40, "0x1234", True):
            with self.subTest(author=author):
                self.integration["authorId"] = author
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "authorId"):
                    checks.submissions(self.root)

    def test_reference_kind_cannot_bypass_author_input(self):
        self.integration.update(kind="reference", authorId=None)
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "canonical example"):
            checks.submissions(self.root)

    def test_invalid_required_developer_rates_rejected(self):
        for rate in (-1, 10000, True, 1.5, "500", None):
            with self.subTest(rate=rate):
                self.integration["developerFeeBps"] = rate
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "developerFeeBps"):
                    checks.submissions(self.root)

    def test_required_rate_boundaries_and_models_accepted(self):
        for rate in (0, 9999):
            for model in ("static", "dynamic"):
                with self.subTest(rate=rate, model=model):
                    self.integration.update(developerFeeBps=rate, swapFeeModel=model)
                    self.save_integration()
                    self.assertEqual(checks.integration_inputs(self.folder), self.integration)

    def test_invalid_or_old_integration_schema_rejected(self):
        for version in (0, 1, 3, True, "2", 2.0):
            with self.subTest(version=version):
                self.integration["schemaVersion"] = version
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "integration schemaVersion"):
                    checks.submissions(self.root)

    def test_invalid_swap_fee_models_rejected(self):
        for model in ("STATIC", "Dynamic", "", "other", 0, 1, True, None, [], {}):
            with self.subTest(model=model):
                self.integration["swapFeeModel"] = model
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "swapFeeModel"):
                    checks.submissions(self.root)

    def test_missing_author_economics_and_obsolete_ceiling_rejected(self):
        for field in ("developerFeeBps", "swapFeeModel"):
            with self.subTest(field=field):
                original = self.integration.pop(field)
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "Exact integration fields"):
                    checks.submissions(self.root)
                self.integration[field] = original
        self.integration["maximumDeveloperFeeBps"] = 500
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "Exact integration fields"):
            checks.submissions(self.root)
        del self.integration["developerFeeBps"]
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "Exact integration fields"):
            checks.submissions(self.root)

    def test_canonical_examples_accept_required_rate_but_require_null_author(self):
        for name in ("reference-bound", "dynamic-fee"):
            with self.subTest(name=name):
                reference = self.root / name
                self.folder.rename(reference)
                self.folder = reference
                self.integration.update(kind="reference", authorId=None, developerFeeBps=500)
                self.save_integration()
                self.assertEqual(checks.integration_inputs(reference)["developerFeeBps"], 500)
                self.integration["authorId"] = "0x" + "11" * 20
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "null authorId"):
                    checks.integration_inputs(reference)

    def test_candidate_environment_uses_exact_declared_rate_and_model(self):
        for kind in ("reference", "submission"):
            for rate in (0, 500, 9999):
                for model, expected in (("static", 0), ("dynamic", 1)):
                    with self.subTest(kind=kind, rate=rate, model=model):
                        self.integration.update(kind=kind, developerFeeBps=rate, swapFeeModel=model)
                        env, values = checks.candidate_environment(
                            self.integration, Path("candidate.json"), Path("fork.json"), Path("receipts.json"),
                            {"PATH": "/bin", "HOOK_MAX_DEVELOPER_BPS": "123", "HOOK_SWAP_FEE_MODEL": "123"})
                        self.assertEqual(values["HOOK_MAX_DEVELOPER_BPS"], rate)
                        self.assertEqual(values["HOOK_SWAP_FEE_MODEL"], expected)
                        self.assertEqual(env["HOOK_MAX_DEVELOPER_BPS"], str(rate))
                        self.assertEqual(env["HOOK_SWAP_FEE_MODEL"], str(expected))
                        self.assertEqual(env["PATH"], "/bin")

    def test_invalid_registry_bounds_rejected(self):
        cases = (("minimumTickSpacing", 0), ("maximumTickSpacing", 32768),
                 ("maximumPositions", 33), ("maximumOracleCardinality", 1),
                 ("maximumOracleCardinality", 4097), ("feeModeFlags", 0),
                 ("feeModeFlags", 4), ("maximumPositions", True))
        for name, value in cases:
            with self.subTest(name=name, value=value):
                original = self.integration["bounds"][name]
                self.integration["bounds"][name] = value
                self.save_integration()
                with self.assertRaisesRegex(ValueError, "bounds"):
                    checks.submissions(self.root)
                self.integration["bounds"][name] = original

    def test_reversed_tick_spacing_rejected(self):
        self.integration["bounds"].update(minimumTickSpacing=60, maximumTickSpacing=10)
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "Reversed"):
            checks.submissions(self.root)

    def test_missing_or_extra_bound_member_rejected(self):
        del self.integration["bounds"]["minimumTickSpacing"]
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "five-member"):
            checks.submissions(self.root)
        self.integration["bounds"].update(minimumTickSpacing=1, maximumHookFeePips=100)
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "five-member"):
            checks.submissions(self.root)

    def test_empty_author_terms_rejected(self):
        self.integration["terms"] = " \n "
        self.save_integration()
        with self.assertRaisesRegex(ValueError, "terms"):
            checks.submissions(self.root)

    def test_duplicate_integration_field_rejected(self):
        path = self.folder / "integration.json"
        path.write_text(path.read_text().replace('"kind": "submission"', '"kind": "reference", "kind": "submission"'))
        with self.assertRaisesRegex(ValueError, "Duplicate JSON"):
            checks.submissions(self.root)

    def test_shared_topology_rejected(self):
        self.row["topology"] = "SharedV4"
        self.save()
        with self.assertRaisesRegex(ValueError, "Unsupported topology"):
            checks.submissions(self.root)

    def test_structure_reports_do_not_claim_runtime_qualification(self):
        self.integration.update(developerFeeBps=500, swapFeeModel="dynamic")
        self.save_integration()
        output = self.root / "reports"
        rows = checks.submissions(self.root)
        output.mkdir()
        checks.write_review_reports(rows, output)
        report = json.loads((output / "sample.registration-inputs.json").read_text())
        self.assertFalse(report["admissionReady"])
        self.assertFalse(report["runtimeQualification"]["passed"])
        self.assertEqual(report["runtimeQualification"]["status"], "not-run")
        self.assertEqual(report["derivedRegistryFields"]["topology"], 2)
        self.assertEqual(report["declared"]["developerFeeBps"], 500)
        self.assertEqual(report["declared"]["swapFeeModel"], "dynamic")
        self.assertNotIn("maximumDeveloperFeeBps", report["declared"])
        self.assertEqual(report["derivedRegistryFields"]["maximumDeveloperFeeBps"], 500)
        self.assertEqual(report["sourceFileSha256"]["Sample.sol"],
                         hashlib.sha256((self.folder / "Sample.sol").read_bytes()).hexdigest())


class RegistryCodecBoundaries(unittest.TestCase):
    def test_bound_v5_schema_matches_canonical_wire_tuple(self):
        wire = "(uint16,uint24,int24,uint160,uint24,uint8,uint8,address,bool,bytes32,bytes32,bytes32,bytes32,address,uint16,(int24,int24,uint128,bytes32,uint256)[])"
        self.assertEqual(checks.codec.config_schema(5), keccak(text=wire))
        for version in (4, True, "5", 6):
            with self.subTest(version=version), self.assertRaises(ValueError):
                checks.codec.config_schema(version)

    def test_bounds_commitment_uses_five_typed_members_in_wire_order(self):
        bounds = dict(feeModeFlags=2, maximumOracleCardinality=16, maximumPositions=3,
                      maximumTickSpacing=60, minimumTickSpacing=10)
        encoded = encode(["(int24,int24,uint16,uint16,uint8)"], [(10, 60, 3, 16, 2)])
        self.assertEqual(checks.codec.encode_bounds(bounds), encoded)
        self.assertEqual(checks.codec.config_bounds_digest(bounds), keccak(encoded))


class ArtifactReconstructionBoundaries(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.solc = checks.artifacts.compiler_executable()
        except ValueError as error:
            raise unittest.SkipTest(str(error)) from error

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "Author.sol"
        self.source.write_text(
            "pragma solidity ^0.8.28; contract Author { uint256 public immutable maximum;"
            " constructor(uint256 v) { maximum = v; }"
            " function quote(uint256 x) external view returns (uint256) { return x + maximum; } }")
        compiled = self.compile("Author.sol", "Author", self.source.read_text())
        self.artifact = {"bytecode": compiled["evm"]["bytecode"],
                         "deployedBytecode": compiled["evm"]["deployedBytecode"],
                         "metadata": json.loads(compiled["metadata"])}
        self.file = self.root / "Author.json"

    def compile(self, name, contract, content):
        compiler_input = {"language": "Solidity", "sources": {name: {"content": content}}, "settings": {
            **checks.artifacts.SETTINGS,
            "outputSelection": {name: {contract: ["evm.bytecode", "evm.deployedBytecode", "metadata"]}},
        }}
        result = subprocess.run([str(self.solc), "--standard-json", "--no-import-callback"],
                                input=json.dumps(compiler_input), text=True, capture_output=True, check=True)
        return json.loads(result.stdout)["contracts"][name][contract]

    def pin(self):
        self.file.write_text(json.dumps(self.artifact))
        self.measured = checks.artifacts.artifact_evidence(self.file)
        self.pins = checks.artifacts.source_inventory(self.measured, self.root)

    def reconstruct(self):
        return checks.artifacts.reconstruct_artifact(self.measured, self.pins, root=self.root, solc=self.solc)

    def test_immutable_alias_groups_not_incidental_ast_ids(self):
        refs = self.artifact["deployedBytecode"]["immutableReferences"]
        self.artifact["deployedBytecode"]["immutableReferences"] = {str(int(key) + 10000): value for key, value in refs.items()}
        self.pin()
        proof = self.reconstruct()
        self.assertTrue(proof["creationAndRuntimeExact"])
        self.assertTrue(proof["immutableReferenceGroupsExact"])
        self.assertFalse(proof["metadataTrusted"])
        self.assertFalse(proof["importCallbackEnabled"])

    def test_self_pinned_runtime_cannot_substitute_for_rebuilt_source(self):
        raw = self.artifact["deployedBytecode"]["object"]
        self.artifact["deployedBytecode"]["object"] = raw[:-2] + ("00" if raw[-2:] != "00" else "01")
        self.pin()
        with self.assertRaisesRegex(ValueError, "bytecode/source mismatch"):
            self.reconstruct()

    def test_empty_and_fabricated_metadata_do_not_authorize_executable_bytes(self):
        self.artifact["metadata"]["sources"] = {}
        self.file.write_text(json.dumps(self.artifact))
        with self.assertRaisesRegex(ValueError, "empty compiler"):
            checks.artifacts.artifact_evidence(self.file)
        unrelated = self.root / "Unrelated.sol"
        unrelated.write_text("pragma solidity ^0.8.28; contract Unrelated { function quote() external pure returns(uint256) { return 1; } }")
        self.artifact["metadata"]["sources"] = {"Unrelated.sol": {"keccak256": "0x" + keccak(unrelated.read_bytes()).hex()}}
        self.artifact["metadata"]["settings"]["compilationTarget"] = {"Unrelated.sol": "Unrelated"}
        self.pin()
        with self.assertRaisesRegex(ValueError, "bytecode/source mismatch"):
            self.reconstruct()

    def test_changed_source_and_claimed_hash_still_require_exact_bytecode(self):
        self.source.write_text(self.source.read_text().replace("x + maximum", "x * maximum"))
        self.artifact["metadata"]["sources"]["Author.sol"]["keccak256"] = "0x" + keccak(self.source.read_bytes()).hex()
        self.pin()
        with self.assertRaisesRegex(ValueError, "bytecode/source mismatch"):
            self.reconstruct()

    def test_compiler_input_requires_sha256_not_only_metadata_keccak(self):
        self.pin()
        self.pins["Author.sol"]["sha256"] = "00" * 32
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            self.reconstruct()

    def test_artifact_cannot_borrow_a_different_reconstruction(self):
        self.pin()
        alternate = self.compile("Author.sol", "Author", self.source.read_text().replace("x + maximum", "x * maximum"))
        self.file.write_text(json.dumps({"bytecode": alternate["evm"]["bytecode"],
                                        "deployedBytecode": alternate["evm"]["deployedBytecode"],
                                        "metadata": json.loads(alternate["metadata"])}))
        with self.assertRaisesRegex(ValueError, "Artifact changed"):
            self.reconstruct()

    def test_immutable_substitution_locations_must_match(self):
        refs = self.artifact["deployedBytecode"]["immutableReferences"]
        next(iter(refs.values()))[0]["start"] += 1
        self.pin()
        with self.assertRaisesRegex(ValueError, "immutable substitution mismatch"):
            self.reconstruct()

    def test_local_source_inventory_rejects_path_escape(self):
        self.pin()
        self.measured["claimedCompilerSources"] = {"../Author.sol": self.pins["Author.sol"]["keccak256"]}
        with self.assertRaisesRegex(ValueError, "Nonlocal compiler source"):
            checks.artifacts.source_inventory(self.measured, self.root)


class ReceiptEvidenceBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "receipt.json"
        self.manifest = {"addresses": {"wrappedNative": "0x" + "11" * 20}}
        self.declared = {"developerFeeBps": 500, "swapFeeModel": "static"}
        self.receipt = {
            "schema": "abyss-hooks.launch-receipts.v1", "token": "0x" + "22" * 20,
            "poolId": "0x" + "33" * 32, "hook": "0x" + "44" * 20,
            "quoteAsset": self.manifest["addresses"]["wrappedNative"], "treasuryPaid": "10",
            "ownerPaid": "190", "authorPaid": "10", "hookFeesCollected": "200", "lpFeesCollected": "0",
            "tradeCount": 2, "developerFeeBps": 500, "authorFeeBps": 500, "swapFeeModel": 0,
            "expectedAuthorPaid": "10", "expectedOwnerPaid": "190",
        }

    def parse(self):
        self.path.write_text(json.dumps(self.receipt))
        return checks.receipt_evidence(self.path, self.manifest, self.declared)

    def test_missing_file_never_qualifies(self):
        with self.assertRaisesRegex(ValueError, "Missing real launch"):
            checks.receipt_evidence(self.path, self.manifest, self.declared)

    def test_canonical_uint256_strings_preserve_receipt_precision(self):
        amount = str(1 << 255)
        self.receipt.update(authorPaid=amount, expectedAuthorPaid=amount)
        self.assertEqual(self.parse()["authorPaid"], 1 << 255)

    def test_receipt_schema_quote_trades_and_accounting_fail_closed(self):
        for name, value in (("schema", "other"), ("quoteAsset", "0x" + "55" * 20), ("tradeCount", 1),
                            ("authorPaid", "11"), ("ownerPaid", "191"), ("developerFeeBps", 501)):
            with self.subTest(name=name):
                original = self.receipt[name]
                self.receipt[name] = value
                with self.assertRaises(ValueError):
                    self.parse()
                self.receipt[name] = original

    def test_hook_only_receipts_reject_lp_proceeds_and_missing_hook_fees(self):
        for field, value in (("lpFeesCollected", 1), ("hookFeesCollected", 0)):
            with self.subTest(field=field):
                original = self.receipt[field]
                self.receipt[field] = value
                with self.assertRaises(ValueError):
                    self.parse()
                self.receipt[field] = original

    def test_paid_and_runtime_author_rates_must_each_equal_declaration(self):
        for field in ("developerFeeBps", "authorFeeBps"):
            for rate in (0, 499, 501, 9999):
                with self.subTest(field=field, rate=rate):
                    original = self.receipt[field]
                    self.receipt[field] = rate
                    with self.assertRaisesRegex(ValueError, field):
                        self.parse()
                    self.receipt[field] = original

    def test_runtime_model_must_match_declaration(self):
        for model, expected in (("static", 0), ("dynamic", 1)):
            self.declared["swapFeeModel"] = model
            self.receipt["swapFeeModel"] = expected
            self.assertEqual(self.parse()["swapFeeModel"], expected)
            for actual in (1 - expected, 2):
                with self.subTest(model=model, actual=actual):
                    self.receipt["swapFeeModel"] = actual
                    with self.assertRaisesRegex(ValueError, "swapFeeModel"):
                        self.parse()

    def test_missing_runtime_terms_or_model_rejected(self):
        for field in ("authorFeeBps", "swapFeeModel"):
            with self.subTest(field=field):
                original = self.receipt.pop(field)
                with self.assertRaisesRegex(ValueError, f"Missing receipt field: {field}"):
                    self.parse()
                self.receipt[field] = original

    def test_zero_required_author_rate_does_not_invent_payment(self):
        self.declared["developerFeeBps"] = 0
        self.receipt.update(developerFeeBps=0, authorFeeBps=0, authorPaid="0",
                            expectedAuthorPaid="0", ownerPaid="200", expectedOwnerPaid="200")
        self.assertEqual(self.parse()["developerFeeBps"], 0)
        self.receipt["developerFeeBps"] = 500
        with self.assertRaisesRegex(ValueError, "required author rate"):
            self.parse()

    def test_runtime_terms_and_model_are_canonical_unsigned_integers(self):
        for field in ("authorFeeBps", "swapFeeModel"):
            for value in ("01", "-1", "static", True, 1.5, 1 << 256):
                with self.subTest(field=field, value=value):
                    original = self.receipt[field]
                    self.receipt[field] = value
                    with self.assertRaisesRegex(ValueError, "canonical uint256"):
                        self.parse()
                    self.receipt[field] = original

    def test_noncanonical_receipt_integers_rejected(self):
        for value in ("01", "-1", "1.0", True, 1.5, 1 << 256):
            with self.subTest(value=value):
                self.receipt["treasuryPaid"] = value
                with self.assertRaisesRegex(ValueError, "canonical uint256"):
                    self.parse()


if __name__ == "__main__":
    unittest.main()
