// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILaunchFeeOwnerRegistry } from "../../../interfaces/ILaunchRewards.sol";

/// @notice Post-executor distribution fractions for one committed ERC20 asset.
struct FeeAssetPolicyV1 {
    address asset;
    uint16 ownerBps;
    uint16 rewardsBps;
    uint16 burnBps;
}

/// @notice The exact newly-collected-fee payment to the caller, including zero payments.
struct ExecutorPaymentV1 {
    address asset;
    uint256 amount;
}

/// @notice A permanently bound, hub-only collection boundary for canonical venue fees.
interface ILaunchFeeSourceV1 {
    function hub() external view returns (address);
    function assets() external view returns (address[] memory);
    function sourceId() external view returns (bytes32);

    /// @notice Reverts until all immutable venue, custody, and collection bindings are ready.
    function validateBinding() external view;

    /// @notice Claims every bound position/source and sends only its exact new fees to `hub`.
    /// @dev Only the bound hub may call. Amounts follow this source's ascending `assets()` order;
    ///      old balances and donations are neither reported nor forwarded.
    function collect() external returns (uint256[] memory amounts);
}

/// @notice The existing one/two-asset StreamedRewardsV2 funding and identity boundary.
interface ILaunchFeeRewardsV1 {
    function rewardToken0() external view returns (address);
    function rewardToken1() external view returns (address);
    function rewardsDistributor() external view returns (address);
    function notifyRewardAmount(address rewardToken, uint256 amount) external;
}

/// @notice Opt-in, immutable, all-source/all-asset ERC20 launch fee routing.
interface ILaunchFeeHubV1 {
    function launchToken() external view returns (address);
    function feeOwnerRegistry() external view returns (ILaunchFeeOwnerRegistry);
    function configurator() external view returns (address);
    function executorFeeBps() external view returns (uint16);
    function requiresOwner() external view returns (bool);
    function requiresRewards() external view returns (bool);
    function finalized() external view returns (bool);
    function rewards() external view returns (address);

    function assets() external view returns (address[] memory);
    function sources() external view returns (address[] memory);
    function policy(address asset) external view returns (FeeAssetPolicyV1 memory);
    function sourceId(address source) external view returns (bytes32);
    function sourceById(bytes32 id) external view returns (address);
    function sourceAssets(address source) external view returns (address[] memory);

    /// @notice Finalizes ready, unique sources and the compatible reward stream exactly once.
    function configureSources(address[] calldata sources_, address rewards_) external;

    /// @notice Collects every bound source and routes every committed asset atomically.
    /// @dev `eth_call` simulation uses this exact non-view, no-argument entrypoint. Results are
    ///      in ascending ERC20-address order and include every committed asset, even at zero.
    ///      Only newly collected canonical fees earn a bounty; inventory and credits do not.
    function claimAndSplit() external returns (ExecutorPaymentV1[] memory payments);

    function claimableOwnerFees(address owner, address asset) external view returns (uint256);
    function reservedOwnerFees(address asset) external view returns (uint256);

    /// @notice Withdraws only the caller's fallback credits, without collecting fees or bounty.
    function claimOwnerFees(address asset, address recipient) external returns (uint256 amount);
}
