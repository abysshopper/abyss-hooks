// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { ILaunchHookV1 } from "./ILaunchHookV1.sol";
import { ILaunchHookAuthorTerms } from "./ILaunchHookAuthorTerms.sol";

/// @notice Authenticated pre-swap inputs for the read-only author rate seam.
/// @dev amountSpecified is the original manager request, before any specified-fee precharge.
///      Exact output does not disclose its eventual input amount. Pool identity is the full-key id.
struct LaunchHookFeeContextV2 {
    bytes32 poolId;
    uint160 sqrtPriceX96;
    uint128 activeLiquidity;
    int256 amountSpecified;
    bool zeroForOne;
    uint24 maximumPips;
    ILaunchHookV1.FeeMode feeMode;
}

/// @notice Final rate/charge guards and a single-use authenticated swap-context lifetime.
/// @dev Static authors need no rate override. Dynamic authors explicitly declare their model and
///      implement _calculateRate. Added selectors, assembly and the complete artifact need review.
abstract contract LaunchHookFeeRateV2 is ILaunchHookAuthorTerms {
    error FeeTooLarge();
    error InvalidSwapContext();

    uint256 private constant RATE_DENOMINATOR = 1_000_000;
    uint256 private constant MAX_FEE_DELTA = uint256(uint128(type(int128).max));

    struct PendingSwapFee {
        bytes32 identity;
        // Zero is inactive; even a zero-rate swap stores one. One storage write per rate update.
        uint32 ratePlusOne;
    }

    function authorFeeBps() public pure virtual override returns (uint16) {
        return 0;
    }

    function swapFeeModel() public pure virtual override returns (SwapFeeModel) {
        return SwapFeeModel.Static;
    }

    /// @dev Called once, before external checkpoints. The pending slot must not be overwritten,
    ///      even for a zero-fee swap. The authenticated base supplies every context field.
    function _freezeRate(
        PendingSwapFee storage pending,
        LaunchHookFeeContextV2 memory context,
        address sender,
        SwapParams calldata params
    ) internal returns (uint24 rate) {
        if (pending.ratePlusOne != 0) revert InvalidSwapContext();
        // Internal overrides can mutate memory arguments; preserve identity by value.
        bytes32 poolId = context.poolId;
        rate = _boundedRate(context);
        pending.identity = _swapIdentity(poolId, sender, params);
        pending.ratePlusOne = uint32(rate) + 1;
    }

    /// @dev Shared by preview and freeze. Static always uses the configured maximum, regardless
    ///      of an unused _calculateRate override. Preserve signed-request guards even at zero fee.
    function _boundedRate(LaunchHookFeeContextV2 memory context) internal view returns (uint24 rate) {
        if (context.amountSpecified == type(int256).min) revert FeeTooLarge();
        uint24 maximumPips = context.maximumPips;
        rate = swapFeeModel() == SwapFeeModel.Static ? maximumPips : _calculateRate(context);
        if (rate > maximumPips) revert FeeTooLarge();
    }

    /// @dev Consume before external afterSwap checkpoints; all successful return paths clear it.
    ///      Pool-local storage plus the full identity rejects absent, foreign and stale callbacks.
    function _consumeRate(
        PendingSwapFee storage pending,
        bytes32 poolId,
        address sender,
        SwapParams calldata params
    ) internal returns (uint24 rate) {
        uint32 ratePlusOne = pending.ratePlusOne;
        if (ratePlusOne == 0 || pending.identity != _swapIdentity(poolId, sender, params)) {
            revert InvalidSwapContext();
        }
        rate = uint24(ratePlusOne - 1);
        delete pending.identity;
        delete pending.ratePlusOne;
    }

    function _swapIdentity(bytes32 poolId, address sender, SwapParams calldata params)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, sender, params));
    }

    /// @dev Final common charge: rate was bounded by the creator's maximum at freeze time.
    ///      All specified, reconciliation and unspecified paths use this same frozen rate.
    function _fee(uint256 amount, uint24 rate) internal pure returns (uint256 fee) {
        fee = FixedPointMathLib.fullMulDiv(amount, rate, RATE_DENOMINATOR);
        if (fee > MAX_FEE_DELTA) revert FeeTooLarge();
    }

    function _abs(int256 amount) internal pure returns (uint256) {
        if (amount == type(int256).min) revert FeeTooLarge();
        return uint256(amount < 0 ? -amount : amount);
    }

    /// @notice Dynamic authors implement a read-only pre-swap rate bounded by maximumPips.
    /// @dev Authors may read an explicitly composed oracle; the core adds no oracle dependency.
    ///      The default rejects Dynamic without a rate override. Inheritance is not a sandbox.
    function _calculateRate(LaunchHookFeeContextV2 memory)
        internal
        view
        virtual
        returns (uint24)
    {
        revert InvalidSwapContext();
    }
}
