// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILaunchFeeOwnerRegistry } from "../../../interfaces/ILaunchRewards.sol";

/// @notice Post-executor distribution fractions for one committed ERC20 asset.
struct FeeAssetPolicyV2 {
    address asset;
    uint16 ownerBps;
    uint16 rewardsBps;
    uint16 burnBps;
}

/// @notice The exact newly-collected-fee payment to the caller, including zero payments.
struct ExecutorPaymentV2 {
    address asset;
    uint256 amount;
}

/// @notice Immutable, bounded multiasset reward funding and identity boundary.
interface ILaunchFeeRewardsV2 {
    /// @notice The immutable, strictly ascending set of one to eight supported ERC20 assets.
    function rewardAssets() external view returns (address[] memory);

    /// @notice The immutable hub authorized to fund and notify this reward module.
    function distributor() external view returns (address);

    /// @notice ERC20 custody available for rewards, excluding any same-asset staking principal.
    function rewardAvailableBalance(address asset) external view returns (uint256);

    /// @notice Accounts for already-transferred funding in the order of `rewardAssets()`.
    /// @dev Every supported asset has one amount, including zeros. Notification must not move
    ///      reward custody or staking principal. The hub funds all assets before this call.
    function notifyRewardAmounts(uint256[] calldata amounts) external;
}

/// @notice Fixed all-source/all-asset routing with an owner-adjustable harvesting bounty.
/// @dev Sources reuse the unchanged ILaunchFeeSourceV1 collection boundary.
interface ILaunchFeeHubV2 {
    event ExecutorFeeUpdated(address indexed feeOwner, uint16 previousFeeBps, uint16 newFeeBps);

    function MAX_EXECUTOR_FEE_BPS() external view returns (uint16);
    function launchToken() external view returns (address);
    function feeOwnerRegistry() external view returns (ILaunchFeeOwnerRegistry);
    function configurator() external view returns (address);
    function executorFeeBps() external view returns (uint16);

    /// @notice Current registered fee owner may set the bounty from 0 through 1,000 bps.
    /// @dev Applies immediately to the next harvest, including previously accrued fees.
    function setExecutorFeeBps(uint16 newFeeBps) external;
    function requiresOwner() external view returns (bool);
    function requiresRewards() external view returns (bool);
    function finalized() external view returns (bool);
    function rewards() external view returns (address);

    function assets() external view returns (address[] memory);
    function sources() external view returns (address[] memory);
    function policy(address asset) external view returns (FeeAssetPolicyV2 memory);
    function sourceId(address source) external view returns (bytes32);
    function sourceById(bytes32 id) external view returns (address);
    function sourceAssets(address source) external view returns (address[] memory);
    function rewardAssets() external view returns (address[] memory);
    function rewardAssetsHash() external view returns (bytes32);

    /// @notice Finalizes ready, unique sources and the compatible reward module exactly once.
    function configureSources(address[] calldata sources_, address rewards_) external;

    /// @notice Collects every bound source and routes every committed asset atomically.
    /// @dev `eth_call` simulation uses this exact non-view, no-argument entrypoint. Results are
    ///      in ascending ERC20-address order and include every committed asset, even at zero.
    ///      Only newly collected canonical fees earn a bounty; inventory and credits do not.
    function claimAndSplit() external returns (ExecutorPaymentV2[] memory payments);

    function claimableOwnerFees(address owner, address asset) external view returns (uint256);
    function reservedOwnerFees(address asset) external view returns (uint256);

    /// @notice Withdraws only the caller's reserved owner credits, without fees or bounty.
    function claimOwnerFees(address asset, address recipient) external returns (uint256 amount);
}
