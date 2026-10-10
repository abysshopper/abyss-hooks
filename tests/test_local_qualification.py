import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("local_hook_checks", Path(__file__).resolve().parents[1] / "scripts/check_hooks.py")
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)
results = checks.results


class RequiredSmokeResults(unittest.TestCase):
    def rows(self, status="Success"):
        return results.result_rows({"hooks/sample/test/Smoke.t.sol:SampleSmokeTest": {
            "test_results": {"testSmokeAccounting()": {"status": status, "kind": {"Standard": {"gas": 123}}}}}})

    def test_missing_failed_and_skipped_mandatory_cases_cannot_qualify(self):
        for status in ("Failure", "Skipped"):
            with self.subTest(status=status), self.assertRaises(ValueError):
                results.validate_test_results(self.rows(status), required=["testSmokeAccounting()"], suite="SampleSmokeTest")
        with self.assertRaisesRegex(ValueError, "not executed"):
            results.validate_test_results(self.rows(), required=["testSmokeIdentity()"], suite="SampleSmokeTest")

    def test_other_suite_cannot_satisfy_required_smoke(self):
        with self.assertRaisesRegex(ValueError, "not executed"):
            results.validate_test_results(self.rows(), required=["testSmokeAccounting()"], suite="AnotherSmokeTest")

    def test_same_policy_name_in_distinct_contracts_remains_distinct(self):
        rows = self.rows() + [{**self.rows()[0], "suite": "Policy.t.sol:DifferentPolicyTest"}]
        results.validate_test_results(rows)
        with self.assertRaisesRegex(ValueError, "Duplicate named"):
            results.validate_test_results(rows + [rows[0]])

    def test_unknown_or_empty_machine_result_is_not_success(self):
        with self.assertRaisesRegex(ValueError, "Unknown test status"):
            self.rows("Unknown")
        with self.assertRaisesRegex(ValueError, "No tests"):
            results.validate_test_results([])


class SmokeInheritance(unittest.TestCase):
    def compiled(self, inherits=True, extra=False):
        base = {"nodeType": "ContractDefinition", "id": 1, "name": "HookSmokeTest", "nodes": [
            {"nodeType": "FunctionDefinition", "name": "testSmokeIdentity", "visibility": "public",
             "virtual": False, "parameters": {"parameters": []}}]}
        child = {"nodeType": "ContractDefinition", "id": 2, "name": "SampleSmokeTest", "contractKind": "contract",
                 "abstract": False, "linearizedBaseContracts": [2, 1] if inherits else [2],
                 "nodes": [{"nodeType": "FunctionDefinition", "name": "testSmokeIdentity"}] if extra else []}
        return {"sources": {
            "contracts/test/HookSmokeTest.sol": {"ast": {"nodes": [base]}},
            "hooks/sample/test/Smoke.t.sol": {"ast": {"nodes": [child]}}}}

    def verify(self, compiled):
        return checks.smoke_checks.verify_inheritance(compiled, base_path="contracts/test/HookSmokeTest.sol",
                                                      smoke_path="hooks/sample/test/Smoke.t.sol", smoke_contract="SampleSmokeTest")

    def test_unrelated_or_replacing_smoke_cannot_qualify(self):
        self.assertEqual(self.verify(self.compiled()), ["testSmokeIdentity()"])
        with self.assertRaisesRegex(ValueError, "does not inherit"):
            self.verify(self.compiled(inherits=False))
        with self.assertRaisesRegex(ValueError, "replace or overload"):
            self.verify(self.compiled(extra=True))

    def test_shared_smoke_cannot_be_virtual_or_absent(self):
        compiled = self.compiled()
        base = compiled["sources"]["contracts/test/HookSmokeTest.sol"]["ast"]["nodes"][0]
        base["nodes"][0]["virtual"] = True
        with self.assertRaisesRegex(ValueError, "nonvirtual"):
            self.verify(compiled)
        base["nodes"] = []
        with self.assertRaisesRegex(ValueError, "no required tests"):
            self.verify(compiled)

    def test_discovery_names_resolve_to_full_fuzz_signatures(self):
        abi = [{"type": "function", "name": "testFuzzBound", "inputs": [
            {"type": "int256"}, {"type": "uint32"},
            {"type": "tuple[]", "components": [{"type": "address"}, {"type": "uint256"}]}]}]
        self.assertEqual(checks.smoke_checks.test_signatures(abi, ["testFuzzBound"]),
                         ["testFuzzBound(int256,uint32,(address,uint256)[])"])
        with self.assertRaisesRegex(ValueError, "absent or overloaded"):
            checks.smoke_checks.test_signatures(abi + abi, ["testFuzzBound"])


class ProvenanceFreshness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / "hooks/sample"
        (self.folder / "test").mkdir(parents=True)
        (self.root / "scripts").mkdir()
        (self.root / "contracts/test").mkdir(parents=True)
        (self.root / "foundry.toml").write_text("[profile.default]\n")
        (self.folder / "Sample.sol").write_text("contract Sample {}")
        (self.folder / "test/Smoke.t.sol").write_text("contract SampleSmokeTest {}")
        (self.root / "contracts/test/HookSmokeTest.sol").write_text("abstract contract HookSmokeTest {}")
        self.tools = {"forge": {"version": "pinned", "sha256": "11" * 32}}
        self.sources = results.source_identities(self.root, self.folder, [])
        self.record = results.make_record(
            root=self.root, folder=self.folder, sources=self.sources, tools=self.tools,
            manifest={"chainId": 4663, "forkBlock": 123, "forkBlockHash": "0x" + "22" * 32,
                      "rpcUrl": "https://rpc.example/public", "addresses": {}, "codeHashes": {}},
            artifact={"creationCodeHash": "0x" + "33" * 32, "deployedBytecodeHash": "0x" + "44" * 32,
                      "immutableReferencesDigest": "0x" + "55" * 32, "templateRuntimeBytes": 100, "creationBytes": 200},
            smoke=[{"suite": "hooks/sample/test/Smoke.t.sol:SampleSmokeTest", "test": "testSmokeIdentity()", "status": "Success"}],
            policy=[], receipts={"modes": [{"feeMode": 0}]}, required=["testSmokeIdentity()"])

    def verify(self, record=None):
        return results.check_record(record or self.record, root=self.root, folder=self.folder, tools=self.tools)

    def test_record_itself_is_not_a_source_hash_cycle(self):
        path = self.folder / "provenance.json"
        results.write_record(path, self.record)
        self.assertTrue(self.verify(json.loads(path.read_text())))
        self.assertNotIn("hooks/sample/provenance.json", self.record["sourceSha256"])

    def test_changed_hook_smoke_or_shared_harness_invalidates_record(self):
        for path in (self.folder / "Sample.sol", self.folder / "test/Smoke.t.sol",
                     self.root / "contracts/test/HookSmokeTest.sol"):
            with self.subTest(path=path):
                before = path.read_bytes()
                path.write_bytes(before + b"// changed")
                with self.assertRaisesRegex(ValueError, "Stale provenance"):
                    self.verify()
                path.write_bytes(before)

    def test_added_policy_test_invalidates_previous_inventory(self):
        (self.folder / "test/Policy.t.sol").write_text("contract Policy {}")
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            self.verify()

    def test_altered_results_and_changed_toolchain_are_not_current(self):
        self.record["smoke"][0]["status"] = "Skipped"
        with self.assertRaisesRegex(ValueError, "record was altered"):
            self.verify()
        self.record["smoke"][0]["status"] = "Success"
        self.tools = {"forge": {"version": "different", "sha256": "11" * 32}}
        with self.assertRaisesRegex(ValueError, "toolchain changed"):
            self.verify()

    def test_paths_cannot_escape_repository_even_with_recomputed_record_hash(self):
        self.record["sourceSha256"]["../outside.sol"] = "11" * 32
        payload = {name: value for name, value in self.record.items() if name != "recordSha256"}
        self.record["recordSha256"] = hashlib.sha256(results.canonical_json(payload).encode()).hexdigest()
        with self.assertRaisesRegex(ValueError, "escapes repository"):
            self.verify()

    def test_incomplete_run_cannot_replace_an_existing_success_record(self):
        path = self.folder / "provenance.json"
        results.write_record(path, self.record)
        previous = path.read_bytes()
        failed = {**self.record, "result": "failed"}
        with self.assertRaisesRegex(ValueError, "incomplete qualification"):
            results.write_record(path, failed)
        self.assertEqual(path.read_bytes(), previous)
        self.assertFalse((self.folder / ".provenance.json.tmp").exists())

    def test_public_record_never_includes_rpc_path_or_query_credentials(self):
        self.assertEqual(results.safe_endpoint("https://rpc.example/key/path?token=private"), "https://rpc.example")
        with self.assertRaisesRegex(ValueError, "Credentialed"):
            results.safe_endpoint("https://user:password@rpc.example")
