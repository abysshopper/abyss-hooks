"""Parse executed Foundry results and bind local qualification to exact input bytes."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import urlsplit

SCHEMA = "abyss-hooks.local-provenance.v1"
HASH = re.compile(r"[0-9a-f]{64}")
SUCCESS = "Success"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def result_rows(payload):
    """Keep actual named statuses, including failures and skips; no count-based acceptance."""
    require(isinstance(payload, dict), "Foundry test result must be an object")
    rows = []
    for suite, data in sorted(payload.items()):
        require(isinstance(data, dict) and isinstance(data.get("test_results"), dict),
                f"Missing Foundry test results: {suite}")
        for name, result in sorted(data["test_results"].items()):
            require(isinstance(result, dict), f"Invalid Foundry test result: {suite}/{name}")
            status = result.get("status")
            require(status in ("Success", "Failure", "Skipped"), f"Unknown test status: {suite}/{name}")
            row = {"suite": suite, "test": name, "status": status}
            kind = result.get("kind")
            if isinstance(kind, dict):
                unit = kind.get("Unit", kind.get("Standard"))
                if isinstance(unit, dict):
                    row["gas"] = unit.get("gas")
                if "Fuzz" in kind and isinstance(kind["Fuzz"], dict):
                    row["fuzzRuns"] = kind["Fuzz"].get("runs")
            if status != SUCCESS:
                row["reason"] = str(result.get("reason") or "")
            rows.append(row)
    return rows


def validate_test_results(rows, *, required=(), suite=None, allow_empty=False):
    require(rows or allow_empty, "No tests were executed")
    require(all(row.get("status") in ("Success", "Failure", "Skipped") for row in rows), "Unknown named test status")
    require(all(isinstance(row.get("suite"), str) and isinstance(row.get("test"), str) for row in rows),
            "Named test result identity is missing")
    require(all(row["test"].startswith("test") for row in rows), "Result is not an executed test")
    require(not any(row["status"] == "Failure" for row in rows), "Executed tests contain a failure")
    names = [(row["suite"], row["test"]) for row in rows]
    require(len(names) == len(set(names)), "Duplicate named test results")
    for name in required:
        candidates = [row for row in rows if row["test"] == name
                      and (suite is None or row["suite"].endswith(":" + suite))]
        require(len(candidates) == 1, f"Required smoke test was not executed exactly once: {name}")
        require(candidates[0]["status"] == SUCCESS, f"Required smoke test did not pass: {name}")


def print_rows(label, rows):
    print(f"\n{label}", flush=True)
    for row in rows:
        gas = f" gas={row['gas']}" if type(row.get("gas")) is int else ""
        print(f"  {row['status'].upper():7} {row['suite']}::{row['test']}{gas}", flush=True)
        if row.get("reason"):
            print(f"          {row['reason']}", flush=True)
    print(f"  {sum(row['status'] == SUCCESS for row in rows)} passed, "
          f"{sum(row['status'] == 'Failure' for row in rows)} failed, "
          f"{sum(row['status'] == 'Skipped' for row in rows)} skipped", flush=True)


def executable_identity(name, environment):
    executable = shutil.which(name, path=environment.get("PATH"))
    require(executable is not None, f"Missing local executable: {name}")
    path = Path(executable).resolve()
    result = subprocess.run([str(path), "--version"], env=environment, text=True,
                            capture_output=True, check=True)
    return {"version": result.stdout.strip(), "sha256": sha256(path)}


def toolchain_identity(solc, environment):
    result = subprocess.run([str(solc), "--version"], env=environment, text=True,
                            capture_output=True, check=True)
    return {
        "forge": executable_identity("forge", environment),
        "cast": executable_identity("cast", environment),
        "solc": {"version": result.stdout.strip(), "sha256": sha256(solc)},
        "fuzzSeed": "0x" + "01" * 32,
    }


def safe_endpoint(rpc):
    parsed = urlsplit(rpc)
    require(parsed.scheme in ("http", "https") and parsed.hostname, "Invalid fork RPC endpoint")
    require(parsed.username is None and parsed.password is None, "Credentialed RPC URLs are not supported")
    # A committed receipt records only the public origin, never URL path/query credentials.
    return f"{parsed.scheme}://{parsed.netloc}"


def source_identities(root, folder, inventories):
    root, folder = root.resolve(), folder.resolve()
    paths = set()
    for inventory in inventories:
        paths.update(inventory)
    paths.update(str(path.relative_to(root)) for path in folder.rglob("*")
                 if path.is_file() and path.name != "provenance.json")
    for directory, suffixes in ((root / "scripts", (".py", ".json", ".txt", ".sh")),
                                (root / "contracts", (".sol", ".json"))):
        paths.update(str(path.relative_to(root)) for path in directory.rglob("*")
                     if path.is_file() and path.suffix in suffixes
                     and "lib" not in path.relative_to(directory).parts
                     and "__pycache__" not in path.relative_to(directory).parts)
    paths.add("foundry.toml")
    values = {}
    for relative in sorted(paths):
        path = Path(relative)
        require(not path.is_absolute() and ".." not in path.parts, "Provenance source escapes repository")
        source = root / path
        require(source.is_file() and not source.is_symlink() and source.resolve().is_relative_to(root),
                f"Missing plain provenance source: {relative}")
        values[relative] = sha256(source)
    return values


def source_commit(root):
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else None


def make_record(*, root, folder, sources, tools, manifest, artifact, smoke, policy, receipts, required):
    payload = {
        "schema": SCHEMA,
        "hook": folder.name,
        "sourceCommit": source_commit(root),
        "identity": "File hashes identify executed working-tree inputs; a commit label alone does not.",
        "sourceSha256": sources,
        "toolchain": tools,
        "fork": {"chainId": manifest["chainId"], "block": manifest["forkBlock"], "timestamp": manifest.get("forkTimestamp"),
                 "blockHash": manifest["forkBlockHash"], "rpcOrigin": safe_endpoint(manifest["rpcUrl"]),
                 "addresses": manifest["addresses"], "codeHashes": manifest["codeHashes"]},
        "artifact": {name: artifact[name] for name in (
            "creationCodeHash", "deployedBytecodeHash", "immutableReferencesDigest",
            "templateRuntimeBytes", "creationBytes")},
        "requiredSmokeTests": sorted(required),
        "smoke": smoke,
        "policy": policy,
        "receipts": receipts,
        "result": "passed",
        "fixtureOnly": True,
        "limitations": "Locally generated observations, not a signed attestation, independent audit or author-control proof.",
        "productionAdmission": False,
        "ci": "not run: explicitly paused",
    }
    validate_test_results(smoke, required=required)
    validate_test_results(policy, allow_empty=True)
    require(all(row["status"] == SUCCESS for row in policy), "Skipped policy tests cannot record a successful qualification")
    payload["recordSha256"] = hashlib.sha256(canonical_json(payload).encode()).hexdigest()
    return payload


def check_record(record, *, root, folder, tools):
    require(isinstance(record, dict) and record.get("schema") == SCHEMA, "Unsupported local provenance schema")
    require(record.get("hook") == folder.name and record.get("result") == "passed",
            "Provenance is not a passed run for this hook")
    require(record.get("fixtureOnly") is True and record.get("productionAdmission") is False,
            "Local provenance cannot claim production admission")
    claimed = record.get("recordSha256")
    payload = {name: value for name, value in record.items() if name != "recordSha256"}
    require(isinstance(claimed, str) and HASH.fullmatch(claimed)
            and claimed == hashlib.sha256(canonical_json(payload).encode()).hexdigest(),
            "Local provenance record was altered")
    sources = record.get("sourceSha256")
    require(isinstance(sources, dict) and bool(sources), "Missing provenance source inventory")
    for relative, expected in sources.items():
        require(isinstance(relative, str) and isinstance(expected, str) and HASH.fullmatch(expected),
                "Invalid provenance source identity")
        path = Path(relative)
        require(not path.is_absolute() and ".." not in path.parts, "Provenance source escapes repository")
        actual = root / path
        require(actual.is_file() and not actual.is_symlink() and actual.resolve().is_relative_to(root.resolve()),
                f"Missing plain provenance source: {relative}")
        require(sha256(actual) == expected, f"Stale provenance source: {relative}")
    current = source_identities(root, folder, [sources])
    require(set(current) == set(sources), "Provenance source/test inventory changed")
    require(record.get("toolchain") == tools, "Provenance toolchain changed")
    validate_test_results(record.get("smoke", []), required=record.get("requiredSmokeTests", []))
    fork = record.get("fork")
    require(isinstance(fork, dict) and type(fork.get("chainId")) is int and fork["chainId"] == 4663
            and type(fork.get("block")) is int and fork["block"] > 0
            and isinstance(fork.get("blockHash"), str) and re.fullmatch(r"0x[0-9a-fA-F]{64}", fork["blockHash"]),
            "Missing observed fork identity")
    require(bool(record.get("receipts", {}).get("modes")), "Missing actual per-mode receipts")
    validate_test_results(record.get("policy", []), allow_empty=True)
    require(all(row["status"] == SUCCESS for row in record.get("policy", [])), "Skipped policy tests cannot qualify")
    require(bool(record.get("requiredSmokeTests")), "Missing required smoke-test identity")
    return True


def write_record(path, record):
    require(not path.is_symlink(), "Provenance output must not be a symlink")
    temporary = path.with_name(".provenance.json.tmp")
    require(not temporary.exists(), "Remove stale provenance temporary file before recording")
    require(record.get("result") == "passed" and record.get("fixtureOnly") is True
            and record.get("productionAdmission") is False, "Cannot record incomplete qualification")
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(path)


def markdown_summary(label, rows):
    lines = [f"## {label}", "", "| Suite / test | Status |", "| --- | --- |"]
    for row in rows:
        name = f"{row['suite']}::{row['test']}".replace("|", "\\|")
        lines.append(f"| `{name}` | {row['status']} |")
    if not rows:
        lines.append("| No separate policy tests supplied | Not run |")
    return "\n".join(lines)
