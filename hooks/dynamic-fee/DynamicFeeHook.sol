// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolBoundHookParametersV2 } from "@black-market/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundTruncatedOracleV2 } from "@black-market/hooks/v4/authoring/PoolBoundTruncatedOracleV2.sol";
import { LaunchHookFeeContextV2 } from "@black-market/hooks/v4/authoring/LaunchHookFeeRateV2.sol";

/// @dev Internal pure oracle-signal arithmetic shared with the constructor-free unit harness.
library DynamicFeeHookRate {
    function calculate(
        uint24 minimumPips,
        uint24 maximumPips,
        uint32 sensitivity,
        int256 tickChange,
        uint32 elapsed
    ) internal pure returns (uint24) {
        if (minimumPips >= maximumPips) return maximumPips;
        if (tickChange <= 0 || elapsed == 0 || sensitivity == 0) return minimumPips;
        unchecked {
            // Headroom * elapsed fits 56 bits. The strict threshold saturates before
            // multiplication; at equality the product still fits and may return maximum.
            uint256 capacity = uint256(maximumPips - minimumPips) * elapsed;
            uint256 rise = uint256(tickChange);
            if (rise > capacity / sensitivity) return maximumPips;
            return uint24(uint256(minimumPips) + rise * sensitivity / elapsed);
        }
    }
}

/// @notice Reference DynamicFeeHook example; not an admitted production hook.
/// @dev Upward quote-per-base tick velocity raises the fee; quiet or falling prices use baseline.
///      Inherited callbacks freeze the pre-swap oracle rate once and retain all fee accounting.
contract DynamicFeeHook is PoolBoundTruncatedOracleV2 {
    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundTruncatedOracleV2(parameters) { }

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
        if (context.maximumPips == context.minimumPips || context.feeSensitivityPipsSecondsPerTick == 0) {
            return context.minimumPips;
        }
        (int256 tickChange, uint32 elapsed) = _oraclePriceMovement();
        return DynamicFeeHookRate.calculate(
            context.minimumPips, context.maximumPips, context.feeSensitivityPipsSecondsPerTick,
            tickChange, elapsed
        );
    }
}
