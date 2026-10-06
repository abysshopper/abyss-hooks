// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice ABI of the deployed Black Market V2 permanent liquidity locker.
interface V4FeeLiquidityLockerV2 {
    struct Lock {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        address feeRecipient;
    }

    struct LockParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
        address feeRecipient;
    }

    function MAX_POSITIONS() external view returns (uint256);
    function poolManager() external view returns (IPoolManager);
    function launcher() external view returns (address);
    function positionCount(bytes32 poolId) external view returns (uint256);
    function locks(bytes32 poolId, uint256 index) external view returns (
        int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt, address feeRecipient
    );
    function isSealed(bytes32 poolId) external view returns (bool);
    function feeRecipient(bytes32 poolId) external view returns (address);
    function positionsHash(bytes32 poolId) external view returns (bytes32);
    function settledFees(bytes32 poolId, address asset) external view returns (uint256);
    function pendingClaims(bytes32 poolId, address asset) external view returns (uint256);
    function poolKey(bytes32 poolId) external view returns (PoolKey memory);
    function lock(PoolKey calldata key, LockParams calldata position)
        external returns (uint256 positionIndex, uint256 amount0, uint256 amount1);
    function sealPool(PoolKey calldata key) external;
    function validatePool(PoolKey calldata key) external view;
    function claimFees(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1);
    function checkpointFees(PoolKey calldata key, uint256 bound0, uint256 bound1)
        external returns (uint256 total0, uint256 total1);
    function inputFeeBound(PoolKey calldata key, SwapParams calldata params, uint256 precharged)
        external view returns (uint256 bound);
}
