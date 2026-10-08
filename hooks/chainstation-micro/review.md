# ChainstationMicroHook

Chainstation micro markets: memecoins paired only with CSX, where buys need a single-use pass issued after a human check and sells are never gated.

## Formula and rounding

- Fee: static reference schedule. Zero pool LP fee. The creator-configured `hookFeePips` is charged through hook deltas as `floor(amount * hookFeePips / 1_000_000)`, using the base's frozen-rate rules unchanged. Chainstation launches use `hookFeePips = 10_000` (1%), but the hook does not enforce that value.
- Fee currency: **QuoteOnly**. Every fee accrues in CSX, in both directions. A launch selecting InputToken reverts at hook construction. `feeModeFlags: 2` declares this.
- Author payment: `authorFeeBps() = 0`. Chainstation takes its share downstream as each launch's fee owner, not through the registry royalty.

## Admission rules (the only behavior added)

1. **CSX-only pairing.** The constructor reverts unless `quoteCurrency == CSX` (`0x30C8562dBb63B3FfD3a4230Dc5B370dE7E257F50`). No hook instance can exist for another quote, so no pool or market can either. `requiredQuoteCurrency()` declares it.
2. **Pass-gated buys.** Enforced in the base's existing `_onBeforeSwap` seam (see below). A swap is a buy when CSX goes in: `zeroForOne == (CSX < token)`, for exact input and exact output alike. After `completePoolOpening`, a buy must carry
   `hookData = abi.encode(uint256 maxQuoteIn, bytes32 nonce, uint256 deadline, bytes signature)`.
   - `signature` is checked against `SWAP_PASS_SIGNER` (`0x05cd4C5d7503cdEB0cB0f43E0537f52a1EB3C9F9`) over EIP-712 `SwapPass(address buyer,uint256 maxQuoteIn,bytes32 nonce,uint256 deadline)`. The domain is name `ChainstationMicroHook`, version `1`, chain ID, and this hook's address. That address makes a pass specific to one pool. The check uses Solady `SignatureCheckerLib`: ECDSA for an EOA, ERC-1271 for a contract or EIP-7702 account.
   - `buyer` is `tx.origin`. A pass copied from the mempool is useless to any other sender, whatever router either side uses.
   - `block.timestamp > deadline` reverts. A nonce is single-use per hook (`swapPassUsed`). It is spent inside the swap, so a reverted swap reverts the spend too.
   - A bounded pass (`maxQuoteIn != type(uint256).max`) admits only exact-input buys with `-amountSpecified <= maxQuoteIn`, the CSX paid with the fee included. An unbounded pass admits any buy form or size.
3. **Sells are never gated.** Any router, caller or size, with or without hookData. Before opening completes, swaps are also not gated, so the launch's own opening buys work unchanged.
4. **Supply-agnostic.** Nothing reads the token supply. Chainstation launches a fixed 500,000-token supply (whole supply as the market's `tokenBudget`, no opening buy); the launch validator only requires `0 < tokenBudget <= supply`.

Errors: `QuoteMustBeCsx`, `QuoteOnlyFeeModeRequired`, `SwapPassRequired`, `SwapPassExpired`, `SwapPassAmount`, `SwapPassUsed`, `SwapPassInvalid`. Event: `SwapPassSpent(nonce, buyer)`.

## Changes, dependencies, authority

- **No base change.** `PoolBoundLaunchHookBaseV2` and every file under `contracts/src` are byte-identical to `main`. Existing hooks compile to byte-identical runtime and initcode (sha256 compared against `main`): ReferenceBoundHook 18,001, DynamicFeeHook 24,047, StaticOracleHook 23,550.
- **Where the gate runs.** The base's nonvirtual `beforeSwap` (manager-only, `nonReadReentrant`, `nonFeeReentrant`, after pool and author-terms authentication) calls `_freezeSwapRate`, which calls `internal virtual _onBeforeSwap(int24, uint128)` before LP checkpoints and fee accrual. The hook overrides that seam. A revert there aborts the swap and every hook write with it. In the base, `_freezeSwapRate` is reached only from `beforeSwap`; `feeRate` (the view preview) and the liquidity callbacks do not call it.
- **Reading the swap.** The seam receives no params or hookData. Inside it `msg.data` is still the PoolManager's `beforeSwap(address,PoolKey,SwapParams,bytes)` calldata, so the hook checks `msg.sig == IHooks.beforeSwap.selector` (anything else is a no-op) and `abi.decode(msg.data[4:], (address, PoolKey, SwapParams, bytes))` for direction, amount and hookData. `onlyPoolManager` guarantees the calldata is the manager's own standard ABI encoding, and the base has already decoded the same bytes as calldata arguments.
- **Opening state.** `_openingCompletedAt` is private, so the hook reads it through the base's public `openingCompletedAt(boundPoolId)` with a self-`staticcall`. That getter has no reentrancy modifier (only `_requireBoundPool`), and `beforeSwap` only runs while the guard slot is clear, so the self-call cannot hit `Reentrancy()`. It is made only for buys.
- **Dependencies.** Solady `SignatureCheckerLib`, already vendored. No companion contract, no router, no external call except that self-`staticcall` and the ERC-1271 `staticcall` to the constant signer when that signer has code.
- **Authority.** No owner, admin, pause, upgrade, sweep or recipient. The signer is a compile-time constant and cannot be rotated in place. A new signer means a new artifact for new launches.
- **Qualification.** The unchanged harness launches with WETH and buys without hookData, so it cannot qualify this hook as is (every launch reverts `QuoteMustBeCsx`). Two ways: (a) an opt-in, ABI-derived harness extension confined to `contracts/test`, `scripts/check_hooks.py` and `tests/` (launch with `requiredQuoteCurrency()`; on the fork etch a permissive ERC-1271 account at `swapPassSigner()` and attach pass hookData; two gate tests that run only for declaring hooks; non-declaring hooks run exactly as before), or (b) no harness change, with this hook qualified manually by a CSX launch and test buys (recipe in the PR).

## Boundaries and liveness risks

- **Signer unavailable means no new buys.** If Chainstation stops signing, or the key is lost, buys on existing pools are refused permanently. Sells and fee collection keep working, so holders can always exit. With an EIP-7702 delegation the signer EOA can move to a rotatable ERC-1271 implementation without a new artifact.
- **Signer compromise means the gate is bypassed.** Anyone holding the key can mint passes, so buys become ungated. It cannot touch custody, fees, sells or liquidity.
- **`tx.origin` binding.** Relayed or meta-transactions and ERC-4337 bundles carry the relayer or bundler as origin. A pass for them must name that origin, which defeats the binding. Chainstation signs only for the member's sending wallet.
- **Exact-output buys** need an unbounded pass. Chainstation's app issues bounded exact-input passes only.
- **Decoding assumption.** The gate relies on the seam being reached only inside the manager's `beforeSwap` call frame. That holds for this base as published; a future base that called `_freezeSwapRate` from another external entry point would make the gate a no-op there (selector check), not a false refusal. The artifact is pinned, so a base change would need a new artifact anyway.
- Hook-level code is reachable only from `beforeSwap`. It writes one storage slot per buy, plus one event. Measured runtime is 19,957 bytes and initcode 24,541, against limits of 24,576 and 49,152.

## Input rationale and verification

- `developerFeeBps: 0`. `feeModeFlags: 2` (QuoteOnly only). Other bounds are the canonical ranges.
- Verification: structure check, Python unit suite, fork qualification of this hook and `reference-bound` under the extended harness, and a 500,000-token-supply launch of this hook. See the PR body for the commands and results.
