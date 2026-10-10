"""Execute exact contributor smoke/policy artifacts and print their observed results."""
from __future__ import annotations

import json
import subprocess


def qualify_candidate(checks, output, folder, row, manifest, environment, resolved_config, solc, tools):
    results, artifacts, smoke_checks = checks.results, checks.artifacts, checks.smoke_checks
    root = checks.ROOT
    label = row["name"]
    print(f"\nQualifying {label}: required smoke + contributor policy tests", flush=True)
    candidate = output / label
    candidate.mkdir()
    report_path = output / f"{label}.registration-inputs.json"
    report = artifacts.load_json(report_path.read_bytes())
    result = {"locallyQualified": False, "fixtureOnly": True, "productionAdmission": False}
    summary = [f"# {label} local qualification", "", "GitHub CI not run: explicitly paused.", ""]
    try:
        checks.require(checks.submission_source_hashes(folder) == report["sourceFileSha256"], "Submission changed after input review")
        selected = candidate / "qualified-hook-artifact.json"
        selected.write_bytes((root / "out" / row["source"] / f"{row['contract']}.json").read_bytes())
        selected.chmod(0o444)
        source = str((folder / row["source"]).relative_to(root))
        measured, pins, rebuilt = reconstruct_selected(checks, selected, source, row["contract"], candidate, solc)
        result["artifactEvidence"] = measured
        report["measuredArtifact"] = measured
        smoke_source = str((folder / "test" / checks.SMOKE_FILE).relative_to(root))
        smoke_contract = row["contract"] + "SmokeTest"
        test_artifact = root / "out" / checks.SMOKE_FILE / f"{smoke_contract}.json"
        test_measured, test_pins, test_rebuilt = reconstruct_selected(
            checks, test_artifact, smoke_source, smoke_contract, candidate, solc,
            portability=False, label="smoke-reconstruction")
        required = smoke_checks.verify_inheritance(
            test_rebuilt, base_path=checks.SMOKE_BASE, smoke_path=smoke_source, smoke_contract=smoke_contract)
        result["requiredSmokeTests"] = required
        result["smokeArtifact"] = test_measured
        all_sources = results.source_identities(root, folder, [pins, test_pins])
        checks.require(all(name not in checks.input_snapshot or checks.input_snapshot[name] == digest
                           for name, digest in all_sources.items()), "Inputs changed after qualification started")
        inventory_before = results.source_identities(root, folder, [pins, test_pins])
        checks.save_json(candidate / "source-manifest.json", {"sources": all_sources})
        candidate_manifest = candidate / "robinhood.json"
        checks.save_json(candidate_manifest, manifest)
        candidate_manifest.chmod(0o444)
        receipts = candidate / "receipt-evidence.json"
        env, inputs = checks.candidate_environment(report["declared"], selected, candidate_manifest, receipts, environment)
        abi = artifacts.load_json(rebuilt["contracts"][source][row["contract"]]["metadata"])["output"]["abi"]
        has_oracle = any(item.get("type") == "function" and item.get("name") == "observeTruncated"
                         and [argument["type"] for argument in item["inputs"]] == ["bytes32", "uint32[]"] for item in abi)
        env["HOOK_HAS_ORACLE"] = "true" if has_oracle else "false"
        inputs["HOOK_HAS_ORACLE"] = has_oracle
        env["FOUNDRY_TEST"] = str((folder / "test").relative_to(root))
        inputs["FOUNDRY_TEST"] = env["FOUNDRY_TEST"]
        env["FOUNDRY_FUZZ_SEED"] = "0x" + "01" * 32
        config = candidate / "local-tests.foundry.toml"
        config.write_text(resolved_config + '\n[[profile.default.fs_permissions]]\naccess = "read-write"\npath = '
                          + json.dumps(str(candidate)) + "\n")
        env["FOUNDRY_CONFIG"] = str(config)
        inputs["FOUNDRY_CONFIG"] = str(config)
        checks.save_json(candidate / "runtime-inputs.json", inputs)
        discovery = artifacts.load_json(checks.run(["forge", "test", "--list", "--json", "--match-path", smoke_source],
                                                   root, candidate, "smoke-discovery", env))
        discovered = smoke_checks.discovery_tests(discovery, smoke_source, smoke_contract)
        checks.require(set(required).issubset(discovered), "Mandatory smoke tests missing from Foundry discovery")
        command = ["forge", "test", "--fork-url", manifest["rpcUrl"], "--fork-block-number", str(manifest["forkBlock"]),
                   "--root", str(root), "--json", "-vv"]
        report["runtimeQualification"] = {"passed": False, "status": "running", "fixtureOnly": True}
        checks.save_json(report_path, report)
        policy_files = [path for path in (folder / "test").iterdir()
                        if path.name.endswith(".t.sol") and path.name != checks.SMOKE_FILE]
        policy_discovery = {}
        if policy_files:
            policy_discovery = artifacts.load_json(checks.run(
                ["forge", "test", "--list", "--json", "--match-path", str(folder.relative_to(root)) + "/test/*.t.sol",
                 "--no-match-path", smoke_source], root, candidate, "policy-discovery", env))
            expected_policy = []
            policy_inventories = []
            for path in policy_files:
                relative = str(path.relative_to(root))
                contracts = policy_discovery.get(relative)
                checks.require(isinstance(contracts, dict) and bool(contracts), f"Policy test file was not discovered: {relative}")
                for contract, names in contracts.items():
                    checks.require(bool(names), f"Policy contract has no discovered tests: {contract}")
                    policy_artifact = root / "out" / path.name / f"{contract}.json"
                    policy_bytes = artifacts.load_json(policy_artifact.read_bytes())
                    for signature in checks.smoke_checks.test_signatures(policy_bytes["abi"], names):
                        expected_policy.append((relative + ":" + contract, signature))
                    _, policy_pins, _ = reconstruct_selected(
                        checks, policy_artifact, relative, contract, candidate, solc, portability=False,
                        label="policy-reconstruction-" + path.stem.removesuffix(".t") + "-" + contract)
                    policy_inventories.append(policy_pins)
            for inventory in policy_inventories:
                for name, entry in inventory.items():
                    checks.require(name not in inventory_before or inventory_before[name] == entry["sha256"],
                                   f"Policy dependency changed after build: {name}")
                    inventory_before[name] = entry["sha256"]
            all_sources = results.source_identities(root, folder, [pins, test_pins, *policy_inventories])
            checks.save_json(candidate / "source-manifest.json", {"sources": all_sources})
        smoke_rows = execute_tests(checks, command + ["--match-path", smoke_source, "--match-contract", f"^{smoke_contract}$"],
                                   candidate, "smoke-results", env, required=required, suite=smoke_contract)
        result["smoke"] = smoke_rows
        summary.append(results.markdown_summary("Required smoke", smoke_rows))
        smoke_receipts = checks.receipt_evidence(receipts, manifest, report["declared"])
        checks.save_json(candidate / "smoke-receipts.json", smoke_receipts)
        policy_rows = []
        if policy_files:
            policy_rows = execute_tests(checks, command + ["--match-path", str(folder.relative_to(root)) + "/test/*.t.sol",
                                                            "--no-match-path", smoke_source],
                                        candidate, "policy-results", env)
            checks.require({(item["suite"], item["test"]) for item in policy_rows} == set(expected_policy),
                           "Executed policy tests differ from discovery")
            checks.require(all(item["status"] == "Success" for item in policy_rows),
                           "Policy tests must pass; skipped cases cannot qualify")
        result["policy"] = policy_rows
        summary.append(results.markdown_summary("Policy tests", policy_rows))
        require_inventories = [pins, test_pins, *(policy_inventories if policy_files else [])]
        checks.require(results.source_identities(root, folder, require_inventories) == all_sources,
                       "Source/test/harness inputs changed during qualification")
        checks.require(results.sha256(selected) == measured["fileSha256"], "Selected artifact changed during execution")
        checks.require(artifacts.load_json(candidate_manifest.read_bytes()) == manifest, "Fork manifest changed during execution")
        checks.require(results.source_identities(root, root / "hooks", [checks.input_snapshot]) == checks.input_snapshot,
                       "Repository qualification inputs changed during execution")
        result.update(locallyQualified=True, receiptEvidence=smoke_receipts)
        record = results.make_record(root=root, folder=folder, sources=all_sources, tools=tools, manifest=manifest,
                                     artifact=measured, smoke=smoke_rows, policy=policy_rows, receipts=smoke_receipts,
                                     required=required)
        checks.save_json(candidate / "provenance.json", record)
        for mode in smoke_receipts["modes"]:
            print(f"  mode {mode['feeMode']}: {mode['tradeCount']} trades; hook fees={mode['hookFeesCollected']}; "
                  f"treasury={mode['treasuryPaid']}; owner={mode['ownerPaid']}; author={mode['authorPaid']}", flush=True)
        summary.extend(["", "## Receipts", "", "```json", json.dumps(smoke_receipts, indent=2), "```"])
        report["runtimeQualification"] = {
            "passed": True, "status": "passed", "fixtureOnly": True,
            "scope": "Executed required smoke and separate contributor policy suites",
            "declaredBoundsAndEconomicsExhaustivelyExecuted": False,
            "evidence": f"{label}/qualification-result.json",
        }
        return result, record
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result["error"] = str(error)
        report["runtimeQualification"] = {"passed": False, "status": "failed", "fixtureOnly": True, "error": str(error)}
        summary.extend(["", "## Failed", "", str(error)])
        raise
    finally:
        (candidate / "RESULTS.md").write_text("\n\n".join(summary) + "\n")
        checks.save_json(report_path, report)
        checks.save_json(candidate / "qualification-result.json", result)


def reconstruct_selected(checks, path, source, contract, candidate, solc, *, portability=True, label="compiler-reconstruction"):
    artifacts = checks.artifacts
    measured = artifacts.artifact_evidence(path, enforce_portability=portability)
    metadata = artifacts.artifact_metadata(artifacts.load_json(path.read_bytes()), path)
    checks.require(metadata["settings"]["compilationTarget"] == {source: contract}, "Artifact target collision or mismatch")
    pins = artifacts.source_inventory(measured, checks.ROOT)
    measured["compilerReconstruction"] = artifacts.reconstruct_artifact(
        measured, pins, root=checks.ROOT, solc=solc, output=candidate / label)
    measured["compilerSourceCorrespondenceVerified"] = True
    return measured, pins, artifacts.load_json((candidate / label / "compiler-output.json").read_bytes())


def execute_tests(checks, argv, candidate, label, environment, *, required=(), suite=None, allow_empty=False):
    completed = subprocess.run(argv, cwd=checks.ROOT, env=environment, text=True, capture_output=True)
    (candidate / f"{label}.stdout.log").write_text(completed.stdout)
    (candidate / f"{label}.stderr.log").write_text(completed.stderr)
    checks.save_json(candidate / f"{label}.command.json", {"argv": argv, "returnCode": completed.returncode})
    payload = checks.smoke_checks.parse_foundry_output(completed.stdout)
    checks.save_json(candidate / f"{label}.json", payload)
    rows = checks.results.result_rows(payload)
    checks.results.print_rows(label, rows)
    checks.results.validate_test_results(rows, required=required, suite=suite, allow_empty=allow_empty)
    checks.require(completed.returncode == 0, f"{label} failed; inspect {candidate}")
    return rows
