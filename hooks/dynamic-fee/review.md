# DynamicFeeHook

- Base and scope: `PoolBoundTruncatedOracleV2` with the 20-word `PoolBoundHookParametersV2` constructor. The creator independently chooses minimum, maximum and sensitivity per pool; immutable policy getters, the complete constructor hash, CREATE2 and the salt-normalized V6 market commitment bind those settings. Oracle and arithmetic compile into this one hook. Author-payment, Dynamic model, initial capacity and read-only rate declarations are overridden; callbacks, custody, payees and accounting remain inherited. The core stays oracle-free and deploys no validation helper. Pool LP fees must be zero.
- Signal: retain two genuine observations automatically. Let `latest` and `previous` be the newest adjacent ring samples. Their modular signed cumulative difference divided by their modular uint32 timestamp interval recovers the previously held truncated tick exactly. `D = currentTruncatedTick - previousHeldTick`; `E = uint32(now) - previous.timestamp`, including idle age. `K` is the frozen configured per-block tick clamp. Fewer than two samples or a zero-length interval means no velocity signal. Quote normalization makes a positive `D` an upward quote-per-base price movement.
- Formula: minimum `m`, maximum `M` and uint32 sensitivity `G` are independent. `G` has units fee-pips × seconds/tick. For `D > 0` and `E > 0`, return `min(M, m + floor(G * D / E))`. Warm-up, flat/falling movement or unavailable elapsed time returns `m`. Zero sensitivity gives a constant minimum; equal bounds give a constant rate; maximum zero implies minimum zero. No fixed percentage baseline or response period remains. Exact input/output, direction, request size, reserves and fee currency mode do not change the schedule.
- Arithmetic and freezing: `C = (M - m) * E < 2^56`. Saturate when `D > floor(C / G)` before multiplying an arbitrary positive signed signal; otherwise `D * G <= C`, so the product and final uint24 result fit. At exact equality the ordinary calculation may return `M`. All divisions floor nonnegative rate arithmetic. The base rejects an `int256.min` request and snapshots/enforces both configured bounds before invoking an override. It freezes the rate before oracle observers and settles using that scalar; a swap's own impact cannot change its charge. Preview is not a future execution guarantee.
- Author payment: `authorFeeBps()` requires 500 bps of source-attributed owner proceeds after bounty through the existing V3 hub, independent of trading fees. No payee is added. A different frozen author allocation is rejected by inherited validation.
- Provenance: independently authored from the disclosed upward-velocity schedule; no external fee-hook implementation was copied. MIT; dependency licenses remain applicable.
- Risks: the signal is the last observed truncated movement, not raw spot velocity, volatility or a long-window TWAP. Clamping and pre-swap sampling introduce lag; a truncated feed may keep catching up while spot is flat. Warm-up charges the chosen minimum rather than inventing history. Idle time fades previous uplift toward that minimum. High sensitivity reaches the cap faster; zero sensitivity disables uplift. Clamping is not manipulation resistance, and inherited author code is not a sandbox. Runtime is 24,047 bytes under the unchanged pinned compiler, leaving 529 bytes below EIP-170. Policy changes require fresh measurement, artifact review and salts.
- Qualification: 12 deterministic/fuzz arithmetic tests pass; real-fork launches check both fee modes, exact-input/output directions, frozen-rate wallet/liability accounting, genuine history and exact royalties. Five independent `(minimum, maximum, sensitivity)` policies charged these actual fast → post-warp rates in pips: `(250,10000,1000)` 958 → 368; `(750,20000,1000)` 1458 → 868; `(250,1000,2000)` 1000 → 486; `(0,10000,3000)` 2125 → 354; `(500,10000,0)` 500 → 500. Each isolated launch executes four setup trades, a measured trade, a 120-second warp and another measured trade (the trade helper advances another 12 seconds). Separate vectors prove falling/flat minimum fees and zero-maximum free trading. Fresh canonical V6 actors are source-shipped and fork-local; no V5 deployment is relabelled. Core-only/composed fixtures also pass malformed/trailing lifecycle and collector getter regressions. Null author identity is not production admission or author-control proof.

## Expanded response verification

The original 120-second comparison is a smoke check, not sufficient response-curve coverage. The real-fork harness additionally executes:

- Eight independent `(minimum, maximum, sensitivity)` policies: `(750,10000,3000)`, `(750,10000,6000)`, `(250,10000,3000)`, `(750,20000,3000)`, `(750,1000,3000)`, `(500,10000,0)`, `(0,10000,3000)`, `(750,750,6000)`. Each launches in both input-token and quote-token fee modes.
- Actual normalized spot rises of 1, 8, 17 and 80 ticks, created by exact-output swaps. Genuine oracle writes sample those moves at 1-, 12- and 60-second intervals; the 80-tick move is observed initially as 17 ticks because of the configured clamp.
- Idle waits of 1, 5, 12, 30, 60, 120, 300, 900, 3,600, 86,400 and 604,800 seconds. Total signal age is observation interval plus idle wait, not idle wait alone.
- Both buy and sell swaps at every point: 8 policies × 2 fee modes × 4 rises × 3 intervals × 11 waits × 2 directions = **4,224 measured charged swaps**. Every swap asserts wallet balances, manager deltas, the exact accrued fee, backing and oracle history. Rates must match the independently calculated bounded formula, decay monotonically with cap/floor plateaus, and reach these policies' minimum after one week.

Each time point replays the same genuine sampled state with fork-local snapshots, isolating idle-age decay from new observations. These are actual executed swaps, not preview-only results. A separate sequential scenario exercises the history changes rather than resetting them.

Observed baseline `(750,10000,3000)` rates in pips, with a 12-second observation interval; both fee modes and both directions agree:

| Raw rise | Initially observed rise | Idle 1s | Idle 12s | Idle 120s | Idle 900s | Idle 1h | Idle 1d | Idle 1w |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 980 | 875 | 772 | 753 | 750 | 750 | 750 |
| 8 | 8 | 2,596 | 1,750 | 931 | 776 | 756 | 750 | 750 |
| 17 | 17 | 4,673 | 2,875 | 1,136 | 805 | 764 | 750 | 750 |
| 80 | 17 | 4,673 | 2,875 | 1,136 | 805 | 764 | 750 | 750 |

Matched controls: doubling sensitivity changes the 17-tick, 12-second-interval, 12-second-idle charge from 2,875 to 5,000 pips. Raising the maximum to 20,000 leaves that uncapped charge at 2,875, but changes the capped 1-second-interval/1-second-idle charge from 10,000 to 20,000. The low-ceiling policy stays at 1,000 through 120 seconds of idle, then drops to 913 at 300 seconds. Zero sensitivity and equal bounds remain constant at their selected minimum.

Sequential baseline scenario: after an 80-tick raw rise, six quiet swaps spaced 12 seconds apart charge **2,875, 2,875, 2,875, 2,875, 2,250, 750** pips. The truncated oracle catches up despite nearly flat raw spot; fees do not necessarily fall on every subsequent trade. After a day at the minimum, a new eight-tick rise reactivates a 1,750-pip charge. The price-moving swap and the first observer swap still charge 750, proving freeze-before-observation ordering.

Current qualification observed **34 dynamic tests passing** and **16 passing tests on each static fixture**. Each static fixture intentionally skips the 18 dynamic-policy-only scenarios. This is deterministic fork-local behavioral evidence, not live deployment, production admission or a manipulation-resistance proof. Compiler settings and submitted hook runtime are unchanged.

## Granular boundaries and trading

The eleven coarse idle durations are retained as long-horizon smoke coverage, not presented as dense temporal or swap-size coverage. Additional real-swap regressions target rate transitions, settlement rounding and changing history separately:

- **Second-by-second rates:** sample a genuine 17-tick rise at a one-second interval, then execute both trade directions at every total signal age from **2 through 300 seconds**. Three policies independently cover baseline `(750,10000,3000)`, low ceiling `(750,1000,3000)` and doubled sensitivity `(750,10000,6000)`, in both fee modes. Five adjacent seconds around each `G × 17 / 100`, `G × 17 / 2` and `G × 17` boundary cover integer-pip transitions, including the first second at the minimum. This adds **3,768 measured swaps** across 314 ages per policy/mode. The protocol uses integer-second timestamps; subsecond warp differences are not a distinct policy input.
- **Swap-size controls:** actual raw requests of `10^6`, `10^9`, `10^12`, `10^15`, `10^17` and `10^18` units, both directions, exact-input and exact-output, both fee modes, at total ages 1, 4, 5, 6, 203, 204, 205, 51,000 and 51,001. These **432 measured swaps** span twelve orders of magnitude and include zero-idle execution, cap release and minimum restoration.
- **Adjacent raw units:** for actual rates 10,000, 9,250, 751 and 750 pips, request one raw unit below, at and above the first and second nonzero integer fee thresholds. The **192 actual swaps** check both directions, amount modes and fee modes. For specified fee-asset quantities, explicitly assert `floor(quantity × rate / 1,000,000)`; for the other branches, the existing full wallet/delta/accrued-fee assertion checks the executed basis.
- **Continuous trading:** 64 successive swaps per fee mode with **no between-swap state reset**, alternating buy/sell and mixing exact-input/output requests from `10^12` through `5 × 10^18` raw units. Delays follow 1, 1, 2, 1, 3, 5, 1 and 7 seconds. Each frozen charge is checked against an independent reference reconstructed from public genuine oracle observations before execution. Input-token mode encountered 19 rising, 22 falling and 23 flat signals; quote-token mode encountered 18 rising, 21 falling and 25 flat signals. Different fee assets affect the subsequent pool path, so continuous histories need not produce identical rates across modes.
- **Block/timestamp ordering:** four new blocks at the same timestamp cannot turn one genuine observation into two; all warm-up swaps charge the minimum. Once a second genuine observation exists, multiple same-block price-moving swaps leave the oracle unchanged. A new block with zero elapsed seconds does not append fabricated history; the next elapsed second resumes sampling. Both fee modes exercise actual settlement throughout.

Observed adjacent-second rates (pips), with minimum 750 and an initially observed 17-tick rise; ages below are **total signal ages**, not idle delays:

| Policy `(maximum, sensitivity)` | Boundary | Before age → rate | Next age → rate |
|---|---|---:|---:|
| `(10000,3000)` | Cap release | 5 → 10,000 | 6 → 9,250 |
| `(10000,6000)` | Cap release | 11 → 10,000 | 12 → 9,250 |
| `(1000,3000)` | Cap release | 204 → 1,000 | 205 → 998 |
| `(10000,3000)` | Two-pip → one-pip uplift | 25,500 → 752 | 25,501 → 751 |
| `(10000,3000)` | Minimum restoration | 51,000 → 751 | 51,001 → 750 |
| `(10000,6000)` | Minimum restoration | 102,000 → 751 | 102,001 → 750 |

Observed specified fee-asset rounding: at 10,000 pips, requests of 99/100/101 raw units charge **0/1/1** units, and 199/200/201 charge **1/2/2**. At 750 pips, 1,333/1,334/1,335 charge **0/1/1**, and 2,666/2,667/2,668 charge **1/2/2**. A positive minimum rate can therefore produce a zero integer fee for a sufficiently small request; that is settlement rounding, not a zero configured rate.

Every executed path retains the existing exact charged-fee, wallet/manager delta, backing and oracle-history checks. Fixed-signal sweeps and size comparisons use honest replay snapshots; continuous and block-ordering scenarios do not reset between swaps. This is targeted deterministic coverage of the selected policies and histories, not exhaustive coverage of all possible liquidity states, price paths or adversarial strategies.
