## Submission

- Hook folder / contract / topology:
- `integration.json`:
- Formula and rounding:
- Changes from the reference, dependencies and added authority:
- Boundary cases and liveness risks:
- Required author payment rate, static/dynamic swap-fee declaration and registry bounds:

For tooling changes: describe the reason and catalogue-wide impact instead.

## Verification

- CI status (currently paused; do not dispatch) and registration-input report:
- Local commands actually run and results:
- Failed checks, unexercised cases and remaining risks:

## Contributor checklist

- [ ] Complete Solidity sources, `hook.json`, `integration.json` and `review.md` included.
- [ ] New hook uses `kind: submission` with a stable authorId, exact `developerFeeBps`, `swapFeeModel`, terms and five registry bounds.
- [ ] Typed constructor, zero pool LP fee, hook fee bounds, authentication, custody, treasury and oracle behavior preserved.
- [ ] Source rights and dependency licenses checked.
- [ ] Whole-catalogue checks passed, or missing/failed checks disclosed.

## Maintainer review

Record the decision in a review/comment against the current PR commit:

- [ ] Inspect local checks, input report and measured artifact hashes during the CI pause; require exact-head Actions evidence when CI is re-enabled.
- [ ] Review formula, boundaries, complete source/dependency graph and authority.
- [ ] Review proposed identity, required payment rate, fee model, terms and bounds; identify unproven claims.
- [ ] Review tooling/pin changes independently.

Decision: accept into catalogue / request changes / reject.

Catalogue acceptance is not registry admission. Author-control proof, economic approval, deployed graph and signed administrator registration remain separate.
