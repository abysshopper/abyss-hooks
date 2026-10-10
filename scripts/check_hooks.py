#!/usr/bin/env python3
"""Validate local hook sources and qualify exact artifacts on the pinned public fork."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from eth_utils import keccak

def local_module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


codec = local_module("registry_codec")
artifacts = local_module("artifact_checks")
ROOT = Path(__file__).resolve().parents[1]
FIELDS = {"schemaVersion", "name", "topology", "source", "contract", "license"}
SLUG = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*")
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
INTEGRATION_FIELDS = {"schemaVersion", "kind", "authorId", "developerFeeBps", "swapFeeModel", "terms", "bounds"}
SWAP_FEE_MODELS = {"static": 0, "dynamic": 1}
FORK_MANIFEST = ROOT / "contracts/config/robinhood.json"
HARNESS = "contracts/test/HookLaunch.t.sol"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def integration_inputs(folder):
    path = folder / "integration.json"
    require(path.is_file(), f"Missing integration.json: {folder}")
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    require(isinstance(data, dict) and set(data) == INTEGRATION_FIELDS, "Exact integration fields required")
    require(type(data["schemaVersion"]) is int and data["schemaVersion"] == 2, "Unsupported integration schemaVersion")
    require(data["kind"] in ("reference", "submission"), "Unsupported integration kind")
    author = data["authorId"]
    if data["kind"] == "reference":
        require(folder.name in {"reference-bound", "dynamic-fee"}, "Only canonical example folders may declare reference kind")
        require(author is None, "Reference examples must declare null authorId")
    else:
        require(isinstance(author, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", author) and int(author, 16) != 0, "authorId must be a nonzero 20-byte address")
    rate = data["developerFeeBps"]
    require(type(rate) is int and 0 <= rate < 10000, "developerFeeBps must be an integer in 0..9999")
    require(isinstance(data["swapFeeModel"], str) and data["swapFeeModel"] in SWAP_FEE_MODELS,
            "swapFeeModel must be static or dynamic")
    require(isinstance(data["terms"], str) and data["terms"].strip(), "Nonempty author terms are required")
    codec.bounds_tuple(data["bounds"])
    return data


def write_review_reports(rows, output):
    reports = []
    for folder, row in rows:
        declared = integration_inputs(folder)
        pins = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(folder.iterdir())}
        source_manifest = {"sourceIdentity": row, "declared": declared, "sourceFileSha256": pins}
        manifest_hash = hashlib.sha256(json.dumps(source_manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        report = {
            "schemaVersion": 1, "name": row["name"], "upstream": json.loads((ROOT / "scripts/upstream.json").read_text()),
            "declared": declared,
            "sourceIdentity": row,
            "sourceFileSha256": pins,
            "sourceManifestSha256": manifest_hash,
            "derivedRegistryFields": {
                "topology": 2, "configVersion": 6,
                "economicVersion": 3, "capabilities": 123, "flags": 0,
                "callbackFlags": 0x1afc, "callbackMask": 0x3fff,
                "configSchema": "0x" + codec.config_schema(6).hex(),
                "maximumDeveloperFeeBps": declared["developerFeeBps"],
                "configBoundsDigest": "0x" + codec.config_bounds_digest(declared["bounds"]).hex(),
            },
            "runtimeQualification": {"passed": False, "status": "not-run", "fixtureOnly": True},
            "inputValidation": {"passed": True, "scope": "Syntax and canonical registry ranges only; not author-control proof, economic approval, or execution under declared bounds"},
            "admissionReady": False,
            "pendingAdmission": [
                "Complete source/runtime/dependency review and approved artifactDigest/reviewManifestDigest/termsDigest",
                "Approve declared bounds and required author rate against the target registry's immutable protocol maximum",
                "Target chain, registry and core; registered adapterId and dependencyDigest",
                "Fixed protocol treasury and denominator (zero or 4..10)",
                "Deployed graph addresses/runtime hashes, immutable typed deployer/chunks and bound constructor provenance",
                "Exact approved envelope, configBoundsDigest, profileId and ProfileRegistrationV1",
                "Current author controller, stable-ID nonce, deadline and chain/registry-bound EOA/ERC-1271 authorization",
                "Registry administrator registration; PR merge does not submit a transaction",
            ],
        }
        (output / f"{row['name']}.registration-inputs.json").write_text(json.dumps(report, indent=2) + "\n")
        reports.append(report)
    lines = ["# Hook PR input review", "", "Declarations below are range-validated, not admitted. Author control, proposed bounds execution and production economics are unproven.", ""]
    for report in reports:
        data = report["declared"]
        lines.extend([f"## {report['name']}", "", f"- Kind: `{data['kind']}`; topology: `{report['sourceIdentity']['topology']}`",
                      f"- Stable authorId: `{data['authorId']}`; required author allocation: `{data['developerFeeBps']}` bps",
                      f"- Swap fee model: `{data['swapFeeModel']}`; derived registry maximumDeveloperFeeBps: `{data['developerFeeBps']}`",
                      "- The author rate allocates owner fees after bounty through the existing V3 hub; creator LP and hook swap fees are separate settings.",
                      f"- Bounds: `{json.dumps(data['bounds'], sort_keys=True)}`",
                      f"- Exact terms, file pins and pending inputs: `{report['name']}.registration-inputs.json`", ""])
    (output / "PR-REVIEW.md").write_text("\n".join(lines) + "\n")


def submissions(root):
    require(root.is_dir() and not root.is_symlink(), "Missing plain hooks directory")
    rows = []
    for folder in sorted(root.iterdir()):
        require(folder.is_dir() and not folder.is_symlink() and SLUG.fullmatch(folder.name), f"Invalid hook directory: {folder}")
        files = list(folder.iterdir())
        require(all(p.is_file() and not p.is_symlink() for p in files), f"Only regular files allowed: {folder}")
        require(all(p.name in {"hook.json", "integration.json", "review.md"} or (p.suffix == ".sol" and IDENTIFIER.fullmatch(p.stem)) for p in files), f"Unexpected submission file: {folder}")
        manifest = folder / "hook.json"
        require(manifest.is_file(), f"Missing hook.json: {folder}")
        row = json.loads(manifest.read_text(), object_pairs_hook=unique_object)
        require(isinstance(row, dict) and set(row) == FIELDS, f"Exact manifest fields required: {folder}")
        require(type(row["schemaVersion"]) is int and row["schemaVersion"] == 1, "Unsupported schemaVersion")
        require(row["name"] == folder.name, "Manifest name must equal directory slug")
        require(row["topology"] == "PoolBoundV4", "Unsupported topology; only PoolBoundV4 is qualified")
        require(isinstance(row["contract"], str) and IDENTIFIER.fullmatch(row["contract"]), "Invalid concrete contract name")
        source = row["source"]
        require(isinstance(source, str) and source.endswith(".sol") and IDENTIFIER.fullmatch(source[:-4]), "Source must be a local Solidity filename")
        require((folder / source).is_file(), "Missing selected source")
        require(isinstance(row["license"], str) and re.fullmatch(r"[A-Za-z0-9.+-]+", row["license"]), "Declare a single SPDX license identifier")
        review = folder / "review.md"
        require(review.is_file() and review.read_text().strip(), "Missing author review.md")
        for path in files:
            if path.suffix == ".sol":
                require(f"// SPDX-License-Identifier: {row['license']}" in path.read_text().splitlines(), f"SPDX declaration mismatch: {path}")
        integration_inputs(folder)
        rows.append((folder, row))
    require(rows, "Empty hook catalogue cannot pass qualification")
    return rows


def run(argv, cwd, output, label, env=None):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True)
    (output / f"{label}.stdout.log").write_text(result.stdout)
    (output / f"{label}.stderr.log").write_text(result.stderr)
    (output / f"{label}.command.json").write_text(json.dumps({
        "argv": argv, "cwd": str(cwd), "returnCode": result.returncode,
    }, indent=2) + "\n")
    require(result.returncode == 0, f"{label} failed; inspect {output}")
    return result.stdout


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def canonical_integer(value, name):
    if isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]*", value):
        value = int(value)
    require(type(value) is int and 0 <= value < 1 << 256, f"{name} must be a canonical uint256")
    return value


def fork_manifest(path):
    manifest = json.loads(path.read_text(), object_pairs_hook=unique_object)
    require(type(manifest["chainId"]) is int and manifest["chainId"] == 4663, "Expected Robinhood chain 4663")
    require(manifest["forkBlock"] == "latest" or (type(manifest["forkBlock"]) is int and manifest["forkBlock"] > 0),
            "Expected latest or a concrete forkBlock")
    require(isinstance(manifest["rpcUrl"], str) and manifest["rpcUrl"].startswith(("https://", "http://")), "Invalid fork RPC URL")
    addresses, hashes = manifest["addresses"], manifest["codeHashes"]
    require(isinstance(addresses, dict) and addresses and isinstance(hashes, dict) and hashes, "Missing deployed graph pins")
    for name, address in addresses.items():
        require(isinstance(name, str) and IDENTIFIER.fullmatch(name), "Invalid graph address label")
        require(isinstance(address, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", address) and int(address, 16), f"Invalid graph address: {name}")
        require(name in hashes, f"Missing graph code hash: {name}")
    require(set(hashes) == set(addresses), "Graph code hashes must match address inventory")
    for name, digest in hashes.items():
        require(isinstance(digest, str) and re.fullmatch(r"0x[0-9a-fA-F]{64}", digest), f"Invalid graph code hash: {name}")
    require("wrappedNative" in addresses, "Missing wrappedNative quote asset")
    return manifest


def check_fork_graph(manifest, rpc, output, env):
    chain = run(["cast", "chain-id", "--rpc-url", rpc], ROOT, output, "chain-id", env).strip()
    require(canonical_integer(chain, "RPC chainId") == manifest["chainId"], "RPC chain differs from pinned manifest")
    evidence = {}
    for name, address in sorted(manifest["addresses"].items()):
        raw = run(["cast", "code", address, "--rpc-url", rpc, "--block", str(manifest["forkBlock"])],
                  ROOT, output, f"code-{name}", env).strip()
        require(re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", raw), f"Missing deployed code at pinned block: {name}")
        digest = "0x" + keccak(bytes.fromhex(raw[2:])).hex()
        require(digest == manifest["codeHashes"][name].lower(), f"Pinned deployed code hash mismatch: {name}")
        evidence[name] = {"address": address, "codeHash": digest, "block": manifest["forkBlock"]}
    save_json(output / "fork-code-evidence.json", evidence)


def declared_view(abi, name):
    """True when the ABI declares `name()`; refuse any shape other than a pure address getter.

    The harness reads a declaration from the artifact's runtime code etched without running a
    constructor, so storage or immutables read zero there. `pure` makes the compiler reject such
    reads (constructor independence); the harness also checks each constructed hook agrees.
    """
    matches = [item for item in abi if item.get("type") == "function" and item.get("name") == name]
    if not matches:
        return False
    require(len(matches) == 1 and not matches[0].get("inputs") and matches[0].get("stateMutability") == "pure"
            and [output["type"] for output in matches[0].get("outputs", [])] == ["address"],
            f"Declaration {name}() must be one constructor-independent pure getter returning an address")
    return True


def receipt_evidence(path, manifest, declared, required_quote=False):
    require(path.is_file() and not path.is_symlink(), "Missing real launch receipt evidence after forge test")
    receipt = json.loads(path.read_text(), object_pairs_hook=unique_object)
    require(receipt["schema"] == "abyss-hooks.launch-receipts.v1", "Wrong launch receipt schema")
    for name in ("token", "hook", "quoteAsset"):
        require(isinstance(receipt[name], str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", receipt[name]) and int(receipt[name], 16),
                f"Invalid receipt identity: {name}")
    require(isinstance(receipt["poolId"], str) and re.fullmatch(r"0x[0-9a-fA-F]{64}", receipt["poolId"]) and int(receipt["poolId"], 16),
            "Invalid receipt poolId")
    required = receipt.get("requiredQuoteCurrency")
    if required_quote:
        # Declared by the artifact's ABI and read back from the deployed hook by the harness.
        require(isinstance(required, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", required) and int(required, 16),
                "Declared required quote missing from receipt")
        require(receipt["quoteAsset"].lower() == required.lower(), "Receipt quote differs from declared required quote")
    else:
        require(required is None or (isinstance(required, str) and re.fullmatch(r"0x0{40}", required)),
                "Undeclared required quote in receipt")
        require(receipt["quoteAsset"].lower() == manifest["addresses"]["wrappedNative"].lower(), "Receipt quote differs from pinned WETH")
    for name in ("treasuryPaid", "ownerPaid", "authorPaid", "hookFeesCollected", "lpFeesCollected",
                 "tradeCount", "developerFeeBps", "authorFeeBps", "swapFeeModel", "expectedAuthorPaid", "expectedOwnerPaid"):
        require(name in receipt, f"Missing receipt field: {name}")
        receipt[name] = canonical_integer(receipt[name], name)
    require(receipt["tradeCount"] >= 2, "Receipt requires actual trades in both directions")
    require(receipt["lpFeesCollected"] == 0, "Hook-only fees require zero collected LP fees")
    require(receipt["hookFeesCollected"] > 0, "Qualification requires actual hook trading fees")
    require(receipt["developerFeeBps"] == declared["developerFeeBps"], "Receipt developerFeeBps differs from required author rate")
    require(receipt["authorFeeBps"] == declared["developerFeeBps"], "Receipt authorFeeBps differs from author declaration")
    require(receipt["swapFeeModel"] == SWAP_FEE_MODELS[declared["swapFeeModel"]],
            "Receipt swapFeeModel differs from author declaration")
    require(receipt["authorPaid"] == receipt["expectedAuthorPaid"] and receipt["ownerPaid"] == receipt["expectedOwnerPaid"],
            "Receipt author/owner accounting mismatch")
    return receipt


def candidate_environment(declared, selected, manifest, receipts, environment):
    env = dict(environment)
    values = {
        "HOOK_ARTIFACT": str(selected), "HOOK_TOPOLOGY": 2,
        "HOOK_MAX_DEVELOPER_BPS": declared["developerFeeBps"],
        "HOOK_SWAP_FEE_MODEL": SWAP_FEE_MODELS[declared["swapFeeModel"]],
        "HOOK_FORK_MANIFEST": str(manifest), "HOOK_RECEIPT_EVIDENCE": str(receipts),
        "HOOK_ORACLE_VELOCITY_EXAMPLE": False,
    }
    for field, name in (
        ("feeModeFlags", "HOOK_FEE_MODE_FLAGS"), ("minimumTickSpacing", "HOOK_MIN_TICK_SPACING"),
        ("maximumTickSpacing", "HOOK_MAX_TICK_SPACING"), ("maximumPositions", "HOOK_MAX_POSITIONS"),
        ("maximumOracleCardinality", "HOOK_MAX_ORACLE_CARDINALITY"),
    ):
        values[name] = declared["bounds"][field]
    env.update({name: str(value).lower() if isinstance(value, bool) else str(value) for name, value in values.items()})
    return env, values


def qualify(output, rows, *, rpc_url=None):
    require(not output.exists(), "Use a new evidence output directory")
    output.mkdir(parents=True)
    write_review_reports(rows, output)
    native_pins = json.loads((ROOT / "scripts/protocol-source-pins.json").read_text(), object_pairs_hook=unique_object)
    for name, digest in {**native_pins["sha256"], native_pins["fixture"]["path"]: native_pins["fixture"]["sha256"]}.items():
        source = ROOT / name
        require(source.is_file() and not source.is_symlink(), f"Missing canonical fixture source: {name}")
        require(hashlib.sha256(source.read_bytes()).hexdigest() == digest, f"Canonical fixture source pin mismatch: {name}")
    save_json(output / "protocol-source-evidence.json", native_pins)
    manifest = fork_manifest(FORK_MANIFEST)
    rpc = rpc_url or manifest["rpcUrl"]
    require(isinstance(rpc, str) and rpc.startswith(("https://", "http://")), "Invalid fork RPC override")
    environment = {key: value for key, value in os.environ.items()
                   if key in {"PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR"}}
    environment["FOUNDRY_PROFILE"] = "default"
    block = json.loads(run(["cast", "block", str(manifest["forkBlock"]), "--json", "--rpc-url", rpc],
                           ROOT, output, "fork-block", environment))
    manifest["forkBlock"] = int(block["number"], 16) if isinstance(block["number"], str) else block["number"]
    manifest["forkBlockHash"] = block["hash"]
    require(type(manifest["forkBlock"]) is int and manifest["forkBlock"] > 0, "RPC returned invalid block number")
    require(re.fullmatch(r"0x[0-9a-fA-F]{64}", manifest["forkBlockHash"]), "RPC returned invalid block hash")
    manifest_path = output / "robinhood.json"
    save_json(manifest_path, manifest)
    manifest_path.chmod(0o444)
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    provenance = {}
    for name in ("foundry.toml", "scripts/upstream.json", "scripts/install-deps.sh", "scripts/check_hooks.py",
                 "scripts/artifact_checks.py", "scripts/registry_codec.py", "scripts/requirements.txt",
                 "scripts/protocol-source-pins.json", "contracts/test/NativeLaunchGraphFixture.sol"):
        raw = (ROOT / name).read_bytes()
        provenance[name] = hashlib.sha256(raw).hexdigest()
        destination = output / "project-provenance" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
    save_json(output / "project-provenance.json", {"sourceFileSha256": provenance})
    check_fork_graph(manifest, rpc, output, environment)
    run(["forge", "build"], ROOT, output, "build", environment)
    resolved_config = run(["forge", "config", "--root", str(ROOT)], ROOT, output, "foundry-profile-config", environment)
    solc = artifacts.compiler_executable()
    qualified = []
    for folder, row in rows:
        label = row["name"]
        print(f"Qualifying {label} ({row['topology']})", flush=True)
        candidate = output / label
        candidate.mkdir()
        report_path = output / f"{label}.registration-inputs.json"
        report = json.loads(report_path.read_text(), object_pairs_hook=unique_object)
        report["forkProvenance"] = {"manifest": "robinhood.json", "manifestSha256": manifest_hash,
                                    "chainId": manifest["chainId"], "forkBlock": manifest["forkBlock"], "rpcUrl": rpc}
        result = {"locallyQualified": False, "fixtureOnly": True, "productionAdmission": False}
        try:
            require({path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in folder.iterdir()} == report["sourceFileSha256"],
                    f"Submission files changed after input review: {label}")
            artifact = ROOT / "out" / row["source"] / f"{row['contract']}.json"
            require(artifact.is_file(), f"No concrete artifact produced: {label}")
            selected = candidate / "qualified-hook-artifact.json"
            selected.write_bytes(artifact.read_bytes())
            selected.chmod(0o444)
            measured = artifacts.artifact_evidence(selected)
            metadata = artifacts.artifact_metadata(artifacts.load_json(selected.read_bytes()), selected)
            require(metadata["settings"]["compilationTarget"] == {str((folder / row["source"]).relative_to(ROOT)): row["contract"]},
                    f"Artifact target collision or mismatch: {label}")
            pins = artifacts.source_inventory(measured, ROOT)
            source_manifest = {"schema": "abyss-hooks.compiler-source-pins.v1", "sources": pins,
                               "selectedArtifactSha256": measured["fileSha256"], "forkManifestSha256": manifest_hash}
            save_json(candidate / "source-manifest.json", source_manifest)
            measured["sourceManifestSha256"] = hashlib.sha256((candidate / "source-manifest.json").read_bytes()).hexdigest()
            measured["compilerReconstruction"] = artifacts.reconstruct_artifact(
                measured, pins, root=ROOT, solc=solc, output=candidate / "compiler-reconstruction")
            measured["compilerSourceCorrespondenceVerified"] = True
            report["measuredArtifact"] = measured
            result["artifactEvidence"] = measured
            receipts = candidate / "receipt-evidence.json"
            candidate_manifest = candidate / "robinhood.json"
            candidate_manifest.write_bytes(manifest_path.read_bytes())
            candidate_manifest.chmod(0o444)
            env, inputs = candidate_environment(report["declared"], selected, candidate_manifest, receipts, environment)
            # Derive feature presence from the independent compiler, not author metadata.
            rebuilt = artifacts.load_json((candidate / "compiler-reconstruction/compiler-output.json").read_bytes())
            compiled_metadata = artifacts.load_json(rebuilt["contracts"][
                str((folder / row["source"]).relative_to(ROOT))
            ][row["contract"]]["metadata"])
            abi = compiled_metadata["output"]["abi"]
            has_oracle = any(
                item.get("type") == "function" and item.get("name") == "observeTruncated"
                and [argument["type"] for argument in item["inputs"]] == ["bytes32", "uint32[]"]
                for item in abi
            )
            env["HOOK_HAS_ORACLE"] = "true" if has_oracle else "false"
            inputs["HOOK_HAS_ORACLE"] = has_oracle
            # Optional swap-admission declarations, also ABI-derived: a required quote currency
            # replaces WETH as the launch quote; a pass authority makes buys carry SwapPass hookData.
            required_quote = declared_view(abi, "requiredQuoteCurrency")
            swap_pass = declared_view(abi, "swapPassSigner")
            env["HOOK_REQUIRED_QUOTE"] = "true" if required_quote else "false"
            env["HOOK_SWAP_PASS"] = "true" if swap_pass else "false"
            env["HOOK_CONTRACT_NAME"] = row["contract"]
            inputs["HOOK_REQUIRED_QUOTE"] = required_quote
            inputs["HOOK_SWAP_PASS"] = swap_pass
            inputs["HOOK_CONTRACT_NAME"] = row["contract"]
            # Economic vectors apply only to this repository's oracle-velocity reference,
            # not arbitrary admitted dynamic policies. Feature support remains ABI-derived.
            velocity_example = folder == ROOT / "hooks/dynamic-fee" and row["contract"] == "DynamicFeeHook"
            env["HOOK_ORACLE_VELOCITY_EXAMPLE"] = "true" if velocity_example else "false"
            inputs["HOOK_ORACLE_VELOCITY_EXAMPLE"] = velocity_example
            config = candidate / "external-artifact.foundry.toml"
            config.write_text(resolved_config + '\n[[profile.default.fs_permissions]]\naccess = "read-write"\npath = '
                              + json.dumps(str(candidate)) + "\n")
            env["FOUNDRY_CONFIG"] = str(config)
            inputs["FOUNDRY_CONFIG"] = str(config)
            result["foundryConfigSha256"] = hashlib.sha256(config.read_bytes()).hexdigest()
            save_json(candidate / "runtime-inputs.json", inputs)
            report["runtimeQualification"] = {"passed": False, "status": "running", "fixtureOnly": True}
            save_json(report_path, report)
            save_json(candidate / "qualification-result.json", result)
            run(["forge", "test", "--match-path", HARNESS, "--fork-url", rpc,
                 "--fork-block-number", str(manifest["forkBlock"]), "--root", str(ROOT), "-vvv"],
                ROOT, candidate, "foundry-qualification", env)
            require(hashlib.sha256(selected.read_bytes()).hexdigest() == measured["fileSha256"], "Selected artifact changed during execution")
            require(hashlib.sha256(manifest_path.read_bytes()).hexdigest() == manifest_hash, "Fork manifest changed during execution")
            require(hashlib.sha256(candidate_manifest.read_bytes()).hexdigest() == manifest_hash, "Candidate fork manifest changed during execution")
            evidence = receipt_evidence(receipts, manifest, report["declared"], required_quote)
            result.update(locallyQualified=True, receiptEvidence=evidence,
                          receiptEvidenceFileSha256=hashlib.sha256(receipts.read_bytes()).hexdigest())
            report["runtimeQualification"] = {
                "passed": True, "status": "passed", "fixtureOnly": True,
                "scope": "One standard ERC20/WETH launch with candidate artifact; fork-local governance simulation, not live admission",
                "declaredBoundsAndEconomicsExhaustivelyExecuted": False,
                "evidence": f"{label}/qualification-result.json", "receiptEvidence": f"{label}/receipt-evidence.json",
            }
        except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
            report["runtimeQualification"] = {"passed": False, "status": "failed", "fixtureOnly": True, "error": str(error)}
            result["error"] = str(error)
            raise
        finally:
            save_json(report_path, report)
            save_json(candidate / "qualification-result.json", result)
        qualified.append({"name": label, "evidence": f"{label}/qualification-result.json", "locallyQualified": True})
    qualify_oracle_composition(output, solc, environment, resolved_config, rpc)
    qualify_declared_admission_fixture(output, solc, environment, resolved_config, rpc)
    save_json(output / "catalogue-result.json", {
        "upstream": json.loads((ROOT / "scripts/upstream.json").read_text()), "forkManifestSha256": manifest_hash,
        "hooks": qualified, "locallyQualified": True, "fixtureOnly": True, "productionAdmission": False,
        "oracleComposition": {"evidence": "oracle-composition/qualification-result.json",
                              "locallyQualified": True, "fixtureOnly": True},
        "declaredAdmission": {"evidence": "declared-admission/qualification-result.json",
                              "locallyQualified": True, "fixtureOnly": True},
    })


def qualify_oracle_composition(output, solc, environment, resolved_config, rpc):
    """Exercise the opt-in template as a fixture, not another catalogue submission."""
    candidate = output / "oracle-composition"
    candidate.mkdir()
    selected = candidate / "qualified-hook-artifact.json"
    selected.write_bytes((ROOT / "out/TruncatedOracleComposition.t.sol/StaticOracleHook.json").read_bytes())
    selected.chmod(0o444)
    measured = artifacts.artifact_evidence(selected)
    metadata = artifacts.artifact_metadata(artifacts.load_json(selected.read_bytes()), selected)
    require(metadata["settings"]["compilationTarget"] == {
        "contracts/test/TruncatedOracleComposition.t.sol": "StaticOracleHook"
    }, "Oracle fixture artifact target mismatch")
    pins = artifacts.source_inventory(measured, ROOT)
    measured["compilerReconstruction"] = artifacts.reconstruct_artifact(
        measured, pins, root=ROOT, solc=solc, output=candidate / "compiler-reconstruction")
    measured["compilerSourceCorrespondenceVerified"] = True
    save_json(candidate / "source-manifest.json", {"sources": pins})
    declared = artifacts.load_json((ROOT / "hooks/reference-bound/integration.json").read_bytes())
    manifest_path = output / "robinhood.json"
    manifest = fork_manifest(manifest_path)
    receipts = candidate / "receipt-evidence.json"
    env, inputs = candidate_environment(declared, selected, manifest_path, receipts, environment)
    env["HOOK_HAS_ORACLE"] = "true"
    inputs["HOOK_HAS_ORACLE"] = True
    config = candidate / "external-artifact.foundry.toml"
    config.write_text(resolved_config + '\n[[profile.default.fs_permissions]]\naccess = "read-write"\npath = '
                      + json.dumps(str(candidate)) + "\n")
    env["FOUNDRY_CONFIG"] = str(config)
    inputs["FOUNDRY_CONFIG"] = str(config)
    save_json(candidate / "runtime-inputs.json", inputs)
    result = {"locallyQualified": False, "fixtureOnly": True, "productionAdmission": False,
              "artifactEvidence": measured}
    save_json(candidate / "qualification-result.json", result)
    run(["forge", "test", "--match-path", HARNESS, "--fork-url", rpc,
         "--fork-block-number", str(manifest["forkBlock"]), "--root", str(ROOT), "-vvv"],
        ROOT, candidate, "foundry-qualification", env)
    result["receiptEvidence"] = receipt_evidence(receipts, manifest, declared)
    result["locallyQualified"] = True
    save_json(candidate / "qualification-result.json", result)
    print("Qualified optional oracle composition fixture", flush=True)


def qualify_declared_admission_fixture(output, solc, environment, resolved_config, rpc):
    """Exercise the optional admission declarations as a fixture, not a catalogue submission.

    The fixture requires wrapped native as its quote, which no catalogue hook needs to cover,
    and gates buys behind the CONTRIBUTING SwapPass, so the harness capability is qualified on
    its own merits even with no declaring hook in the catalogue.
    """
    candidate = output / "declared-admission"
    candidate.mkdir()
    source, contract = "contracts/test/DeclaredAdmissionFixture.sol", "DeclaredAdmissionFixtureHook"
    selected = candidate / "qualified-hook-artifact.json"
    selected.write_bytes((ROOT / "out/DeclaredAdmissionFixture.sol" / f"{contract}.json").read_bytes())
    selected.chmod(0o444)
    measured = artifacts.artifact_evidence(selected)
    metadata = artifacts.artifact_metadata(artifacts.load_json(selected.read_bytes()), selected)
    require(metadata["settings"]["compilationTarget"] == {source: contract}, "Declared-admission fixture target mismatch")
    pins = artifacts.source_inventory(measured, ROOT)
    measured["compilerReconstruction"] = artifacts.reconstruct_artifact(
        measured, pins, root=ROOT, solc=solc, output=candidate / "compiler-reconstruction")
    measured["compilerSourceCorrespondenceVerified"] = True
    save_json(candidate / "source-manifest.json", {"sources": pins})
    rebuilt = artifacts.load_json((candidate / "compiler-reconstruction/compiler-output.json").read_bytes())
    abi = artifacts.load_json(rebuilt["contracts"][source][contract]["metadata"])["output"]["abi"]
    required_quote = declared_view(abi, "requiredQuoteCurrency")
    swap_pass = declared_view(abi, "swapPassSigner")
    require(required_quote and swap_pass, "Declared-admission fixture must declare both views")
    declared = artifacts.load_json((ROOT / "hooks/reference-bound/integration.json").read_bytes())
    manifest_path = output / "robinhood.json"
    manifest = fork_manifest(manifest_path)
    receipts = candidate / "receipt-evidence.json"
    env, inputs = candidate_environment(declared, selected, manifest_path, receipts, environment)
    env.update(HOOK_HAS_ORACLE="false", HOOK_REQUIRED_QUOTE="true", HOOK_SWAP_PASS="true", HOOK_CONTRACT_NAME=contract)
    inputs.update(HOOK_HAS_ORACLE=False, HOOK_REQUIRED_QUOTE=True, HOOK_SWAP_PASS=True, HOOK_CONTRACT_NAME=contract)
    config = candidate / "external-artifact.foundry.toml"
    config.write_text(resolved_config + '\n[[profile.default.fs_permissions]]\naccess = "read-write"\npath = '
                      + json.dumps(str(candidate)) + "\n")
    env["FOUNDRY_CONFIG"] = str(config)
    inputs["FOUNDRY_CONFIG"] = str(config)
    save_json(candidate / "runtime-inputs.json", inputs)
    result = {"locallyQualified": False, "fixtureOnly": True, "productionAdmission": False,
              "artifactEvidence": measured}
    save_json(candidate / "qualification-result.json", result)
    run(["forge", "test", "--match-path", HARNESS, "--fork-url", rpc,
         "--fork-block-number", str(manifest["forkBlock"]), "--root", str(ROOT), "-vvv"],
        ROOT, candidate, "foundry-qualification", env)
    result["receiptEvidence"] = receipt_evidence(receipts, manifest, declared, required_quote=True)
    result["locallyQualified"] = True
    save_json(candidate / "qualification-result.json", result)
    print("Qualified declared-admission fixture", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", help="Override the pinned manifest's public RPC endpoint")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence")
    parser.add_argument("--structure-only", action="store_true")
    args = parser.parse_args()
    try:
        rows = submissions(ROOT / "hooks")
        print(f"Validated {len(rows)} source submissions", flush=True)
        if args.structure_only:
            output = args.output.resolve()
            require(not output.exists(), "Use a new evidence output directory")
            output.mkdir(parents=True)
            write_review_reports(rows, output)
        else:
            qualify(args.output.resolve(), rows, rpc_url=args.rpc_url)
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Hook checks refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
