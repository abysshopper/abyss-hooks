// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolBoundHookParametersV2 } from "../../src/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundLaunchHookBaseV2 } from "../../src/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";

/// @notice Maintainer test subject proving zero trading fees and zero author bps are valid.
contract FreeFeeHook is PoolBoundLaunchHookBaseV2 {
    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundLaunchHookBaseV2(parameters) { }
}

/// @notice Maintainer test subject with an explicit positive-fee constructor policy.
contract PositiveFeeHook is PoolBoundLaunchHookBaseV2 {
    error PositiveFeeRequired();

    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundLaunchHookBaseV2(parameters) {
        if (parameters.hookFeePips == 0) revert PositiveFeeRequired();
    }
}
