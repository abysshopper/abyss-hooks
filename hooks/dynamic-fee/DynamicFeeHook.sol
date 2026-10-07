// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolBoundHookParametersV1 } from "@black-market/hooks/v4/PoolBoundHookParametersV1.sol";
import { PoolBoundTruncatedOracleV2 } from "@black-market/hooks/v4/authoring/PoolBoundTruncatedOracleV2.sol";
import { LaunchHookFeeContextV2 } from "@black-market/hooks/v4/authoring/LaunchHookFeeRateV2.sol";

/// @dev Internal pure oracle-signal arithmetic shared with the constructor-free unit harness.
library DynamicFeeHookRate {
    function calculate(uint24 maximumPips, int256 tickChange, uint32 elapsed, uint24 maximumMove)
        internal
        pure
        returns (uint24)
    {
        uint256 maximum = maximumPips;
        uint256 baseline = maximum / 5;
        if (tickChange <= 0 || elapsed == 0 || maximumMove == 0) return uint24(baseline);

        unchecked {
            // Capacity is below 2^56. Saturation makes rise * 30 < capacity, so the
            // uplift numerator is below 2^80 and baseline + uplift never exceeds maximum.
            uint256 capacity = uint256(maximumMove) * elapsed;
            uint256 rise = uint256(tickChange);
            // Saturate before multiplying an arbitrary signed signal by the 30-second response.
            if (rise >= (capacity + 29) / 30) return maximumPips;
            return uint24(baseline + (maximum - baseline) * (rise * 30) / capacity);
        }
    }
}

/// @notice Reference DynamicFeeHook example; not an admitted production hook.
/// @dev Upward quote-per-base tick velocity raises the fee; quiet or falling prices use baseline.
///      Inherited callbacks freeze the pre-swap oracle rate once and retain all fee accounting.
contract DynamicFeeHook is PoolBoundTruncatedOracleV2 {
    constructor(PoolBoundHookParametersV1 memory parameters) PoolBoundTruncatedOracleV2(parameters) { }

    function authorFeeBps() public pure override returns (uint16) {
        return 500;
    }

    function swapFeeModel() public pure override returns (SwapFeeModel) {
        return SwapFeeModel.Dynamic;
    }

    function _initialOracleCapacity() internal pure override returns (uint16) {
        return 2;
    }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal view override returns (uint24) {
        if (context.maximumPips == 0) return 0;
        (int256 tickChange, uint32 elapsed, uint24 maximumMove) = _oraclePriceMovement();
        return DynamicFeeHookRate.calculate(context.maximumPips, tickChange, elapsed, maximumMove);
    }
}
