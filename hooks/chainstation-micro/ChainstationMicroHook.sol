// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolBoundHookParametersV2 } from "@black-market/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundLaunchHookBaseV2 } from "@black-market/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";

/// @title Chainstation micro-market hook: CSX-paired, pass-gated buys, open sells.
/// @notice Static reference fee schedule (QuoteOnly, so every fee accrues in CSX). Three rules:
///         1. The pool's quote currency is CSX. Any other quote reverts at construction, so no
///            hook instance, pool or market can exist for a non-CSX pair.
///         2. Fees accrue only in the quote currency (QuoteOnly); InputToken reverts at
///            construction.
///         3. After opening completes, a BUY (CSX in, exact-in or exact-out) needs `hookData`
///            carrying a single-use EIP-712 `SwapPass` signed by `SWAP_PASS_SIGNER` for the
///            transaction's origin. SELLS ARE NEVER GATED. Opening buys executed by the launch
///            itself, before `completePoolOpening`, are not gated.
/// @dev No owner, no admin, no upgrade, no sweep, no recipient. `authorFeeBps` is zero.
///      Uses the unmodified base: the gate lives in the existing `_onBeforeSwap` observer seam.
contract ChainstationMicroHook is PoolBoundLaunchHookBaseV2 {
    error QuoteMustBeCsx();
    error QuoteOnlyFeeModeRequired();
    error SwapPassRequired();
    error SwapPassExpired();
    error SwapPassAmount();
    error SwapPassUsed();
    error SwapPassInvalid();

    /// @notice Chainstation's token on Robinhood Chain; the only admissible quote currency.
    address public constant CSX = 0x30C8562dBb63B3FfD3a4230Dc5B370dE7E257F50;
    /// @notice The pass authority. EOA (ECDSA) or contract/EIP-7702 account (ERC-1271).
    address public constant SWAP_PASS_SIGNER = 0x05cd4C5d7503cdEB0cB0f43E0537f52a1EB3C9F9;
    /// @notice A pass without an amount bound; it also admits exact-output buys.
    uint256 public constant UNBOUNDED = type(uint256).max;
    bytes32 public constant SWAP_PASS_TYPEHASH =
        keccak256("SwapPass(address buyer,uint256 maxQuoteIn,bytes32 nonce,uint256 deadline)");
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("ChainstationMicroHook");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    bool private immutable _quoteIsCurrency0;

    /// @notice Spent pass nonces. One hook serves one pool, so the space is per pool.
    mapping(bytes32 nonce => bool) public swapPassUsed;

    event SwapPassSpent(bytes32 indexed nonce, address indexed buyer);

    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundLaunchHookBaseV2(parameters) {
        if (parameters.quoteCurrency != CSX) revert QuoteMustBeCsx();
        if (parameters.feeMode != uint8(FeeMode.QuoteOnly)) revert QuoteOnlyFeeModeRequired();
        _quoteIsCurrency0 = parameters.quoteCurrency < parameters.token;
    }

    function authorFeeBps() public pure override returns (uint16) {
        return 0;
    }

    /// @notice Declared for tooling: every pool of this hook is quoted in this currency.
    function requiredQuoteCurrency() external pure returns (address) {
        return CSX;
    }

    /// @notice Declared for tooling: buys after opening need a pass signed by this authority.
    function swapPassSigner() external pure returns (address) {
        return SWAP_PASS_SIGNER;
    }

    /// @notice EIP-712 digest of `SwapPass(buyer, maxQuoteIn, nonce, deadline)` for this hook.
    function swapPassDigest(address buyer, uint256 maxQuoteIn, bytes32 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
        bytes32 structHash =
            keccak256(abi.encode(SWAP_PASS_TYPEHASH, buyer, maxQuoteIn, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @dev The base's nonvirtual `beforeSwap` (manager-only, after pool and author-terms
    ///      authentication) calls `_freezeSwapRate`, which calls this seam before LP checkpoints
    ///      and fee accrual; a revert here aborts the whole swap. The seam receives no params or
    ///      hookData, so they are read back from the call frame: inside `beforeSwap`, `msg.data`
    ///      is the PoolManager's `beforeSwap(sender, key, params, hookData)` calldata. Any other
    ///      entry point is a no-op (in the base only `beforeSwap` reaches this seam).
    ///
    ///      `hookData` = abi.encode(uint256 maxQuoteIn, bytes32 nonce, uint256 deadline, bytes sig).
    ///      The buyer is `tx.origin`: the pass is bound to the wallet that sends the transaction,
    ///      whatever router it uses, so a pass copied from the mempool is useless to anyone else.
    ///      A bounded pass admits only exact-input buys of at most `maxQuoteIn` CSX (fee
    ///      included); `UNBOUNDED` admits any buy size and form. The nonce is spent here; a
    ///      reverted swap reverts the spend with it.
    function _onBeforeSwap(int24, uint128) internal override {
        if (msg.sig != IHooks.beforeSwap.selector) return;
        (,, SwapParams memory params, bytes memory hookData) =
            abi.decode(msg.data[4:], (address, PoolKey, SwapParams, bytes));
        if (params.zeroForOne != _quoteIsCurrency0) return;
        // Opening state through the base's public getter. `openingCompletedAt` carries no
        // reentrancy modifier, and `beforeSwap` itself only runs while the guard is clear.
        if (this.openingCompletedAt(boundPoolId) == 0) return;
        if (hookData.length == 0) revert SwapPassRequired();
        (uint256 maxQuoteIn, bytes32 nonce, uint256 deadline, bytes memory signature) =
            abi.decode(hookData, (uint256, bytes32, uint256, bytes));
        if (block.timestamp > deadline) revert SwapPassExpired();
        if (
            maxQuoteIn != UNBOUNDED
                && (params.amountSpecified >= 0 || uint256(-params.amountSpecified) > maxQuoteIn)
        ) revert SwapPassAmount();
        if (swapPassUsed[nonce]) revert SwapPassUsed();
        if (
            !SignatureCheckerLib.isValidSignatureNow(
                SWAP_PASS_SIGNER, swapPassDigest(tx.origin, maxQuoteIn, nonce, deadline), signature
            )
        ) revert SwapPassInvalid();
        swapPassUsed[nonce] = true;
        emit SwapPassSpent(nonce, tx.origin);
    }
}
