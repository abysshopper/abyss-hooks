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
| `test/Smoke.t.sol` | Mandatory concrete `<contract>SmokeTest` inheriting `HookSmokeTest`, pointed at this hook's artifact |
| `test/*.t.sol` | Additional policy-specific suites, such as `Policy.t.sol` or `Rate.t.sol`, where needed |
| `provenance.json` | Optional compact record generated only by successful local qualification with `--record` |

Production Solidity sources stay flat in `hooks/<slug>/`. The sole allowed subdirectory is `test/`, containing regular, flat Solidity files: mandatory `Smoke.t.sol`, optional policy suites and Solidity fixtures. No deeper directories, symlinks, scripts, generated artifacts or unknown file types are allowed; `provenance.json` is the explicit generated-record exception. `source` must be a local production filename. `@black-market/` maps to the shipped `contracts/src/` authoring code and interfaces; Uniswap and Solady remappings are also available.

Submission pull requests may only add or change files under `hooks/<slug>/`. The shared test harness, tooling, catalogue tests, documentation and CI workflows are maintainer-owned; if a hook needs new harness capability, open an issue or a separate infrastructure pull request instead of bundling it into the submission.

### Contributor smoke and policy tests

Copy the reference's `test/` directory along with its sources. Rename the concrete smoke test to the `hook.json` contract name followed by `SmokeTest`, and pass the actual source/contract descriptor to the shared constructor. For the dynamic reference:

```solidity
import { HookSmokeTest } from "../../../contracts/test/HookSmokeTest.sol";

contract DynamicFeeHookSmokeTest is HookSmokeTest {
    constructor() HookSmokeTest("hooks/dynamic-fee/DynamicFeeHook.sol:DynamicFeeHook") {}
}
```

Replace both names and the descriptor when authoring another hook. `HookSmokeTest` inherits `HookLaunchFixture`, which reuses the native launch graph, typed holder, CREATE2 deployment, lifecycle and accounting helpers. Setup resolves the runner-selected `HOOK_ARTIFACT` and checks its creation-code hash against the constructor's configured artifact. Do not override deployment or use `vm.etch` to substitute candidate code.

All inherited public `testSmoke*` tests are nonvirtual and mandatory. The runner independently checks compiler-AST inheritance, derives required test names from the base ABI and requires each discovered result to be `Success`; missing, `Failure` or `Skipped` cases cannot qualify. Contributor setup, prerequisite overrides and mutable cheatcodes still need source review. These checks are not a sandbox or proof that arbitrary setup or runtime behavior is safe.

Override `_configureScenario() internal returns (LaunchScenario memory)` and start from `_defaultScenario()` to keep useful defaults. Configure the quote token, raw-unit funding, supply, liquidity, opening price/ticks, creator fee settings, oracle settings, opening buy and trade amounts on the test side. Override `_setUpPrerequisites() internal` for existing policy dependencies and `_fundQuote(address payer, uint256 rawAmount) internal` when the configured quote needs custom funding. A signed policy can override `_swapHookData(PoolKey memory, SwapParams memory, address payer) internal returns (bytes memory)` with genuinely signed test data. `PoolKey` and `SwapParams` can be imported from `contracts/test/HookLaunchFixture.sol`. No production `requiredQuoteCurrency()` or `swapPassSigner()` getter is required for qualification.

Where a policy intentionally refuses a swap branch, override `_expectedSwapRevert(PoolKey memory, SwapParams memory, address payer) internal view returns (bytes memory)` with the actual expected rejection; the shared check must observe that rejection and unchanged wallets/liabilities, never skip. Evaluate both directions and exact-input/output branches in each declared fee mode, and demonstrate actual successful trading under a valid scenario in every declared mode. A hook need not admit every amount mode. Free-fee hooks are valid; author bps must match the declaration exactly, not a universal 500 bps example.

`LaunchScenario.preparedOracleCardinality` controls test-side capacity preparation without inventing observations. `_expectedZeroFeeLaunchRevert(LaunchPlanV1)` may return `(LaunchRefusalStage.Prepare | Activate, exactRevertBytes)` when a policy deliberately rejects the zero-fee configuration; empty bytes require the actual free-fee scenario to pass. This is test configuration, not a new production gate.

Keep formula, rounding, oracle-curve, boundary, malformed-data and signature/replay evidence in separate policy `test/*.t.sol` suites, such as `Policy.t.sol` and `Rate.t.sol`. The runner discovers the selected hook's `test/` directory and runs smoke and policy suites with separate results/logs. Policy evidence supplements the shared invariants; it cannot override or replace them. The dynamic reference's curve tests are not a universal policy requirement. Additional harness capability remains a separate maintainer-owned infrastructure change.

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

Maintainer checks separately reconstruct and launch the composed oracle fixture, exercising genuine genesis, capped growth, normalized/clamped sampling, same-block swaps, stored and extrapolated accumulators, historical-query rejection and the same accounting/royalty checks as core-only hooks. The dynamic reference's separate policy suites prove a higher fee for observed rises, decay during idle time, and baseline fees after falling/flat observations. Those economic vectors are scoped to that example, not imposed on arbitrary dynamic policies.


## Local checks

Use Python 3.12 and Foundry `nightly-5e88010a83d1b87b8f4d13058e42a2949d3e9dc0`. Run untrusted submissions in a disposable environment without credentials or wallet keys.

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python3.12 -m pip install -r scripts/requirements.txt
scripts/install-deps.sh
python3.12 scripts/check_hooks.py --hook <slug> --output evidence/<unique-run> --rpc-url https://robinhood.drpc.org --record
```

Replace `<slug>` with the selected hook folder and `<unique-run>` with a fresh identifier. The selected hook's exact artifact, mandatory smoke suite and all policy suites must pass. The runner prints named tests/statuses and actual receipt summaries, and writes full logs, JSON and `RESULTS.md` in the ignored output directory. Smoke and policy evidence are separate. Failed, skipped, missing or incomplete mandatory results do not qualify; failed-run output is retained for diagnosis.

Compilation uses Solidity 0.8.28, Cancun, optimizer runs 1, no via-IR or bytecode metadata. Production hook runtime/initcode limits are 24,576/49,152 bytes; measured sizes are included in reports. Test-contract output is not the production portability artifact.

Qualification resolves the public RPC's latest block once, records its number/hash, and verifies deployed code hashes. `--rpc-url` selects another Robinhood RPC without bypassing those checks. Replaying older evidence requires an archive endpoint.

Maintainer infrastructure checks include `python3.12 -m unittest discover -s tests`, `python3.12 scripts/check_hooks.py --structure-only --output evidence/structure-<unique-run>`, and catalogue-wide qualification by omitting `--hook`. Structure-only checks do not compile or qualify a hook. Internal oracle/custom-adapter fixture runs are maintainer checks, not catalogue submissions.

### Commit-ready provenance

`--record` is optional and writes only `hooks/<slug>/provenance.json` after successful full qualification. It never runs `git commit` or `git push`. A failed or incomplete run cannot publish a success record or overwrite an existing one; an old record is not evidence that a failed new run qualified.

The compact record binds source and test bytes, harness/protocol dependencies and tool identity to measured artifact identity, fork chain/block/hash, named test outcomes and actual launch receipts. It includes source-commit identity with a working-tree caveat; file hashes, not HEAD alone, identify what ran. The record excludes itself from source hashes.

Review the record and reports before staging. Commit the selected `hooks/<slug>/provenance.json` with the matching sources, tests, manifests and `review.md`, and reference that compact file in the GitHub PR. Do not commit the full ignored evidence directory, credential-bearing logs, wallet keys or production admission secrets.

```bash
python3.12 scripts/check_hooks.py --hook <slug> --check-provenance
```

This checks recorded source, test, harness and tool identity freshness without rerunning chain behavior. A fresh identity check is not a new fork run, a current-chain guarantee or a signed attestation. Changed inputs need new full qualification with a fresh output directory and a reviewed replacement record.

## PR review

Use the [PR template](.github/pull_request_template.md). Automatic GitHub CI is temporarily paused. Do not start or wait for a run during the pause; report the applicable local checks and explicitly disclose that CI did not run. After CI is re-enabled, inspect the exact-head run before acceptance.

Review `RESULTS.md`, smoke/policy JSON and logs, receipts, `PR-REVIEW.md` and `<slug>.registration-inputs.json` from the selected local output directory alongside any committed `provenance.json`. Reports separate declared inputs, file SHA256 identities, measured artifact evidence, derived registry fields and pending admission inputs. File hashes are not Solidity admission digests.

The runner independently reconstructs each selected artifact and uses the test-configured quote and prerequisite scenario on a local fork with zero LP fees. Shared checks evaluate declared fee modes, both directions and exact-input/output branches as successful trades or asserted policy refusals, with real successful trade evidence per declared mode. They check previewed versus charged rates, wallet/delta accounting, backing and exact treasury, executor, owner and developer receipts. Lifecycle, author-rate rejection, payout routing, zero-fee/zero-credit behavior, donation exclusion and protocol-fee rejection remain shared checks. Policy-specific formulas and boundaries run separately. Test setup and declared registry bounds are assumptions to review, not exhaustive bounds or arbitrary-runtime safety proof.

`contracts/protocol/` contains external Black Market launch contracts used only by the test harness. `scripts/protocol-source-pins.json` records the exact imported bytes and documented adaptations so a maintainer update cannot silently change the platform being tested. These hashes identify the test dependency snapshot; they do not restrict a contributor's fee formula, quote selection or optional policy. `contracts/config/robinhood.json` identifies the fork venues and a historical reference envelope. The harness creates its own launch graph and profile, never upgrades or registers on the public chain. Internal names such as config version 6 and hub version 3 describe the external launch ABI, not separate hook submission versions.

The external launch contracts require each market's position maxima to sum exactly to its token budget, and all market budgets to sum exactly to the token supply. Unused inventory is burned at activation. The current fee hub requires each source's `custodyRecipients()` descriptor; update the hub and collector implementations together. Candidate accounting and author payment remain in the provided base and downstream hub, not a second hook-specific payment path.

Registry admission remains separate: approved artifact/review/terms commitments, target economics and deployed graph, exact envelope/profile/registration, current author-controller authorization and administrator submission. Obtain authorization from the target registry's `authorizationDigest`. Do not include private keys or admission signatures in the initial PR.
