// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal dynamic fee-owner lookup consumed by fee routers.
interface ILaunchFeeOwnerRegistry {
    function feeOwner(address launch) external view returns (address);
}

/// @notice Minimal streamed-reward funding boundary consumed by fee routers and module factories.
interface IStreamedRewards {
    function setRewardsDistributor(address distributor) external;
    function notifyRewardAmount(address rewardToken, uint256 amount) external;
}

/// @notice Minimal one-time tracker binding consumed by a canonical token factory.
interface IHolderDividendToken {
    function configureRewardTracker(address tracker) external;
    function rewardTracker() external view returns (address);
}

/// @notice Minimal dividend tracker configuration and identity surface.
interface IHolderDividendTracker {
    function trackedToken() external view returns (address);
    function addExcludedAccount(address account) external;
}
