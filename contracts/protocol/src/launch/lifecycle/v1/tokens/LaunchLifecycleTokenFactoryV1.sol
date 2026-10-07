// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILaunchFeeHubV2 } from "../../../fees/v2/ILaunchFeeHubV2.sol";
import { ILaunchTokenFactoryV1 } from "../ILaunchLifecycleV1.sol";
import { TokenKindV1, RewardModeV1, TokenConfigV1 } from "../LaunchTypesV1.sol";
import { LaunchTokenContextV1 } from "./LaunchTokenContextV1.sol";
import {
    LaunchERC20DeployerV1, LaunchERC404DeployerV1, LaunchStakingDeployerV1
} from "./LaunchTokenDeployerV1.sol";

interface ILifecycleTokenBalanceV1 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Immutable token implementations, deterministic identities and per-launch rewards.
/// @dev Helpers bind a predicted factory/core at construction. No token registration, mutable
///      implementation binding, deployment nonce, prevrandao or CREATE3 proxy is involved.
contract LaunchLifecycleTokenFactoryV1 is ILaunchTokenFactoryV1 {
    error Unauthorized();
    error InvalidBinding();
    error AlreadyDeployed();
    error AlreadyConfigured();
    error InvalidRewardMode();

    address public immutable override core;
    LaunchERC20DeployerV1 public immutable erc20Deployer;
    LaunchERC404DeployerV1 public immutable erc404Deployer;
    LaunchStakingDeployerV1 public immutable stakingDeployer;
    mapping(bytes32 launchId => address token) public tokenOfLaunch;
    mapping(address token => bytes32 launchId) public launchOfToken;
    mapping(address token => bool configured) public rewardsCreated;

    event TokenDeployed(bytes32 indexed launchId, address indexed token, TokenKindV1 kind);
    event RewardsCreated(address indexed token, address indexed hub, address indexed rewards);

    constructor(address core_, address erc20Deployer_, address erc404Deployer_, address stakingDeployer_) {
        if (core_ == address(0) || erc20Deployer_.code.length == 0
            || erc404Deployer_.code.length == 0 || stakingDeployer_.code.length == 0) {
            revert InvalidBinding();
        }
        erc20Deployer = LaunchERC20DeployerV1(erc20Deployer_);
        erc404Deployer = LaunchERC404DeployerV1(erc404Deployer_);
        stakingDeployer = LaunchStakingDeployerV1(stakingDeployer_);
        if (erc20Deployer.factory() != address(this) || erc404Deployer.factory() != address(this)
            || stakingDeployer.factory() != address(this) || erc20Deployer.core() != core_
            || erc404Deployer.core() != core_ || stakingDeployer.core() != core_
            || erc20Deployer.tokenKind() != TokenKindV1.ERC20
            || erc404Deployer.tokenKind() != TokenKindV1.ERC404) revert InvalidBinding();
        core = core_;
    }

    function predictToken(bytes32 launchId, TokenConfigV1 calldata config)
        external view override returns (address)
    {
        if (config.kind == TokenKindV1.ERC20) return erc20Deployer.predictToken(launchId, config);
        return erc404Deployer.predictToken(launchId, config);
    }

    function deployToken(bytes32 launchId, TokenConfigV1 calldata config)
        external override returns (address token)
    {
        _requireCore();
        if (launchId == bytes32(0)) revert InvalidBinding();
        if (tokenOfLaunch[launchId] != address(0)) revert AlreadyDeployed();
        if (config.kind == TokenKindV1.ERC20) token = erc20Deployer.deployToken(launchId, config);
        else token = erc404Deployer.deployToken(launchId, config);
        if (token.code.length == 0 || ILifecycleTokenBalanceV1(token).totalSupply() != config.supply
            || ILifecycleTokenBalanceV1(token).balanceOf(core) != config.supply) revert InvalidBinding();
        tokenOfLaunch[launchId] = token;
        launchOfToken[token] = launchId;
        emit TokenDeployed(launchId, token, config.kind);
    }

    function createRewards(address token, address hub, address[] calldata rewardAssets_)
        external override returns (address rewards)
    {
        _requireCore();
        bytes32 launchId = launchOfToken[token];
        if (launchId == bytes32(0) || hub.code.length == 0) revert InvalidBinding();
        if (rewardsCreated[token]) revert AlreadyConfigured();
        if (ILaunchFeeHubV2(hub).launchToken() != token || ILaunchFeeHubV2(hub).configurator() != core) {
            revert InvalidBinding();
        }
        RewardModeV1 mode = LaunchTokenContextV1(token).rewardMode();
        if (mode == RewardModeV1.Staking) {
            rewards = stakingDeployer.deployStaking(launchId, token, hub, rewardAssets_);
        } else if (mode == RewardModeV1.Dividends) {
            rewards = token;
        } else if (rewardAssets_.length != 0) {
            revert InvalidRewardMode();
        }
        rewardsCreated[token] = true;
        LaunchTokenContextV1(token).configureRewards(hub, rewards, rewardAssets_);
        emit RewardsCreated(token, hub, rewards);
    }

    function _requireCore() private view {
        if (msg.sender != core) revert Unauthorized();
    }
}
