---
name: hook-authoring
description: >-
  Create or modify an Abyss Hooks submission, including a static or dynamic fee
  policy, manifests, contributor smoke/policy tests, review.md and local
  qualification provenance. Use for hook economics, oracle policy and submission
  contract changes.
---
# Hook authoring

## Read the contract first

Read `CONTRIBUTING.md` sections Submission, Hook requirements, Fees and author payment, and Optional truncated oracle. Inspect `hooks/reference-bound/` for static policies or `hooks/dynamic-fee/` for dynamic policies, including their manifests and review. Read the shared base and any inherited template before overriding policy seams.

Read `SECURITY.md` before handling contributed code or evidence. Use the [hook-security-review skill](../hook-security-review/SKILL.md) for security-sensitive authoring: fee math, new external reads/selectors or assembly, oracle policy, lifecycle assumptions, and artifact/admission identity. Inheritance is not a sandbox; review the complete concrete artifact, not just the override.

## Establish version and scope

- Record the requested policy, allowed overrides, units, economic terms and acceptance vectors in `review.md`. Distinguish creator trading-fee pips from the author's bps share of downstream owner proceeds. Keep pool LP fees zero; official examples of dynamic LP fees are not this catalogue's fee model.
- Read `scripts/install-deps.sh`, `foundry.toml`, `scripts/upstream.json` and the relevant entries in `scripts/protocol-source-pins.json`. Record the actual dependency/compiler revisions, source adaptations and imported interfaces used by the artifact. The install script currently pins `v4-core` to `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`; neither current online `main` nor a historical audit identifies that revision. File hashes identify shipped adaptations that an upstream commit alone cannot.
- Compare official documentation and audit scope with the pinned code before borrowing behavior or claiming a finding applies. Follow fixes to their commits and relevant code paths; an audit of core/periphery does not audit this policy, the approved base, or the deployed launch graph. Keep a concrete assumption → invariant → verification vector for each applicable lesson.
- `contracts/config/robinhood.json` identifies fork venues and a historical reference envelope. Qualification creates isolated launch actors from the external Black Market dependency snapshot; it is not production deployment or authority to admit a submission. Internal launch ABI versions do not define a new hook policy. Do not add generic Uniswap templates, new permission profiles, proxies/upgrades, custom companion deployments or alternate settlement layers.

## Implement the requested policy

1. For a new submission, copy the appropriate reference into `hooks/<lowercase-kebab-case-slug>/`. Rename the source and concrete contract. Do not reuse reserved reference `kind` or slugs.
2. Keep production sources flat with `hook.json`, `integration.json` and `review.md`. The sole allowed subdirectory is flat `test/`, containing mandatory `Smoke.t.sol`, optional policy `*.t.sol` suites and Solidity fixtures. A successful runner-generated `provenance.json` is the only generated-record exception. No deeper directories, symlinks, scripts, other generated artifacts or companion contracts. Preserve matching SPDX headers and a local production `source` filename.
3. Confine every submission pull request to `hooks/<slug>/`, including contributor tests and reviewed compact provenance. Never modify the shared harness (`contracts/test/`), tooling (`scripts/`), catalogue tests (`tests/`), maintainer docs (`CONTRIBUTING.md`, root `README.md`) or CI workflows to make a submission pass. Express non-WETH quote, prerequisites and signed swap hookData through existing test-side seams. If genuinely new harness capability is required, report the exact need for a separate maintainer infrastructure change.
4. Derive from `PoolBoundLaunchHookBaseV2` with its typed constructor. Use `PoolBoundTruncatedOracleV2` only for authenticated truncated history. Reuse the base's validation, callbacks, custody, and accounting; do not modify the approved base to accommodate a submission.
5. Declare `authorFeeBps()` and match `developerFeeBps` in the integration manifest. New submissions use `kind: submission` and a nonzero stable 20-byte `authorId`, not a live payout wallet. Do not fabricate an author's identity or consent; obtain missing author/economic terms from the contributor before completing a submission.
6. Static hooks charge the creator's configured maximum. Dynamic hooks explicitly declare `SwapFeeModel.Dynamic` and implement read-only `_calculateRate(LaunchHookFeeContextV2 memory)` within the frozen bounds. Preserve floor rounding, both fee modes, exact-input/output behavior, and rate freezing before oracle observations.
7. For oracle policies, cover genuine warm-up, flat/falling movement, idle decay, same-timestamp observations, and history rejection as applicable to the requested policy. Do not impose the reference dynamic formula on unrelated policies.
8. Update `hook.json` schema 1 and `integration.json` schema 2 without extra or duplicate fields. Use the exact field table and limits in `CONTRIBUTING.md`, including declared registry bounds and supported fee modes.
9. Update `review.md` with the formula, units, rounding, boundary vectors, potential reverts, dependencies, authority, risks, input rationale, and fresh verification evidence. Separate measured results from proposed terms and pending approval.

Include `<hook.json contract>SmokeTest` in `test/Smoke.t.sol`, inheriting `HookSmokeTest` with the actual source/contract descriptor in its constructor. Reuse `HookLaunchFixture` configuration, prerequisite and hookData seams; do not substitute deployment or `vm.etch` candidate code. Inherited nonvirtual `testSmoke*` tests are mandatory and unskippable. Policy refusals must be actual asserted rejections with unchanged wallets/liabilities, and each declared fee mode still needs successful trade evidence. Put custom formula, boundary, oracle and signed-data/replay checks in separate policy `test/*.t.sol` suites, such as `Policy.t.sol` and `Rate.t.sol`; they supplement, not replace, shared invariants. Mutable setup remains a reviewed assumption, not a safety proof. See `CONTRIBUTING.md` for the API and layout contract.

## Preserve the lifecycle and artifact boundary

The [official hook lifecycle](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks) describes general V4 capabilities. This repository deliberately narrows them to one bound market:

- Trace constructor → registrar registration in the exact core Prepare context → authenticated initialization → opening liquidity → terminal opening completion → swaps/donations → collector redemption. Preserve one-time bindings, the frozen opening price/configuration, collector/locker graph validation and downstream author-term authentication. Registration/initialization precede hub terms binding; the required author rate is checked before the first liquidity acquisition, not by pretending admission has already enforced it.
- Keep `msg.sender == PoolManager` callback authentication separate from the callback's `sender` (the initiating periphery actor, not necessarily a trader). Do not authenticate with `tx.origin`. Preserve exact full `PoolKey` identity: ordered currencies, fee, tick spacing and hook address, not just a token pair. Manager-only access alone does not reject another pool or an out-of-sequence callback.
- Read `V4HookFlags.sol` and the base together. The required low-bit equality is `(uint160(hook) & 0x3fff) == 0x1afc`: after-initialize; before-add/remove-liquidity; before/after-swap and their return-delta permissions; before/after-donate. There is no before-initialize permission or general opening swap gate. Preserve the actual opening/external-liquidity restrictions; do not invent a stronger lifecycle claim.
- Preserve the single-use frozen swap context and authenticated unlock payload. Reject missing, mismatched, replayed or stale callbacks, including zero-fee swaps. External checkpoints must not overwrite the rate or turn a previous swap's state into a new authorization. Keep callbacks and settlement inherited/nonvirtual; policy code must not introduce an alternate collect, sweep, recipient, author-payment or principal-withdrawal path.

### Bind permission mining to the reviewed artifact

Use qualification's typed `PoolHookDeployerV1` path, not arbitrary-address test deployment as production evidence. Bind the CREATE2 preimage to the actual deployer address, salt and `keccak256(creationCode || abi.encode(PoolBoundHookParametersV2))`. Freeze the complete constructor tuple, including creator minimum/maximum/sensitivity and market commitment, before mining.

Preserve evidence connecting source/compiler pins → creation code/hash → typed constructor bytes/initcode hash → deployer/holder and code chunks → predicted address and exact permission mask → deployed runtime/code hash. The permission bits only select callbacks; they do not prove implementation safety or artifact approval. Compare prediction and deployed artifact using the qualification/admission checks, including the salt-normalized market commitment. A code, dependency, compiler or constructor change invalidates prior artifact evidence: requalify, obtain approval for the new identity and mine against the new preimage. Never reuse an old salt/address claim or change the compiler profile/split deployment to evade size limits.

## Write the swap and settlement model before coding

Read the pinned `IHooks`, `BeforeSwapDelta`, `BalanceDelta` and base swap paths alongside [flash accounting](https://developers.uniswap.org/docs/protocols/v4/concepts/flash-accounting) and [unlock callbacks/deltas](https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas). These tables describe the inherited fee paths, not permission to replace them.

Let `c0/c1` be the sorted `PoolKey` currencies. Negative `amountSpecified` is exact input; positive is exact output. `zeroForOne` means input `c0`, output `c1`; the opposite means input `c1`, output `c0`. “Specified” is the requested input for exact input and requested output for exact output, **not** always token0 or the fee asset.

| Direction / request | Specified / unspecified | InputToken fee path | QuoteOnly if quote = c0 | QuoteOnly if quote = c1 |
| --- | --- | --- | --- | --- |
| c0 → c1, exact input | c0 / c1 | Before, c0 | Before, c0 | After, c1 |
| c1 → c0, exact input | c1 / c0 | Before, c1 | After, c0 | Before, c1 |
| c0 → c1, exact output | c1 / c0 | After, c0 | After, c0 | Before, c1 |
| c1 → c0, exact output | c0 / c1 | After, c1 | Before, c0 | After, c1 |

“Before” charges `floor(abs(original amountSpecified) * frozenRate / 1_000_000)` as a positive specified hook delta. A nonzero precharge requires the base's exact-fill reconciliation; a price-limit partial fill reverts instead of charging for unfilled volume. “After” charges the same floor formula on the absolute **executed unspecified** currency amount from `afterSwap`'s delta, not an estimated request. `afterSwap` returns an unspecified delta; `BeforeSwapDelta` packs specified/unspecified, whereas `BalanceDelta` packs token0/token1. Exact output does not reveal its eventual input to `_calculateRate`.

Keep the account perspective explicit:

| Quantity | Meaning | Settlement/accounting consequence |
| --- | --- | --- |
| Caller currency delta < 0 | Caller owes the manager | ERC20 sync → transfer → settle, or burn valid ERC6909 claims to offset debt, through the approved integration |
| Caller currency delta > 0 | Manager owes the caller | Take assets or mint claims to consume credit |
| Positive returned hook delta | Hook is owed/takes value | The caller bears the opposite adjustment; the base accrues the fee and mints backed manager claims |
| Negative returned hook delta | Hook owes/sends value | Not this base's fee policy; do not confuse it with a positive caller credit or add a new rebate path |
| Successful unlock completion | No unresolved currency delta remains | Check caller and hook deltas as well as wallets; zero deltas alone do not prove liabilities are backed |

Do not settle from `feeRate` previews or idealized liquidity calculations. Follow actual execution deltas and the inherited claim/cash path. Assert pending fee liabilities are backed by tracked ERC6909 claims or settled cash, including claim headroom and later redemption; treasury liabilities are a subset, not additional principal. Donations/checkpointed LP growth are not hook fees. Collector-only collection must preserve exact manager/hook/recipient balance movements and downstream treasury, executor, owner and developer allocations.

## Bound the policy, rounding and execution

- Express each input and intermediate's signedness, units and range. Preserve `0 <= minimum <= maximum <= 1_000_000`, uint32 sensitivity (including zero), the original signed-request guard and `int128.max` charge bound. Prove products/divisions fit before narrowing or using `unchecked`; do not negate `int256.min`, cast a negative amount to unsigned, mix bps/pips or substitute floating-point estimates.
- Return a rate within frozen creator bounds from the read-only seam. The base snapshots bounds before invoking it and freezes one scalar before observers/checkpoints; do not mutate the context to widen limits or depend on an eventual exact-output input amount. Static declaration always uses the configured maximum and does not invoke a dynamic override. Out-of-bounds dynamic returns revert, rather than being silently clamped by the base.
- Preserve full-precision floor fee rounding and the exact treasury order `denominator == 0 ? 0 : (grossHookFee / denominator) * 125 / 100`, with nonzero denominators `4..10`. Algebraically similar expressions can differ by integer units. A nonzero rate can still charge zero on dust.
- Define expected behavior at zero maximum, equal bounds, zero sensitivity, smallest nonzero charge, cap/floor transitions, zero elapsed time, extreme signed signals and charge-overflow limits. Use raw token units and disclose decimal assumptions. Check one unit below/at/above rounding and branch boundaries with an independent integer reference.
- Prove rates and charged amounts in executed swaps across the table, both supported fee modes and relevant partial-fill/price-limit paths. Compare pre-swap preview to the frozen execution rate only under the same authenticated state; a preview is neither a guaranteed future quote nor an exact-output total fee amount. Analyze split/alternating trades, manipulated pre-swap state and sequences without resetting history, not only isolated previews.

## Identify dependency, oracle and authority failure modes

For every existing or requested external dependency, record address/code provenance, reader/caller, trusted controller, authenticated data, failure behavior and who can restore liveness. New harness capabilities or dependency graph changes need separate maintainer infrastructure work; do not hide them inside a submission.

- **External reads:** read-only is not synonymous with trustworthy, cheap or nonreentrant. Model reverts, malformed/short or oversized returndata, gas exhaustion, read-only/nested callback attempts and state changed by intervening external calls. Retain the base's authentication/ABI guards and snapshot order; do not add catch-and-ignore or fake-data fallbacks to make qualification pass. Document whether failure stops swaps, opening or collection, and the residual authority risk.
- **Tokens:** preserve the approved ERC20/WETH path and exact-transfer accounting. Fee-on-transfer, rebasing, callback-capable, paused/blacklisted or dual-entry/native-alias tokens are not proven supported by standard-token qualification. Do not broaden token support or assume nominal transfer amounts establish backing.
- **Oracle:** opt into the provided sealed template only when history is needed. Keep quote-per-base normalization, per-block clamping, genuine genesis, retained-history rejection and registered-config snapshots. Capacity/growth is not observation count or mature lookback; core-only `oracleInitializedAt == 0` is not a fabricated genesis. Define warm-up, stale/idle signal, zero elapsed time, same-block/same-timestamp behavior, ring/counter wrap and retention boundaries. Clamping is not a manipulation-resistance guarantee: disclose thin-liquidity, flash-loan/MEV, lag and repeated-trade incentives. Use the requested policy's conservative behavior; do not force the reference velocity schedule or add an unrequested oracle fallback.
- **Governance and admission:** distinguish immutable hook configuration from registry administrator, current author controller/payout and manager protocol-fee authority. A nonzero manager protocol fee makes this base reject swaps; disclose that liveness dependency rather than adding a bypass. Author signatures authorize the exact approved downstream registration, not runtime fee logic. Use the target registry's `authorizationDigest` and current controller authorization; review the actual domain, chain/registry, commitments, profile/envelope, nonce/deadline and replay rules rather than signing a hand-built digest. CI's test author/fork-only administration and a submitted `authorId` prove neither real consent nor production admission. Never put wallet keys or admission signatures in the initial PR.

## Turn published audit lessons into author invariants

Primary sources and scope:

- [OpenZeppelin Uniswap v4 Core Audit](https://www.openzeppelin.com/news/uniswap-v4-core-audit), scoped to `v4-core` [`d5d4957b35750e8cf1f3db5584e77eef4861c21e`](https://github.com/Uniswap/v4-core/tree/d5d4957b35750e8cf1f3db5584e77eef4861c21e). Some inherited V3 math was reviewed only as a diff; consult its Scope section.
- [OpenZeppelin Uniswap v4 Periphery and Universal Router Audit](https://www.openzeppelin.com/news/uniswap-v4-periphery-and-universal-router-audit), scoped to `v4-periphery` [`df47aa9ba521fc15ffd339dc773d32f5fc4c91fc`](https://github.com/Uniswap/v4-periphery/tree/df47aa9ba521fc15ffd339dc773d32f5fc4c91fc) and Universal Router [`4ce107d6387558b97816293fe2c0d4d7c4cadef4`](https://github.com/Uniswap/universal-router/tree/4ce107d6387558b97816293fe2c0d4d7c4cadef4), with the report's stated integration scope.

These are historical findings, **not claims of current vulnerabilities** in the repository's different dependency pins or an audit of Abyss. For an applicability claim, identify the affected path, report status/fix provenance and whether that behavior exists in the actual pinned source/deployed code. Otherwise use the finding only to motivate an invariant and adversarial vector:

| Published finding (report above) | Invariant and author verification |
| --- | --- |
| Core: “ERC-20 Representation of Native Currency Can Be Used to Drain Native Currency Pools” (reported resolved in core PR #779) | One real payment cannot create credits for two currency identities. Preserve supported currencies, sync/settle ordering and exact claim/cash backing; do not copy the historical settlement ABI or extend native-token support. |
| Core: “Front-Running Pool's Initialization or Initial Deposit Can Lead to Draining Initial Liquidity” (acknowledged; periphery slippage protection assumed) | Preserve exact registrar/full-key/opening-price authentication and opening continuity. Exercise unauthorized/preinitialized/wrong-price launch rejection; do not infer the hook or core supplies arbitrary user slippage protection. |
| Core: “ProtocolFeeController Gas Griefing” (reported resolved in core PRs #771/#825) | An external response cannot be assumed bounded because call gas is limited. Review dependency returndata/gas handling and explicit liveness consequences without weakening the approved guards. |
| Periphery: “Accrued Fees Can Be Stolen” (reported resolved in periphery PR #290) | A zero-liquidity-delta action can still realize value. Test fee checkpoint/collection authorization, zero-credit cases and arbitrary callers; do not equate “no principal change” with “no authorization needed.” |
| Periphery: “Slippage Checks Are Not Enforced When Fees Accrued Exceed Tokens Required for a Liquidity Deposit” and “Slippage Check Can Be Bypassed With Unsafe Cast” (reported resolved in periphery PR #285) | Separate principal, fee and hook adjustments; retain signedness through checks. Assert actual wallet/delta/fee results, sign/cast boundaries and integration slippage assumptions, not just net-positive balances or estimated amounts. |

The [official V4 security framework](https://developers.uniswap.org/docs/protocols/v4/security) helps identify math, dependency, permission and liquidity risk. It is voluntary, self-directed guidance, not Uniswap Foundation review, certification or a safety guarantee. Its general feature examples do not relax this catalogue's restrictions.

## Verify and hand off

Use the `hook-qualification` skill and the local contributor command: `python3.12 scripts/check_hooks.py --hook <slug> --output evidence/<unique-run> --rpc-url https://robinhood.drpc.org --record`. For a fee-policy change, exercise the changed behavior in separate policy `test/*.t.sol` suites; do not rely only on previews or compilation. Measure actual artifact size under the pinned profile: the dynamic reference has limited runtime headroom, so do not assume additional code fits.

Build an acceptance matrix in `review.md`: invariant, adversarial input/sequence, expected fee or revert, actual check/evidence and any uncovered case. Include all swap-table branches; boundary/rounding vectors; wrong manager/full key and stale swap/unlock context; preinitialization/wrong-price or liquidity-caller violations; nested/checkpoint attempts; donation exclusion, backed claims/cash and collector-only collection; downstream author-rate/payout behavior; and the requested oracle/dependency failure cases. Use existing fixtures/qualification instead of a replacement harness. If required coverage is missing, report the exact capability for a separate maintainer change; do not modify shared tests/tooling inside a submission PR.

Catalogue launch scenarios are not exhaustive declared-bounds, token-behavior or adversarial coverage. Add policy-specific deterministic, fuzz and stateful invariant evidence in the contributor's `test/` suites using existing fixtures; never present proposed tests or inherited example results as this artifact's observed verification. Review the successful compact `provenance.json` and commit it with matching sources/tests, not full ignored logs. `--check-provenance` checks identity freshness without a chain rerun. Run contributed code only in a disposable environment without credentials or wallet keys. Report exploitable findings through the private channel in `SECURITY.md`, not public review evidence.

Before opening a PR or pushing updates to an existing PR, apply the [pr-review skill](../pr-review/SKILL.md) to the complete proposed diff and resolve actionable findings or explicitly disclose remaining gaps. For security-sensitive changes, include the [hook-security-review skill](../hook-security-review/SKILL.md) assessment. Inspect exact-head CI when enabled; during the documented pause, do not dispatch or wait for Actions and report actual local checks plus unrun cases. Source/artifact changes require fresh applicable evidence.

Report changed sources and declarations, executed checks, measured artifact evidence, and unresolved contributor inputs. Passing qualification does not authorize registry admission or prove control of `authorId`.
