---
name: pr-review
description: >-
  Review an Abyss Hooks submission pull request: ownership scope, CI coverage,
  declared-versus-proven claims, authority and liveness analysis. Use when
  reviewing contributor hook PRs or registration evidence.
---
# Submission PR review

## Check ownership scope first

A submission pull request may only add or change files under its own `hooks/<slug>/`. Everything else is maintainer-owned:

- `contracts/src/`, `contracts/protocol/`, `contracts/test/`: base, protocol sources, shared harness
- `scripts/`, `tests/`: qualification tooling and catalogue regressions
- `CONTRIBUTING.md`, root `README.md`, `.github/workflows/`: maintainer docs and CI

If any of these appear in a submission diff, request a split regardless of code quality: the hook in one PR, the infrastructure capability in a separate maintainer-reviewed PR. A hook that cannot pass the unchanged harness must disclose that and wait for infrastructure to land first; bundling the harness change into the submission reverses the ownership direction.

Verify the contributor's "no base change" claim rather than trusting it: `git diff <base> -- contracts/src` must be empty, and existing reference hooks must compile byte-identical (compare runtime and initcode SHA-256 against a clean base checkout).

## Require independent verification

- CI must have run on the exact head commit. No reported checks means nothing is verified; never merge on local claims alone.
- Separate declared inputs (`integration.json` values, terms, authorId) from proven behavior (qualification evidence). Declarations are proposals, not facts.
- Reproduce locally when feasible: structure check, unit suite, and full fork qualification per the `hook-qualification` skill. Compare measured artifact sizes and hashes against the PR's claims.
- Watch for coverage gaps the harness cannot see. Example: a fork-only permissive signature authority proves gating logic but not the real signature scheme—if the hook verifies EIP-712/ECDSA passes, require at least one end-to-end check against a real test key, not only an etched accept-all account.

## Review authority and liveness

For each external call, constant address, stored credential or signature check, answer: who can act, what happens if the key is lost, and what happens if it is compromised. Acceptable answers must be stated in `review.md`. Permanent loss of a non-custodial liveness gate (for example buys halted while sells and fee collection continue) may be acceptable when disclosed; undisclosed upgrade, sweep, or recipient-selection authority is not.

Flag fragile coupling explicitly: reading another contract's calldata (`msg.data`), depending on `tx.origin`, or relying on a private-by-convention call path all couple the hook to the pinned base artifact. These are permissible only when the artifact is pinned and the failure mode degrades to a no-op rather than a false acceptance.

## Report

Record the decision against the exact head commit: accept into catalogue, request changes, or reject. List verified claims with evidence, unproven claims, scope violations, and required follow-ups. Catalogue acceptance is not production registry admission, an audit, or proof of `authorId` control.
