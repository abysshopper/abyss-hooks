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
from types import SimpleNamespace

from eth_utils import keccak

def local_module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


codec = local_module("registry_codec")
artifacts = local_module("artifact_checks")
results = local_module("qualification_results")
smoke_checks = local_module("smoke_checks")
local_tests = local_module("local_tests")
ROOT = Path(__file__).resolve().parents[1]
FIELDS = {"schemaVersion", "name", "topology", "source", "contract", "license"}
SLUG = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*")
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
INTEGRATION_FIELDS = {"schemaVersion", "kind", "authorId", "developerFeeBps", "swapFeeModel", "terms", "bounds"}
SWAP_FEE_MODELS = {"static": 0, "dynamic": 1}
FORK_MANIFEST = ROOT / "contracts/config/robinhood.json"
SMOKE_BASE = "contracts/test/HookSmokeTest.sol"
SMOKE_FILE = "Smoke.t.sol"
FOUNDRY_COMMIT = "5e88010a83d1b87b8f4d13058e42a2949d3e9dc0"


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
        pins = submission_source_hashes(folder)
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
        files = submission_files(folder)
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

def submission_files(folder):
    """Only candidate sources, one flat contributor test directory and compact provenance."""
    files = []
    for path in sorted(folder.iterdir()):
        require(not path.is_symlink(), f"Only regular files allowed: {folder}")
        if path.name == "test":
            require(path.is_dir(), f"Missing plain test directory: {folder}")
            for test in sorted(path.iterdir()):
                require(test.is_file() and not test.is_symlink(), f"Only regular test files allowed: {folder}")
                stem = test.name.removesuffix(".sol").removesuffix(".t")
                require(test.suffix == ".sol" and IDENTIFIER.fullmatch(stem), f"Unexpected test file: {test}")
                files.append(test)
            continue
        require(path.is_file(), f"Only regular files allowed: {folder}")
        require(path.name in {"hook.json", "integration.json", "review.md", "provenance.json"}
                or (path.suffix == ".sol" and IDENTIFIER.fullmatch(path.stem)),
                f"Unexpected submission file: {path}")
        if path.name == "provenance.json":
            record = artifacts.load_json(path.read_bytes())
            require(isinstance(record, dict) and record.get("schema") == results.SCHEMA,
                    "Unsupported local provenance schema")
        if path.name != "provenance.json":
            files.append(path)
    require((folder / "test" / SMOKE_FILE).is_file(), f"Missing required test/{SMOKE_FILE}: {folder}")
    return files


def submission_source_hashes(folder):
    return {str(path.relative_to(folder)): results.sha256(path) for path in submission_files(folder)}


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


def receipt_evidence(path, manifest, declared):
    require(path.is_file() and not path.is_symlink(), "Missing real launch receipt evidence after forge test")
    receipt = json.loads(path.read_text(), object_pairs_hook=unique_object)
    require(receipt["schema"] == "abyss-hooks.launch-receipts.v1", "Wrong launch receipt schema")
    for name in ("token", "hook", "quoteAsset"):
        require(isinstance(receipt[name], str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", receipt[name]) and int(receipt[name], 16),
                f"Invalid receipt identity: {name}")
    require(isinstance(receipt["poolId"], str) and re.fullmatch(r"0x[0-9a-fA-F]{64}", receipt["poolId"]) and int(receipt["poolId"], 16),
            "Invalid receipt poolId")
    require(bool(receipt.get("modes")), "Missing per-mode smoke receipt evidence")
    for name in ("treasuryPaid", "ownerPaid", "authorPaid", "hookFeesCollected", "lpFeesCollected",
                 "tradeCount", "developerFeeBps", "authorFeeBps", "swapFeeModel", "expectedAuthorPaid", "expectedOwnerPaid"):
        require(name in receipt, f"Missing receipt field: {name}")
        receipt[name] = canonical_integer(receipt[name], name)
    require(receipt["tradeCount"] > 0, "Receipt requires actual supported trades")
    require(receipt["lpFeesCollected"] == 0, "Hook-only fees require zero collected LP fees")
    require(receipt["developerFeeBps"] == declared["developerFeeBps"], "Receipt developerFeeBps differs from required author rate")
    require(receipt["authorFeeBps"] == declared["developerFeeBps"], "Receipt authorFeeBps differs from author declaration")
    require(receipt["swapFeeModel"] == SWAP_FEE_MODELS[declared["swapFeeModel"]],
            "Receipt swapFeeModel differs from author declaration")
    require(receipt["authorPaid"] == receipt["expectedAuthorPaid"] and receipt["ownerPaid"] == receipt["expectedOwnerPaid"],
            "Receipt author/owner accounting mismatch")
    modes = receipt["modes"]
    expected_modes = [mode for mode in range(2) if declared["bounds"]["feeModeFlags"] & (1 << mode)]
    require(isinstance(modes, list) and [item.get("feeMode") for item in modes] == expected_modes,
            "Smoke receipts must cover every declared fee mode exactly once")
    total_trades = 0
    for mode in modes:
        require(mode.get("quoteAsset", "").lower() == receipt["quoteAsset"].lower(), "Mode quote identity differs")
        for name in ("token", "hook", "quoteAsset"):
            require(isinstance(mode.get(name), str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", mode[name])
                    and int(mode[name], 16), f"Invalid mode identity: {name}")
        require(canonical_integer(mode.get("developerFeeBps"), "mode developerFeeBps") == declared["developerFeeBps"]
                and canonical_integer(mode.get("authorFeeBps"), "mode authorFeeBps") == declared["developerFeeBps"],
                "Mode author rate differs from declaration")
        require(canonical_integer(mode.get("swapFeeModel"), "mode swapFeeModel") == SWAP_FEE_MODELS[declared["swapFeeModel"]],
                "Mode fee model differs from declaration")
        for name in ("treasuryPaid", "hookFeesCollected", "principalBefore", "principalAfter", "openingBuyQuote"):
            canonical_integer(mode.get(name), "mode " + name)
        require(canonical_integer(mode.get("tradeCount"), "mode tradeCount") > 0, "Mode needs actual supported trades")
        total_trades += canonical_integer(mode["tradeCount"], "mode tradeCount")
        require(canonical_integer(mode.get("lpFeesCollected"), "mode LP fees") == 0, "Mode collected LP fees")
        require(canonical_integer(mode.get("authorPaid"), "mode authorPaid") ==
                canonical_integer(mode.get("expectedAuthorPaid"), "mode expectedAuthorPaid"), "Mode author accounting mismatch")
        require(canonical_integer(mode.get("ownerPaid"), "mode ownerPaid") ==
                canonical_integer(mode.get("expectedOwnerPaid"), "mode expectedOwnerPaid"), "Mode owner accounting mismatch")
        require(canonical_integer(mode.get("principalBefore"), "mode principal before") ==
                canonical_integer(mode.get("principalAfter"), "mode principal after"), "Collection changed principal")
        cases = mode.get("cases")
        require(isinstance(cases, list) and len(cases) == 4, "Smoke needs four named amount/direction cases")
        expected_cases = {(direction, amount) for direction in ("buy", "sell")
                          for amount in ("exact-input", "exact-output")}
        require({(case.get("direction"), case.get("amountMode")) for case in cases} == expected_cases,
                "Smoke amount/direction case coverage differs")
        successes = 0
        for case in cases:
            require(case.get("status") in ("success", "rejected"), "Unknown smoke trade status")
            if case["status"] == "success":
                successes += 1
                require(canonical_integer(case.get("inputAmount"), "case input") > 0
                        and canonical_integer(case.get("outputAmount"), "case output") > 0,
                        "Successful smoke case has no actual volume")
                require(canonical_integer(case.get("ratePips"), "case rate") <= 1_000_000, "Smoke case fee rate out of bounds")
                canonical_integer(case.get("feePaid"), "case feePaid")
            else:
                require(isinstance(case.get("expectedRevert"), str)
                        and re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", case["expectedRevert"]),
                        "Refused smoke case needs a concrete expected revert")
        require(successes == canonical_integer(mode["tradeCount"], "mode tradeCount"), "Mode trade count mismatch")
    require(total_trades == canonical_integer(receipt.get("totalTradeCount"), "totalTradeCount"),
            "Aggregate smoke trade count mismatch")
    require(receipt["tradeCount"] == canonical_integer(modes[0]["tradeCount"], "first mode tradeCount"),
            "Compatibility receipt differs from first mode")
    return receipt


def candidate_environment(declared, selected, manifest, receipts, environment):
    env = dict(environment)
    values = {
        "HOOK_ARTIFACT": str(selected), "HOOK_TOPOLOGY": 2,
        "HOOK_MAX_DEVELOPER_BPS": declared["developerFeeBps"],
        "HOOK_SWAP_FEE_MODEL": SWAP_FEE_MODELS[declared["swapFeeModel"]],
        "HOOK_FORK_MANIFEST": str(manifest), "HOOK_RECEIPT_EVIDENCE": str(receipts),
    }
    for field, name in (
        ("feeModeFlags", "HOOK_FEE_MODE_FLAGS"), ("minimumTickSpacing", "HOOK_MIN_TICK_SPACING"),
        ("maximumTickSpacing", "HOOK_MAX_TICK_SPACING"), ("maximumPositions", "HOOK_MAX_POSITIONS"),
        ("maximumOracleCardinality", "HOOK_MAX_ORACLE_CARDINALITY"),
    ):
        values[name] = declared["bounds"][field]
    env.update({name: str(value).lower() if isinstance(value, bool) else str(value) for name, value in values.items()})
    return env, values


def clean_environment():
    environment = {key: value for key, value in os.environ.items()
                   if key in {"PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR"}}
    environment["FOUNDRY_PROFILE"] = "default"
    return environment


def qualify(output, rows, *, rpc_url=None, record=False):
    require(not output.exists(), "Use a new evidence output directory")
    output.mkdir(parents=True)
    (output / "RESULTS.md").write_text("# Local qualification\n\nStatus: running. No success is recorded yet.\n")
    write_review_reports(rows, output)
    input_snapshot = results.source_identities(ROOT, ROOT / "hooks", [])
    native_pins = json.loads((ROOT / "scripts/protocol-source-pins.json").read_text(), object_pairs_hook=unique_object)
    for name, digest in {**native_pins["sha256"], native_pins["fixture"]["path"]: native_pins["fixture"]["sha256"]}.items():
        source = ROOT / name
        require(source.is_file() and not source.is_symlink(), f"Missing canonical fixture source: {name}")
        require(hashlib.sha256(source.read_bytes()).hexdigest() == digest, f"Canonical fixture source pin mismatch: {name}")
    save_json(output / "protocol-source-evidence.json", native_pins)
    manifest = fork_manifest(FORK_MANIFEST)
    rpc = rpc_url or manifest["rpcUrl"]
    results.safe_endpoint(rpc)
    manifest["rpcUrl"] = rpc
    environment = clean_environment()
    block = json.loads(run(["cast", "block", str(manifest["forkBlock"]), "--json", "--rpc-url", rpc],
                           ROOT, output, "fork-block", environment))
    manifest["forkBlock"] = int(block["number"], 16) if isinstance(block["number"], str) else block["number"]
    manifest["forkBlockHash"] = block["hash"]
    manifest["forkTimestamp"] = int(block["timestamp"], 16) if isinstance(block["timestamp"], str) else block["timestamp"]
    require(type(manifest["forkBlock"]) is int and manifest["forkBlock"] > 0, "RPC returned invalid block number")
    require(re.fullmatch(r"0x[0-9a-fA-F]{64}", manifest["forkBlockHash"]), "RPC returned invalid block hash")
    manifest_path = output / "robinhood.json"
    save_json(manifest_path, manifest)
    manifest_path.chmod(0o444)
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    provenance = {}
    for name in ("foundry.toml", "scripts/upstream.json", "scripts/install-deps.sh", "scripts/check_hooks.py",
                 "scripts/artifact_checks.py", "scripts/registry_codec.py", "scripts/requirements.txt",
                 "scripts/protocol-source-pins.json", "scripts/qualification_results.py", "scripts/smoke_checks.py",
                 "scripts/local_tests.py", "contracts/test/NativeLaunchGraphFixture.sol"):
        raw = (ROOT / name).read_bytes()
        provenance[name] = hashlib.sha256(raw).hexdigest()
        destination = output / "project-provenance" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
    save_json(output / "project-provenance.json", {"sourceFileSha256": provenance})
    check_fork_graph(manifest, rpc, output, environment)
    run(["forge", "build", "--ast"], ROOT, output, "build", environment)
    resolved_config = run(["forge", "config", "--root", str(ROOT)], ROOT, output, "foundry-profile-config", environment)
    solc = artifacts.compiler_executable()
    tools = results.toolchain_identity(solc, environment)
    require(FOUNDRY_COMMIT in tools["forge"]["version"], "Use the pinned Foundry release from CONTRIBUTING.md")
    context = SimpleNamespace(ROOT=ROOT, SMOKE_FILE=SMOKE_FILE, SMOKE_BASE=SMOKE_BASE,
                              results=results, artifacts=artifacts, smoke_checks=smoke_checks,
                              require=require, run=run, save_json=save_json,
                              submission_source_hashes=submission_source_hashes,
                              candidate_environment=candidate_environment, receipt_evidence=receipt_evidence,
                              input_snapshot=input_snapshot)
    qualified = []
    recorded = []
    for folder, row in rows:
        result, evidence = local_tests.qualify_candidate(context, output, folder, row, manifest,
                                                        environment, resolved_config, solc, tools)
        qualified.append({"name": row["name"], "evidence": f"{row['name']}/qualification-result.json", "locallyQualified": True})
        recorded.append((folder, evidence))
    save_json(output / "catalogue-result.json", {
        "hooks": qualified, "locallyQualified": True, "fixtureOnly": True, "productionAdmission": False,
        "fork": {"chainId": manifest["chainId"], "block": manifest["forkBlock"], "blockHash": manifest["forkBlockHash"]},
    })
    (output / "RESULTS.md").write_text("# Local qualification passed\n\nGitHub CI not run: explicitly paused.\n\n"
                                       + "\n".join(f"- [{item['name']}]({item['name']}/RESULTS.md)" for item in qualified) + "\n")
    if record:
        for folder, evidence in recorded:
            results.check_record(evidence, root=ROOT, folder=folder, tools=tools)
            results.write_record(folder / "provenance.json", evidence)
            print(f"Recorded {folder.relative_to(ROOT)}/provenance.json; review and stage it with its sources/tests.", flush=True)
    print(f"\nLocal results: {output / 'RESULTS.md'}", flush=True)




def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", help="Override the pinned manifest's public RPC endpoint")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence")
    parser.add_argument("--structure-only", action="store_true")
    parser.add_argument("--hook", help="Qualify one hook slug; all hooks by default")
    parser.add_argument("--record", action="store_true", help="Write compact hooks/<slug>/provenance.json after success only")
    parser.add_argument("--check-provenance", action="store_true", help="Check recorded input identities without rerunning the fork")
    args = parser.parse_args()
    output_was_present = args.output.resolve().exists()
    try:
        rows = submissions(ROOT / "hooks")
        print(f"Validated {len(rows)} source submissions", flush=True)
        if args.hook:
            require(SLUG.fullmatch(args.hook), "Invalid hook selection")
            rows = [(folder, row) for folder, row in rows if row["name"] == args.hook]
            require(bool(rows), f"Unknown hook: {args.hook}")
        require(not (args.structure_only and (args.record or args.check_provenance)),
                "Structure-only validation cannot record runtime provenance")
        require(not (args.record and args.check_provenance), "Choose record or check-provenance, not both")
        if args.check_provenance:
            tools = results.toolchain_identity(artifacts.compiler_executable(), clean_environment())
            for folder, row in rows:
                path = folder / "provenance.json"
                require(path.is_file() and not path.is_symlink(), f"Missing local provenance: {row['name']}")
                record = artifacts.load_json(path.read_bytes())
                results.check_record(record, root=ROOT, folder=folder, tools=tools)
                print(f"CURRENT {row['name']}: source/test/harness/tool identities match; fork not rerun.", flush=True)
            return 0
        if args.structure_only:
            output = args.output.resolve()
            require(not output.exists(), "Use a new evidence output directory")
            output.mkdir(parents=True)
            write_review_reports(rows, output)
        else:
            try:
                qualify(args.output.resolve(), rows, rpc_url=args.rpc_url, record=args.record)
            except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
                summary = args.output.resolve() / "RESULTS.md"
                if not output_was_present and summary.is_file():
                    summary.write_text("# Local qualification failed\n\nNo successful provenance was recorded.\n\n"
                                       + str(error) + "\n")
                raise
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Hook checks refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
