# Contributing

## Submission

Copy `hooks/reference-bound` to `hooks/<slug>`. Only `PoolBoundV4` submissions are supported. Use a lowercase kebab-case slug, rename the source and contract, and update the declarations.

Each folder must contain:

| File | Contents |
| --- | --- |
| `hook.json` | `schemaVersion: 1`, matching `name`, `topology`, `source`, `contract`, SPDX `license` |
| `integration.json` | Proposed registry inputs listed below |
| `review.md` | Formula and rounding; boundary inputs/outputs; changes, dependencies, authority and risks; input rationale and verification evidence |
| `*.sol` | Complete sources with matching SPDX headers |

Additional local Solidity files are allowed. No nested directories, symlinks, scripts, generated artifacts or other file types. `source` must be a local filename. `@black-market/` maps to the shipped `contracts/src/` authoring code and interfaces; Uniswap and Solady remappings are also available.

### Integration inputs

`integration.json` requires exactly these fields:

| Field | Accepted values |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `kind` | `submission`; `reference` is reserved for `reference-bound` |
| `authorId` | Nonzero `0x`-prefixed 20-byte address, identifying the stable author—not the live payout wallet |
| `maximumDeveloperFeeBps` | Integer `0..9999`; zero requests no developer allocation |
| `terms` | Nonempty string with the proposed author/economic terms |
| `bounds.minimumTickSpacing` | Integer `1..32767` |
| `bounds.maximumTickSpacing` | Integer `1..32767`, at least the minimum |
| `bounds.maximumPositions` | Integer `1..32` |
| `bounds.maximumOracleCardinality` | Integer `2..4096` |
| `bounds.feeModeFlags` | `1` InputToken, `2` QuoteOnly, `3` both |

Missing, extra or duplicate fields and incorrect numeric types are rejected. Qualification rejects a developer ceiling above the deployed registry's protocol maximum; it never clamps the proposal. The ceiling is not the swap-hook fee rate.

### Hook requirements

- Derive from `PoolBoundLaunchHookBaseV1`; preserve its typed constructor. Override only `_calculateFee`.
- Use full-precision arithmetic. Fees cannot exceed `floor(amount * maximumPips / 1_000_000)` or `int128.max`. Disclose rounding, thresholds and potential reverts.
- Preserve manager-only callbacks, mask `0x1afc` under `0x3fff`, one-time registrar binding and exact full-key checks.
- Preserve permanent liquidity custody, fee-only accounting, backing, settlement and collector-only collection. Donations are not fees.
- Preserve treasury arithmetic: `denominator == 0 ? 0 : (grossHookFee / denominator) * 125 / 100`; nonzero denominators are `4..10`.
- Preserve genuine oracle history and pre-genesis rejection. Capacity does not establish mature lookback.
- Keep developer payments in the downstream fee hub. No hook-level author payment, sweep, upgrade or recipient-selection extension.

The [base](contracts/src/hooks/v4/authoring/PoolBoundLaunchHookBaseV1.sol) and [typed deployer](contracts/src/hooks/v4/authoring/PoolHookDeployerV1.sol) define the authoring contract. `scripts/upstream.json` records source provenance; no private repository checkout is needed.

## Local checks

Use Python 3.12 and Foundry `nightly-5e88010a83d1b87b8f4d13058e42a2949d3e9dc0`. Run untrusted submissions in a disposable environment without credentials or wallet keys.

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements.txt
python -m unittest discover -s tests
python scripts/check_hooks.py --structure-only --output evidence/structure
scripts/install-deps.sh
python scripts/check_hooks.py --output evidence/qualification
```

Use fresh evidence directories on subsequent runs. All hooks are checked. Compilation uses Solidity 0.8.28, Cancun, optimizer runs 1, no via-IR or bytecode metadata. Runtime/initcode limits are 24,576/49,152 bytes. The reference has 66 bytes of runtime headroom.

Qualification resolves the public RPC's latest block once, records its number/hash, and verifies every deployed code hash. `--rpc-url` can select another Robinhood RPC. Replaying older evidence requires an archive endpoint.

## PR review

Use the [PR template](.github/pull_request_template.md). Link the current Actions run and disclose missing or failed checks.

Review `PR-REVIEW.md` and `<slug>.registration-inputs.json` from the Actions artifacts. Reports separate declared inputs, file SHA256 pins, measured artifact evidence, derived registry fields and pending admission inputs. File pins are not Solidity admission digests.

CI independently reconstructs the submitted artifact, then runs a real standard ERC20 launch with one WETH pool on a local fork. It exercises every declared fee mode, exact-input/output swaps in both directions, and exact treasury, executor, owner and developer receipts. The scenario uses the proposed developer ceiling, minimum tick spacing, maximum oracle cardinality and one LP position; it is not exhaustive bounds coverage. The reference uses a 500-bps fixture allocation.

Adapter and locker creation bytes come from the public transactions recorded in `contracts/config/robinhood.json`. Local fixture admission uses fork-only administrator impersonation and a test author signature. CI has no wallet credentials and never broadcasts. This does not prove control of the submitted `authorId` or establish arbitrary-runtime safety.

Registry admission remains separate: approved artifact/review/terms commitments, target economics and deployed graph, exact envelope/profile/registration, current author-controller authorization and administrator submission. Obtain authorization from the target registry's `authorizationDigest`. Do not include private keys or admission signatures in the initial PR.
