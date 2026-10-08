# Contributing

## Submission

Copy `hooks/reference-bound` for static fees or `hooks/dynamic-fee` for a custom dynamic schedule into `hooks/<slug>`. Only `PoolBoundV4` submissions are supported. Use a lowercase kebab-case slug, rename the source and contract, and update the declarations.

Each folder must contain:

| File | Contents |
| --- | --- |
| `hook.json` | `schemaVersion: 1`, matching `name`, `topology`, `source`, `contract`, SPDX `license` |
| `integration.json` | Proposed registry inputs listed below |
| `review.md` | Formula and rounding; boundary inputs/outputs; changes, dependencies, authority and risks; input rationale and verification evidence |
| `*.sol` | Complete sources with matching SPDX headers |

Additional local Solidity files are allowed. No nested directories, symlinks, scripts, generated artifacts or other file types. `source` must be a local filename. `@black-market/` maps to the shipped `contracts/src/` authoring code and interfaces; Uniswap and Solady remappings are also available.

Submission pull requests may only add or change files under `hooks/<slug>/`. The shared test harness, tooling, catalogue tests, documentation and CI workflows are maintainer-owned; if a hook needs new harness capability, open an issue or a separate infrastructure pull request instead of bundling it into the submission.

### Integration inputs

`integration.json` requires exactly these fields:

| Field | Accepted values |
| --- | --- |
| `schemaVersion` | Integer `2` |
| `kind` | `submission`; `reference` is reserved for `reference-bound` and `dynamic-fee` |
| `authorId` | Submission: nonzero `0x`-prefixed 20-byte stable author ID—not the live payout wallet; reference: `null` |
| `developerFeeBps` | Integer `0..9999`; required author share of attributed owner proceeds after bounty; zero means free |
| `swapFeeModel` | `static` or `dynamic`, matching the hook declaration |
| `terms` | Nonempty string with the proposed author/economic terms |
| `bounds.minimumTickSpacing` | Integer `1..32767` |
| `bounds.maximumTickSpacing` | Integer `1..32767`, at least the minimum |
| `bounds.maximumPositions` | Integer `1..32` |
| `bounds.maximumOracleCardinality` | Integer `2..4096` |
| `bounds.feeModeFlags` | `1` InputToken, `2` QuoteOnly, `3` both |

Missing, extra or duplicate fields and incorrect numeric types are rejected. The required author rate must fit the target registry's protocol maximum; qualification never clamps it. The reference declares 500 bps as an example, not a platform default.

### Hook requirements

- Derive from `PoolBoundLaunchHookBaseV2`; preserve its typed constructor. The base works without a fee-calculation override and contains no oracle history. Inherit the optional `PoolBoundTruncatedOracleV2` template when your hook needs that feature.
- Override `authorFeeBps()` to declare your required payment rate; its default is zero. Match it in `integration.json`. Do not supply a payout address.
- Pool LP fees must be zero. Static is the default: charge the creator's configured trading fee through hook deltas. Only explicitly dynamic hooks override `swapFeeModel()` and `_calculateRate(LaunchHookFeeContextV2 memory)`.
- Dynamic rates must stay between the creator's configured minimum and maximum. The base snapshots both bounds before invoking the policy, freezes one rate before each swap and applies full-precision `floor(amount * rate / 1_000_000)` charges, bounded by `int128.max`. Disclose the formula, rounding and potential reverts.
- Preserve manager-only callbacks, mask `0x1afc` under `0x3fff`, one-time registrar binding and exact full-key checks.
- Preserve permanent liquidity custody, fee-only accounting, backing, settlement and collector-only collection. Donations are not fees.
- Preserve treasury arithmetic: `denominator == 0 ? 0 : (grossHookFee / denominator) * 125 / 100`; nonzero denominators are `4..10`.
- If composing the oracle, preserve genuine history and pre-genesis rejection. Capacity does not establish mature lookback.
- Keep developer payments in the downstream fee hub. No hook-level author payment, sweep, upgrade or recipient-selection extension.

The [base](contracts/src/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol) and [typed deployer](contracts/src/hooks/v4/authoring/PoolHookDeployerV1.sol) define the authoring contract. `scripts/upstream.json` records source provenance; no private repository checkout is needed. Submit one concrete hook contract. Inherited abstract templates and internal library code compile into that hook; the base performs validation itself and does not deploy a helper. Do not modify the approved base or deploy custom companion contracts.

### Fees and author payment

```solidity
function authorFeeBps() public pure override returns (uint16) {
    return 500; // 5% of attributed owner proceeds after bounty, not 5% of a swap.
}
```

Maintainers review the complete artifact and terms, deploy the approved graph, and register the signed profile with the stable `authorId`. The existing registry field `maximumDeveloperFeeBps` is set to the approved required rate. Launch builders must set `developerFeeBps` to that exact rate; the hook rejects a different frozen hub rate before acquiring liquidity. Registration and initialization precede the hub's terms binding, so enforcement occurs at the first liquidity callback, not registration.

The hub allocates the author's share once from source-attributed owner proceeds, after the executor bounty and owner/rewards/burn split. These hooks generate hook-fee proceeds, not LP fees. It pays the registry's current payout for the stable author ID. Neither the hook nor the collector transfers a second author fee. Payment terms do not change the creator's selected disposition policy.

Launch builders use `V4MarketConfigV6` and the 20-word `PoolBoundHookParametersV2` constructor tuple. Set `lpFeePips: 0`, maximum `hookFeePips`, independent `minimumHookFeePips`, and `feeSensitivityPipsSecondsPerTick` immediately after the maximum. Require `0 <= minimum <= maximum <= 1_000_000` and uint32 sensitivity, including zero. All three settings are creator-selected per pool and frozen before salt mining; constructor identity, CREATE2 and the salt-normalized market commitment bind them. Static hooks charge the maximum. `poolConfig()` retains its existing ABI; the two new getters expose the frozen policy settings. `feeRate(SwapParams)` previews a current-state rate, not a guaranteed execution quote or eventual exact-output amount. Do not add author bps to swap pips or combine different currencies into one raw rate.

`InputToken` collects the trader's input asset, so fees can accrue in either pool token across directions. `QuoteOnly` collects the quote asset in both directions. `feeModeFlags: 3` permits either selection; it does not charge both currencies on the same swap. The base also rejects a nonzero PoolManager protocol fee before trading rather than silently adding a second fee; governance enabling one will stop swaps until it is cleared.

For a dynamic hook, explicitly return `SwapFeeModel.Dynamic` and implement the read-only `_calculateRate`. Its typed context includes pool ID, pre-swap price/liquidity, original signed request, direction, minimum, maximum, sensitivity and fee currency mode. A static declaration never invokes that override. A composed policy may additionally read its inherited oracle's authenticated history; the core acquires no oracle dependency.

[`DynamicFeeHook`](hooks/dynamic-fee/DynamicFeeHook.sol) raises fees with observed upward quote-per-base tick velocity, not trade size. For creator-selected minimum `m`, maximum `M`, sensitivity `G` in fee-pips × seconds/tick, positive observed tick change `D`, and age-adjusted elapsed seconds `E`, the rate is `min(M, m + floor(G * D / E))`. Warm-up, flat/falling observations or missing elapsed time use `m`; idle time reduces the uplift. Zero `G` fixes the rate at `m`, and maximum zero is free. There is no maximum-derived baseline or fixed response period. Exact input/output and both fee modes use the same schedule. The [example review](hooks/dynamic-fee/review.md) defines measurement, rounding and risks.

### Provided accounting

The base supplies lifecycle checks, permanent LP custody, V4 swap deltas, ERC6909 claims, cash settlement, treasury liabilities and collector-only redemption. Contributors do not reimplement these layers. The static example stays core-only; the dynamic example explicitly composes the optional oracle.

[`LaunchDeltaAccountingFixture`](contracts/test/LaunchDeltaAccountingFixture.sol) checks actual wallet changes against swap deltas, cleared manager/hook deltas, and fee liabilities backed by tracked claims or settled cash. The launch harness runs these checks in both fee modes and verifies donations stay excluded after collection. This is test-only; lifecycle authorization and callback ownership are unchanged.

The retained lifecycle V1 wire interfaces and canonical `ILaunchFeeSourceV1` are still used by the current target ADR. Hub economics use V3; retired launch/router, reward-tracker and V1 fee-hub APIs are not shipped.

### Optional truncated oracle

[`PoolBoundTruncatedOracleV2`](contracts/src/hooks/v4/authoring/PoolBoundTruncatedOracleV2.sol) extends the base with quote-normalized, per-block clamped observations. Opt in by inheriting it instead of the core-only base:

```solidity
import { PoolBoundHookParametersV2 } from "@black-market/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundTruncatedOracleV2 } from "@black-market/hooks/v4/authoring/PoolBoundTruncatedOracleV2.sol";

contract MyOracleHook is PoolBoundTruncatedOracleV2 {
    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundTruncatedOracleV2(parameters) {}

    function authorFeeBps() public pure override returns (uint16) {
        return 500;
    }
}
```

This is still one deployed hook, not a separate oracle deployment. The base's external callbacks and settlement remain nonvirtual; protected notifications let the provided oracle template record authenticated initialization, pre-swap and pre-liquidity-change snapshots. The oracle template seals its notification overrides.

History, observation storage, cardinality management and registry-snapshot checks live only in the optional template. Its [interface](contracts/src/hooks/v4/authoring/ILaunchHookOracleV1.sol) exposes `observeTruncated`, `observations`, `oracleState`, `validateOracleConfig` and capacity growth. Queries before initialization or before retained history fail closed.

The core retains `oracleInitializedAt(poolId)` because the deployed adapter reads it: core-only hooks return `0`, while composed hooks return their genuine initialization time. The constructor/config tuple still contains `oracleFactory` and `oracleConfigId`; the current launch factory validates the registered config even for core-only hooks. These wire fields do not create oracle history.

The read-only `_oraclePriceMovement()` seam returns the latest truncated tick change and age-adjusted elapsed seconds. It needs two genuine samples and returns no movement during warm-up. `_initialOracleCapacity()` defaults to one; a policy can reserve more ring capacity, capped by the registered configuration. The dynamic example reserves two slots without fabricating observations or requiring an external growth transaction. Callback observers run after rate freezing, so a swap cannot change its own oracle-based rate.

Under the unchanged pinned compiler profile, `ReferenceBoundHook` is 18,001 runtime bytes, `DynamicFeeHook` is 24,047, and the composed static fixture is 23,550. The dynamic example has **529 bytes** of EIP-170 headroom; additional policy code must be measured. Do not change the compiler profile or split deployment to evade the limit. Artifact changes require fresh qualification, approved hashes and newly mined salts.

CI separately reconstructs and launches the composed fixture, exercising genuine genesis, capped growth, normalized/clamped sampling, same-block swaps, stored and extrapolated accumulators, historical-query rejection and the same accounting/royalty checks as core-only hooks. The dynamic reference additionally proves a higher fee for observed rises, decay during idle time, and baseline fees after falling/flat observations. Those economic vectors are scoped to that example, not imposed on arbitrary dynamic policies.


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

Use fresh evidence directories on subsequent runs. All hooks are checked. Compilation uses Solidity 0.8.28, Cancun, optimizer runs 1, no via-IR or bytecode metadata. Runtime/initcode limits are 24,576/49,152 bytes; measured sizes are included in qualification reports.

Qualification resolves the public RPC's latest block once, records its number/hash, and verifies every deployed code hash. `--rpc-url` can select another Robinhood RPC. Replaying older evidence requires an archive endpoint.

## PR review

Use the [PR template](.github/pull_request_template.md). Link the current Actions run and disclose missing or failed checks.

Review `PR-REVIEW.md` and `<slug>.registration-inputs.json` from the Actions artifacts. Reports separate declared inputs, file SHA256 pins, measured artifact evidence, derived registry fields and pending admission inputs. File pins are not Solidity admission digests.

CI independently reconstructs each submitted artifact and runs real standard ERC20/WETH launches on a local fork with zero LP fees. It exercises both declared fee modes, exact-input/output swaps in both directions, previewed versus charged hook rates, and exact treasury, executor, owner and developer receipts. It also checks nonzero LP-fee and reduced-payment rejection, registered payout routing, zero-fee trading, zero-credit claim behavior and rejection of PoolManager protocol fees. The scenario uses the declared author rate, minimum tick spacing, maximum oracle cardinality and one LP position; it is not exhaustive bounds coverage. Dynamic rate boundary tests run separately in CI.

The pinned public graph in `contracts/config/robinhood.json` remains historical V5 evidence. Qualification deploys fresh actual V6 infrastructure from the shipped `contracts/protocol/` sources against the pinned real manager, oracle factory and WETH; it does not relabel or upgrade deployed V5 actors. Local fixture admission uses a test author signature and fork-only administration; oracle registration, if needed, is fork-only. CI has no wallet credentials and never broadcasts. This does not prove control of the submitted `authorId` or establish arbitrary-runtime safety. Production use requires separately deployed and approved V6 infrastructure.

Registry admission remains separate: approved artifact/review/terms commitments, target economics and deployed graph, exact envelope/profile/registration, current author-controller authorization and administrator submission. Obtain authorization from the target registry's `authorizationDigest`. Do not include private keys or admission signatures in the initial PR.
