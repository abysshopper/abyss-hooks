---
name: hook-authoring
description: >-
  Create or modify an Abyss Hooks submission, including a static or dynamic fee
  policy, hook.json, integration.json, and review.md. Use for hook economics,
  oracle policy, and submission contract changes.
---
# Hook authoring

## Read the contract first

Read `CONTRIBUTING.md` sections Submission, Hook requirements, Fees and author payment, and Optional truncated oracle. Inspect `hooks/reference-bound/` for static policies or `hooks/dynamic-fee/` for dynamic policies, including their manifests and review. Read the shared base and any inherited template before overriding policy seams.

## Implement the requested policy

1. For a new submission, copy the appropriate reference into `hooks/<lowercase-kebab-case-slug>/`. Rename the source and concrete contract. Do not reuse reserved reference `kind` or slugs.
2. Keep the submission flat: only `hook.json`, `integration.json`, `review.md`, and local Solidity sources. No nested directories, symlinks, scripts, generated artifacts, or companion contracts. Preserve matching SPDX headers and a local `source` filename.
3. Confine every submission pull request to `hooks/<slug>/`. Never modify the shared harness (`contracts/test/`), tooling (`scripts/`), catalogue tests (`tests/`), maintainer docs (`CONTRIBUTING.md`, root `README.md`), or CI workflows to make a submission pass. If the hook needs new harness capability (for example a non-WETH quote or swap hookData), stop and report the missing capability so a maintainer can land it as a separate infrastructure change first.
4. Derive from `PoolBoundLaunchHookBaseV2` with its typed constructor. Use `PoolBoundTruncatedOracleV2` only for authenticated truncated history. Reuse the base's validation, callbacks, custody, and accounting; do not modify the approved base to accommodate a submission.
5. Declare `authorFeeBps()` and match `developerFeeBps` in the integration manifest. New submissions use `kind: submission` and a nonzero stable 20-byte `authorId`, not a live payout wallet. Do not fabricate an author's identity or consent; obtain missing author/economic terms from the contributor before completing a submission.
6. Static hooks charge the creator's configured maximum. Dynamic hooks explicitly declare `SwapFeeModel.Dynamic` and implement read-only `_calculateRate(LaunchHookFeeContextV2 memory)` within the frozen bounds. Preserve floor rounding, both fee modes, exact-input/output behavior, and rate freezing before oracle observations.
7. For oracle policies, cover genuine warm-up, flat/falling movement, idle decay, same-timestamp observations, and history rejection as applicable to the requested policy. Do not impose the reference dynamic formula on unrelated policies.
8. Update `hook.json` schema 1 and `integration.json` schema 2 without extra or duplicate fields. Use the exact field table and limits in `CONTRIBUTING.md`, including declared registry bounds and supported fee modes.
9. Update `review.md` with the formula, units, rounding, boundary vectors, potential reverts, dependencies, authority, risks, input rationale, and fresh verification evidence. Separate measured results from proposed terms and pending approval.

## Verify and hand off

Use the `hook-qualification` skill. For a fee-policy change, exercise the changed behavior in an appropriate Foundry fixture; do not rely only on previews or compilation. Measure actual artifact size under the pinned profile: the dynamic reference has limited runtime headroom, so do not assume additional code fits.

Report changed sources and declarations, executed checks, measured artifact evidence, and unresolved contributor inputs. Passing qualification does not authorize registry admission or prove control of `authorId`.
