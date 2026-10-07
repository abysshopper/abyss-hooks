// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolBoundHookParametersV2 } from "../src/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundTruncatedOracleV2 } from "../src/hooks/v4/authoring/PoolBoundTruncatedOracleV2.sol";

/// @notice Concrete opt-in candidate exercised through the real launch and pool callbacks.
contract StaticOracleHook is PoolBoundTruncatedOracleV2 {
    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundTruncatedOracleV2(parameters) { }

    function authorFeeBps() public pure override returns (uint16) {
        return 500;
    }
}
