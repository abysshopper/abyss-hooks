---
name: hook-qualification
description: >-
  Validate Abyss Hooks catalogue structure, run real fork-based hook
  qualification, diagnose runner or accounting failures, and review PR-REVIEW.md
  and registration-inputs evidence.
---
# Hook qualification and review

## Establish the boundary

Read `CONTRIBUTING.md` sections Local checks and PR review, `SECURITY.md`, and `.github/workflows/hooks.yml`. Use a disposable environment for untrusted submissions, with no wallet keys, credentials, or sensitive files. Qualification never broadcasts or grants production admission.

Check the requested validation level. Structure-only validation is useful for manifests and catalogue layout but provides no compiler, bytecode, launch, accounting, or royalty evidence. For Solidity or economics changes, run the changed behavior and full qualification rather than reporting structural acceptance as safety.

## Run the existing workflow

Use Python 3.12 and the Foundry release pinned in CI and `CONTRIBUTING.md`. Run commands from the repository root. Replace `<unique-run>` below with a new identifier for each invocation.

```sh
python3.12 -m pip install -r scripts/requirements.txt
python3.12 -m unittest discover -s tests
python3.12 scripts/check_hooks.py --structure-only --output evidence/structure-<unique-run>
scripts/install-deps.sh
forge test --match-path contracts/test/DynamicFeeRate.t.sol -vv
python3.12 scripts/check_hooks.py --output evidence/qualification-<unique-run> --rpc-url https://robinhood.drpc.org
```

The runner validates the whole catalogue. For a narrow source change, also exercise the applicable Foundry fixture or Python regression. Keep compiler settings, runtime/initcode limits, source provenance, independent reconstruction, chain ID, fork block/hash, and deployed-code hashes intact.

The default public RPC may reject fork reads with a Cloudflare challenge. `--rpc-url` selects an alternative endpoint, not a bypass for chain or code identity. Replaying old fork evidence requires an archive endpoint. If RPC access fails, retain the failure output and distinguish infrastructure failure from a hook result; do not downgrade the requested verification silently.

## Interpret evidence

Inspect fresh `PR-REVIEW.md`, each `<slug>.registration-inputs.json`, qualification results, build logs, and receipt evidence in the selected output directory.

- Separate declared author/economic inputs, file SHA256 pins, measured artifact evidence, derived registry fields, and pending admission inputs. File pins are not Solidity admission digests.
- Qualification deploys fresh actual V6 infrastructure using shipped `contracts/protocol/` sources against pinned real manager/oracle/WETH contracts. `contracts/config/robinhood.json` is historical V5 evidence; do not relabel those deployed actors as V6.
- Check coverage against the hook's declared modes and policy. Existing launch checks cover real swaps, wallet/delta accounting, treasury and royalty receipts, rejection paths, payout routing, and donation exclusion. They are not exhaustive coverage of every submitted bound or proof of arbitrary-runtime safety.
- Fixture author signatures and fork-only administration do not establish control of a submitted `authorId`. Production admission separately needs approved commitments, economics, graph, current author-controller authorization, and administrator submission.

For failures, diagnose the first failing stage using its logs and source, fix the responsible behavior, and rerun the affected path. Never relax validation, alter pins merely to accept unexplained drift, or change the compiler profile to hide a failure.

## Report

List commands executed, pass/fail status, fresh evidence directories, artifact sizes/hashes when measured, and missing checks or prerequisites. Do not include private keys or admission signatures in a PR. Do not claim audit, production approval, or exhaustive policy coverage from CI success.
