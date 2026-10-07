# ReferenceBoundHook

- Base: `PoolBoundLaunchHookBaseV2`; one exact pool key per instance, with inherited lifecycle, custody and accounting. No oracle history or separately deployed validation helper; oracle composition is optional.
- Trading fees: Static; zero pool LP fee. Creator-configured trading fees use hook deltas with full-precision `floor(amount * configuredHookPips / 1_000_000)`, in InputToken or QuoteOnly mode.
- Author payment: `authorFeeBps()` declares 500 bps of source-attributed owner proceeds after bounty. This is not a swap surcharge. The existing V3 hub pays the registered author; the hook rejects a different frozen rate before liquidity acquisition.
- Changes: author-payment declaration only; typed constructor and inherited fee behavior unchanged.
- Integration: reference only, with a fork test identity rather than a proposed production author. Bounds declare the canonical registry range, not exhaustive test coverage.
- Risks: the complete inherited runtime, inline validation and dependency graph require permissioned review. Qualification is not production admission.
- License: MIT; dependency licenses remain applicable.
