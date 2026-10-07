// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolBoundHookParametersV2 } from "@black-market/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundLaunchHookBaseV2 } from "@black-market/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";

/// @notice CI reference schedule, not an admitted production hook.
contract ReferenceBoundHook is PoolBoundLaunchHookBaseV2 {
    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundLaunchHookBaseV2(parameters) { }

    function authorFeeBps() public pure override returns (uint16) {
        return 500;
    }
}
