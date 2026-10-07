// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SharedLaunchFeeHookV2 } from "../../../hooks/v4/SharedLaunchFeeHookV2.sol";
import { ILaunchFeeSourceV1 } from "../v1/ILaunchFeeHubV1.sol";
import { V4FeeLiquidityLockerV2 } from "./V4FeeLiquidityLockerV2.sol";

/// @notice Hub-only, full-pool collection of sealed permanent LP positions and registered hook fees.
/// @dev Deploy before root registration/locking. Finalization requires initialization and sealing.
///      Every collection includes both venues, even when the hook fee or its pending balance is zero.
contract V4FeeCollectorV2 is ILaunchFeeSourceV1, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error Unauthorized();
    error InvalidBinding();
    error ClaimMismatch();
    error InexactTransfer();

    address public immutable override hub;
    IPoolManager public immutable poolManager;
    V4FeeLiquidityLockerV2 public immutable locker;
    SharedLaunchFeeHookV2 public immutable hookRoot;
    bytes32 public immutable poolId;
    uint256 public immutable expectedPositionCount;
    address public immutable token0;
    address public immutable token1;
    PoolKey private _key;

    event FeesCollected(uint256 amount0, uint256 amount1);

    constructor(
        address hub_,
        V4FeeLiquidityLockerV2 locker_,
        PoolKey memory key_,
        uint256 expectedPositionCount_
    ) {
        address asset0 = Currency.unwrap(key_.currency0);
        address asset1 = Currency.unwrap(key_.currency1);
        if (
            hub_.code.length == 0 || address(locker_).code.length == 0
                || address(key_.hooks).code.length == 0 || asset0 == address(0) || asset0 >= asset1
                || asset0.code.length == 0 || asset1.code.length == 0
                || key_.fee > LPFeeLibrary.MAX_LP_FEE
                || key_.tickSpacing < TickMath.MIN_TICK_SPACING
                || key_.tickSpacing > TickMath.MAX_TICK_SPACING || expectedPositionCount_ == 0
                || expectedPositionCount_ > 32 || hub_ == address(this) || hub_ == address(locker_)
                || hub_ == address(key_.hooks) || hub_ == asset0 || hub_ == asset1
        ) revert InvalidBinding();
        IPoolManager manager_ = locker_.poolManager();
        SharedLaunchFeeHookV2 root_ = SharedLaunchFeeHookV2(address(key_.hooks));
        if (
            address(manager_).code.length == 0 || hub_ == address(manager_)
                || address(root_.poolManager()) != address(manager_)
                || address(root_.oracleFactory()).code.length == 0
                || address(locker_) == address(root_) || address(locker_) == address(manager_)
        ) revert InvalidBinding();
        hub = hub_;
        locker = locker_;
        poolManager = manager_;
        hookRoot = root_;
        poolId = PoolId.unwrap(key_.toId());
        expectedPositionCount = expectedPositionCount_;
        token0 = asset0;
        token1 = asset1;
        _key = key_;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function assets() external view override returns (address[] memory result) {
        result = new address[](2);
        result[0] = token0;
        result[1] = token1;
    }

    /// @dev The sealed position hash is immutable, but unavailable before locks are installed.
    ///      Hub configuration only authenticates this identity after validateBinding succeeds.
    function sourceId() external view override returns (bytes32) {
        if (!locker.isSealed(poolId)) revert InvalidBinding();
        return keccak256(
            abi.encode(
                "black-market.v4-fee-source.v2",
                address(poolManager),
                _key,
                address(locker),
                expectedPositionCount,
                locker.positionsHash(poolId)
            )
        );
    }

    function validateBinding() external view override {
        _validateConfiguration();
        locker.validatePool(_key);
    }

    function collect() external override nonReentrant returns (uint256[] memory amounts) {
        if (msg.sender != hub) revert Unauthorized();
        _validateConfiguration();
        (uint256 lp0, uint256 lp1) = _collectLiquidity();
        (uint256 hook0, uint256 hook1) = _collectHook();
        amounts = new uint256[](2);
        amounts[0] = lp0 + hook0;
        amounts[1] = lp1 + hook1;
        _forwardExact(token0, amounts[0]);
        _forwardExact(token1, amounts[1]);
        emit FeesCollected(amounts[0], amounts[1]);
    }

    function _validateConfiguration() private view {
        if (
            address(locker.poolManager()) != address(poolManager)
                || address(hookRoot.poolManager()) != address(poolManager)
                || !locker.isSealed(poolId) || locker.positionCount(poolId) != expectedPositionCount
                || locker.feeRecipient(poolId) != address(this)
                || locker.positionsHash(poolId) == bytes32(0)
        ) revert InvalidBinding();
        hookRoot.validateCollector(_key, address(this), address(locker));
    }

    function _collectLiquidity() private returns (uint256 amount0, uint256 amount1) {
        uint256 before0 = SafeTransferLib.balanceOf(token0, address(this));
        uint256 before1 = SafeTransferLib.balanceOf(token1, address(this));
        (amount0, amount1) = locker.claimFees(_key);
        _requireDelta(token0, before0, amount0);
        _requireDelta(token1, before1, amount1);
    }

    function _collectHook() private returns (uint256 amount0, uint256 amount1) {
        uint256 before0 = SafeTransferLib.balanceOf(token0, address(this));
        uint256 before1 = SafeTransferLib.balanceOf(token1, address(this));
        (amount0, amount1) = hookRoot.collectFees(_key);
        _requireDelta(token0, before0, amount0);
        _requireDelta(token1, before1, amount1);
    }

    function _requireDelta(address asset, uint256 beforeBalance, uint256 reported) private view {
        uint256 afterBalance = SafeTransferLib.balanceOf(asset, address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != reported) {
            revert ClaimMismatch();
        }
    }

    function _forwardExact(address asset, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeSource = SafeTransferLib.balanceOf(asset, address(this));
        uint256 beforeHub = SafeTransferLib.balanceOf(asset, hub);
        SafeTransferLib.safeTransfer(asset, hub, amount);
        uint256 afterSource = SafeTransferLib.balanceOf(asset, address(this));
        uint256 afterHub = SafeTransferLib.balanceOf(asset, hub);
        if (
            afterSource > beforeSource || beforeSource - afterSource != amount
                || afterHub < beforeHub || afterHub - beforeHub != amount
        ) revert InexactTransfer();
    }
}
