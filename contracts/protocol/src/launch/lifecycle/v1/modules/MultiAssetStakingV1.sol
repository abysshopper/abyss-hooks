// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MultiAssetStreamV1 } from "./MultiAssetStreamV1.sol";

/// @notice One non-transferable stake entitlement for the immutable 1..8-asset reward set.
/// @dev Staked launch-token principal is never counted as reward funding, even when the launch
///      token is also a reward asset. Neither the distributor nor the factory can withdraw it.
contract MultiAssetStakingV1 is MultiAssetStreamV1 {
    error InvalidStakingToken();
    error InsufficientStake();

    event Staked(address indexed payer, address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed beneficiary, uint256 amount);

    address public immutable stakingToken;
    uint256 public totalStaked;
    mapping(address account => uint256 amount) public stakedBalance;

    constructor(address stakingToken_, address distributor_, address[] memory assets) {
        if (stakingToken_ == address(0) || stakingToken_.code.length == 0) revert InvalidStakingToken();
        stakingToken = stakingToken_;
        _initializeRewards(assets, distributor_);
    }

    function stake(uint256 amount) external nonReentrant {
        _stake(msg.sender, msg.sender, amount);
    }

    function stakeFor(address beneficiary, uint256 amount) external nonReentrant {
        if (beneficiary == address(0)) revert ZeroAddress();
        _stake(msg.sender, beneficiary, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedBalance[msg.sender];
        if (amount > staked) revert InsufficientStake();
        _checkpointRewards(msg.sender);
        _setRewardShare(msg.sender, staked - amount);
        totalStaked -= amount;
        stakedBalance[msg.sender] = staked - amount;
        uint256 sourceBefore = SafeTransferLib.balanceOf(stakingToken, address(this));
        uint256 beneficiaryBefore = SafeTransferLib.balanceOf(stakingToken, msg.sender);
        SafeTransferLib.safeTransfer(stakingToken, msg.sender, amount);
        uint256 sourceAfter = SafeTransferLib.balanceOf(stakingToken, address(this));
        uint256 beneficiaryAfter = SafeTransferLib.balanceOf(stakingToken, msg.sender);
        if (
            sourceAfter > sourceBefore || sourceBefore - sourceAfter != amount
                || beneficiaryAfter < beneficiaryBefore || beneficiaryAfter - beneficiaryBefore != amount
        ) revert InexactTransfer();
        _requirePrincipalAndRewards();
        emit Withdrawn(msg.sender, amount);
    }

    function _stake(address payer, address beneficiary, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_REWARD_SHARE_SUPPLY - totalStaked) revert RewardShareSupplyTooLarge();
        _checkpointRewards(beneficiary);
        uint256 sourceBefore = SafeTransferLib.balanceOf(stakingToken, payer);
        uint256 vaultBefore = SafeTransferLib.balanceOf(stakingToken, address(this));
        SafeTransferLib.safeTransferFrom(stakingToken, payer, address(this), amount);
        uint256 sourceAfter = SafeTransferLib.balanceOf(stakingToken, payer);
        uint256 vaultAfter = SafeTransferLib.balanceOf(stakingToken, address(this));
        if (
            sourceAfter > sourceBefore || sourceBefore - sourceAfter != amount
                || vaultAfter < vaultBefore || vaultAfter - vaultBefore != amount
        ) revert InexactTransfer();
        _setRewardShare(beneficiary, stakedBalance[beneficiary] + amount);
        totalStaked += amount;
        stakedBalance[beneficiary] += amount;
        _startQueuedRewards();
        _requirePrincipalAndRewards();
        emit Staked(payer, beneficiary, amount);
    }

    function _requirePrincipalAndRewards() private view {
        uint256 balance = SafeTransferLib.balanceOf(stakingToken, address(this));
        if (balance < totalStaked) revert RewardBalanceDeficit();
        if (supportsRewardAsset[stakingToken]) {
            if (balance - totalStaked < rewardData[stakingToken].accountedBalance) {
                revert RewardBalanceDeficit();
            }
        }
    }

    function _rewardShareSupply() internal view override returns (uint256) {
        return totalStaked;
    }

    function _rewardShareOf(address account) internal view override returns (uint256) {
        return stakedBalance[account];
    }

    function _availableRewardBalance(address asset) internal view override returns (uint256 balance) {
        balance = SafeTransferLib.balanceOf(asset, address(this));
        if (asset == stakingToken) {
            if (balance < totalStaked) revert RewardBalanceDeficit();
            balance -= totalStaked;
        }
    }
}
