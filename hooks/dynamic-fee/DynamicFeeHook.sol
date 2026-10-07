// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolBoundHookParametersV1 } from "@black-market/hooks/v4/PoolBoundHookParametersV1.sol";
import { PoolBoundLaunchHookBaseV2 } from "@black-market/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";
import { LaunchHookFeeContextV2 } from "@black-market/hooks/v4/authoring/LaunchHookFeeRateV2.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev Internal pure arithmetic shared with the constructor-free unit harness.
library DynamicFeeHookRate {
    uint256 private constant Q96 = 1 << 96;

    function calculate(LaunchHookFeeContextV2 memory context) internal pure returns (uint24) {
        uint256 maximum = context.maximumPips;
        if (maximum == 0) return 0;
        // Exact output does not disclose eventual input; unavailable reserves are conservative too.
        if (context.amountSpecified > 0 || context.activeLiquidity == 0 || context.sqrtPriceX96 == 0) {
            return uint24(maximum);
        }

        uint256 reserve = context.zeroForOne
            ? FixedPointMathLib.fullMulDiv(context.activeLiquidity, Q96, context.sqrtPriceX96)
            : FixedPointMathLib.fullMulDiv(context.activeLiquidity, context.sqrtPriceX96, Q96);
        if (reserve == 0) return uint24(maximum);

        // The final base wrapper rejects int256.min before calling this seam. Valid pool prices
        // bound reserve to 192 bits; input <= int256.max, so reserve + input fits uint256.
        uint256 input = uint256(-context.amountSpecified);
        uint256 baseline = maximum / 5;
        return uint24(baseline + FixedPointMathLib.fullMulDiv(maximum - baseline, input, reserve + input));
    }
}

/// @notice Reference DynamicFeeHook example; not an admitted production hook.
/// @dev Inherited callbacks freeze this pure pre-swap rate once and retain all fee accounting.
contract DynamicFeeHook is PoolBoundLaunchHookBaseV2 {
    constructor(PoolBoundHookParametersV1 memory parameters) PoolBoundLaunchHookBaseV2(parameters) { }

    function authorFeeBps() public pure override returns (uint16) {
        return 500;
    }

    function swapFeeModel() public pure override returns (SwapFeeModel) {
        return SwapFeeModel.Dynamic;
    }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal pure override returns (uint24) {
        return DynamicFeeHookRate.calculate(context);
    }
}
