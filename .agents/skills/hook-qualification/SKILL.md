---
name: hook-qualification
description: >-
  Run contributor-local selected-hook mandatory smoke and separate policy
  qualification, record and review commit-ready provenance.json, check recorded
  identity freshness, and diagnose fork/artifact/accounting failures. Use for
  hook authoring, submission review and local qualification evidence, not remote
  CI dispatch.
---
# Hook qualification and review

## Establish the boundary

Read `CONTRIBUTING.md` sections Contributor smoke and policy tests, Local checks and PR review, and `SECURITY.md`. Use a disposable environment for untrusted submissions, with no wallet keys, credentials or sensitive files. Qualification never broadcasts or grants production admission. Automatic GitHub CI is paused: do not enable, dispatch or wait for a remote run; explicitly disclose that CI did not run.

Check the requested validation level. Structure-only validation is useful for manifests and catalogue layout but provides no compiler, bytecode, launch, accounting, or royalty evidence. For Solidity or economics changes, run the changed behavior and full qualification rather than reporting structural acceptance as safety.

## Run local contributor qualification

Use Python 3.12 and the Foundry release pinned in `CONTRIBUTING.md`. Run commands from the repository root. Replace `<slug>` with the selected hook folder and `<unique-run>` with a new identifier for each invocation.

```sh
python3.12 -m pip install -r scripts/requirements.txt
scripts/install-deps.sh
python3.12 scripts/check_hooks.py --hook <slug> --output evidence/<unique-run> --rpc-url https://robinhood.drpc.org --record
```

The runner independently reconstructs the selected artifact and discovers `hooks/<slug>/test/`. Mandatory `Smoke.t.sol` defines `<hook.json contract>SmokeTest` inheriting maintainer-owned `HookSmokeTest`, with a constructor descriptor pointing to the actual hook, such as `HookSmokeTest("hooks/dynamic-fee/DynamicFeeHook.sol:DynamicFeeHook")`. The shared fixture verifies creation-code identity; do not override deployment or `vm.etch` candidate code.

All inherited public nonvirtual `testSmoke*` tests are required. The runner checks compiler-AST inheritance and base-ABI required names; missing, skipped or failed mandatory cases cannot qualify. Separate policy `*.t.sol` suites, such as `Policy.t.sol` and `Rate.t.sol`, carry formula, rounding, oracle, malformed-data and signature/replay coverage, not replacements for baseline accounting/lifecycle invariants.

Configure quote/raw-unit funding, supply, liquidity, price/ticks, creator fee/oracle settings, opening buy and trade amounts on the test side. Reuse virtual prerequisite setup and `_swapHookData(PoolKey memory, SwapParams memory, address payer)` for genuine signed data, not qualification-only production quote/signer getters. Intentional policy refusals use `_expectedSwapRevert(...)` and assert rejection plus unchanged wallets/liabilities. Evaluate all four swap branches and show actual successful trades under valid scenarios in each declared fee mode; do not require every policy to admit every amount mode. Free-fee hooks and zero author rates remain valid when declared exactly.

The scenario may select `preparedOracleCardinality` independently of populated history. A zero-fee configuration refusal uses `_expectedZeroFeeLaunchRevert(LaunchPlanV1)` with test-only `LaunchRefusalStage.Prepare` or `Activate` and exact observed revert bytes; empty bytes require successful zero-fee accounting. Neither branch skips the inherited mandatory case.

Review mutable setup, overrides and cheatcodes as assumptions, not a sandbox or proof of arbitrary-runtime safety. Keep compiler settings, production runtime/initcode limits, source provenance, independent reconstruction, chain ID, fork block/hash and deployed-code hashes intact.

For maintainer infrastructure changes, additionally run applicable Python regressions (`python3.12 -m unittest discover -s tests`), relevant Foundry fixtures and structure-only validation (`python3.12 scripts/check_hooks.py --structure-only --output evidence/structure-<unique-run>`). Omit `--hook` for catalogue-wide qualification. Internal oracle/custom-adapter fixtures are maintainer checks, not catalogue hooks.

The default public RPC may reject fork reads with a Cloudflare challenge. `--rpc-url` selects an alternative endpoint, not a bypass for chain or code identity. Replaying old fork evidence requires an archive endpoint. If RPC access fails, retain the failure output and distinguish infrastructure failure from a hook result; do not downgrade the requested verification silently.

## Interpret evidence

The runner prints named test statuses/results and actual receipt summaries, and writes full ignored logs, JSON and `RESULTS.md` in the chosen output directory. Inspect those fresh smoke and policy results separately, along with receipts, `PR-REVIEW.md` and `<slug>.registration-inputs.json`. False, failed or incomplete results do not qualify; retain failure output rather than representing it as success.

- Separate declared author/economic inputs, file SHA256 pins, measured artifact evidence, derived registry fields, and pending admission inputs. File pins are not Solidity admission digests.
- `contracts/protocol/` is an external Black Market source snapshot used only to create isolated launch-test infrastructure. `contracts/config/robinhood.json` identifies fork venues and a historical reference envelope, not candidate production admission. File hashes identify imported dependency bytes, not restrictions on contributor policies.
- Check coverage against the hook's declared modes and policy. Existing launch checks cover real swaps, wallet/delta accounting, treasury and royalty receipts, rejection paths, payout routing, and donation exclusion. They are not exhaustive coverage of every submitted bound or proof of arbitrary-runtime safety.
- Fixture author signatures and fork-only administration do not establish control of a submitted `authorId`. Production admission separately needs approved commitments, economics, graph, current author-controller authorization, and administrator submission.
- Automatic GitHub CI is temporarily paused. Do not dispatch or wait for a workflow; run applicable local checks and disclose missing CI. Restore exact-head Actions verification when the pause ends.

For failures, diagnose the first failing stage using its logs and source, fix the responsible behavior, and rerun the affected path. Never relax validation, alter pins merely to accept unexplained drift, or change the compiler profile to hide a failure.

## Review and commit compact provenance

`--record` is optional and writes `hooks/<slug>/provenance.json` only after successful full qualification; it never commits or pushes. Failed/incomplete runs do not write or replace a success record. An existing record does not qualify a subsequent failed run.

Review the compact record's source/test file hashes, harness/protocol/tool identity, artifact creation/runtime identity, source-commit working-tree caveat, chain/block/hash, named cases and actual receipts. Hashes identify bytes; HEAD alone does not identify dirty sources. The provenance file excludes itself from the hashed inputs.

After review, commit the selected compact record with matching hook sources, tests, manifests and `review.md`, and reference that file in the GitHub PR. Full logs/JSON/`RESULTS.md` remain in ignored local output; do not commit credential-bearing logs, wallet keys or production admission signatures.

```sh
python3.12 scripts/check_hooks.py --hook <slug> --check-provenance
```

This checks recorded source, test, harness and tool identity freshness. It does not rerun the chain, establish current-chain behavior, prove author control or provide a signed attestation. Changed inputs require fresh full qualification and a reviewed replacement record.

## Report

List commands executed, pass/fail status, separate smoke/policy results, actual receipts, fresh evidence paths, reviewed compact provenance, artifact sizes/hashes when measured, and missing checks or prerequisites. Explicitly state that GitHub CI did not run during the pause. Do not include credentials, private keys or admission signatures in a PR. Do not claim audit, production approval, signer consent or exhaustive policy coverage from qualification success.
