// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { V4FeeCollectorV2 } from "../../fees/v2/V4FeeCollectorV2.sol";
import { V4FeeLiquidityLockerV2 } from "../../fees/v2/V4FeeLiquidityLockerV2.sol";

/// @notice Separately deployed, exact canonical V2 collector creation code.
/// @dev Permissionless typed creation grants no source admission, binding or payout authority.
///      The admitted graph pins this runtime independently of the configuration helper.
contract PoolFeeCollectorDeployerV1 {
    function create(address hub, V4FeeLiquidityLockerV2 locker, PoolKey calldata key,
        uint256 expectedPositionCount) external returns (V4FeeCollectorV2 collector)
    {
        collector = new V4FeeCollectorV2(hub, locker, key, expectedPositionCount);
    }
}
