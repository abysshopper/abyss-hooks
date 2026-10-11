---
name: pr-review
description: "Review an Abyss Hooks submission and self-review before opening or updating a PR: ownership, local smoke/policy qualification and compact provenance, declared-versus-proven claims, authority and liveness. Use for contributor hook PRs and registration evidence."
targets: ["*"]
---
# Submission PR review

## Self-review before opening or updating

Before opening a PR or pushing updates to an existing PR, review the complete proposed diff against its target base using this skill. Apply it to hook submissions; for maintainer infrastructure PRs, review the applicable verification, authority and reporting criteria without imposing hook-folder-only scope. Fix actionable findings before publishing. Re-review the complete diff after fixes, not just the latest patch.

Use the `hook-qualification` skill and local contributor command: `python3.12 scripts/check_hooks.py --hook <slug> --output evidence/<unique-run> --rpc-url https://robinhood.drpc.org --record`. Report commands actually run, named smoke/policy results, actual receipts, evidence paths, failures and missing prerequisites. Review the compact `hooks/<slug>/provenance.json` with matching sources/tests; do not attach full credential-bearing logs. `--check-provenance` checks recorded identity, not a chain rerun. When CI is enabled, inspect exact-head Actions and their artifacts before requesting acceptance. During the documented maintainer CI pause, do not dispatch, enable or wait for Actions; record the reviewed head, actual local evidence and unrun checks, and state "CI not run: explicitly paused". Self-review does not replace independent maintainer review.

For technical hook auditing, apply the `hook-security-review` skill. Its official documentation and public-audit lessons supplement, not replace, repository-specific qualification and independent audits.

## Check ownership scope first

A submission pull request may only add or change files under its own `hooks/<slug>/`. Everything else is maintainer-owned:

- `contracts/src/`, `contracts/protocol/`, `contracts/test/`: base, protocol sources, shared harness
- `scripts/`, `tests/`: qualification tooling and catalogue regressions
- `CONTRIBUTING.md`, root `README.md`, `.github/workflows/`: maintainer docs and CI

If any of these appear in a submission diff, request a split regardless of code quality: the hook in one PR, the infrastructure capability in a separate maintainer-reviewed PR. A hook that cannot pass the unchanged harness must disclose that and wait for infrastructure to land first; bundling the harness change into the submission reverses the ownership direction.

Within the contributor folder, require flat production sources and `test/Smoke.t.sol`; allow separate policy `test/*.t.sol` suites and Solidity fixtures plus successful runner-generated compact `provenance.json`. No other nested directories or generated output. Require `<hook.json contract>SmokeTest` inheriting `HookSmokeTest` with an actual artifact descriptor. No candidate code substitution, deployment override, missing or skipped mandatory inherited tests. Review test-side quote/configuration, prerequisites and genuinely signed hookData; mutable setup is an assumption, not a sandbox or proof of safety. Policy suites cannot replace shared nonvirtual invariants.

Verify the contributor's "no base change" claim rather than trusting it: `git diff <base> -- contracts/src` must be empty. When artifact stability is claimed, compare decoded runtime and initcode bytes against a clean base build using the pinned compiler profile.

## Require independent verification

- When CI is enabled, require successful exact-head checks and inspect their evidence. During the maintainer-authorized CI pause, do not dispatch or wait for runs; use applicable local checks and explicitly state that CI did not run. Missing CI is not successful CI.
- Separate declared inputs (`integration.json` values, terms, authorId) from proven behavior (qualification evidence). Declarations are proposals, not facts.
- Reproduce selected-hook mandatory smoke and all separate policy suites per the `hook-qualification` skill; infrastructure changes also need applicable structure, Python and maintainer fixture checks. Compare measured artifact sizes/hashes and compact provenance identity against the PR's claims. Reuse applicable observed evidence only when code and inputs are unchanged; label reused evidence explicitly. A fresh provenance identity check does not establish current-chain results.
- Watch for coverage gaps the harness cannot see. A fork-only permissive signature authority proves gating logic but not the real signature scheme. For EIP-712/ECDSA passes, require a genuinely signed end-to-end test using an independently constructed digest and a real test key, including buyer, domain, signed-field and replay rejection. Do not require or expose production private keys.

## Review authority and liveness

For each external call, constant address, stored credential or signature check, answer: who can act, what happens if the key is lost, and what happens if it is compromised. State these risks in `review.md`. Disclosed non-custodial liveness gates may be acceptable; undisclosed upgrade, sweep, or recipient-selection authority is not. Check inherited and external halt conditions before claiming holders can always exit.

Flag fragile coupling explicitly: decoding `msg.data`, depending on `tx.origin`, or relying on an internal call path couples the hook to the pinned artifact. Trace actual reachability and bypass conditions; artifact pinning alone does not prove safety. Distinguish a demonstrated bypass from a disclosed future-change risk.

## Report

Record the decision against the exact head commit: accept into catalogue, request changes, or reject. For self-review, report readiness and unresolved findings without granting maintainer approval. List verified claims with evidence, unproven claims, scope violations, and required follow-ups. Catalogue acceptance is not production registry admission, an audit, or proof of `authorId` control.
