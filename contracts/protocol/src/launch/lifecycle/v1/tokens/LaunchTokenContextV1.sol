// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ILaunchLifecycleV1, ILaunchLifecycleTokenV1 } from "../ILaunchLifecycleV1.sol";
import { RewardModeV1, TokenConfigV1 } from "../LaunchTypesV1.sol";
import { MultiAssetStreamV1 } from "../modules/MultiAssetStreamV1.sol";
import { ILaunchFeeHubV2 } from "../../../fees/v2/ILaunchFeeHubV2.sol";
import { LaunchTokenParametersV1 } from "./LaunchTokenParametersV1.sol";

/// @notice Deferred, core-owned launch context shared by both token standards.
/// @dev No eligible transfer precedes the complete immutable exclusion set. Activation and
///      cancellation are terminal local states: the core cannot pause an active token later.
abstract contract LaunchTokenContextV1 is MultiAssetStreamV1, ILaunchLifecycleTokenV1 {
    error InvalidTokenConfiguration();
    error TransferInactive();
    error TokenCancelled();
    error AlreadyTerminal();
    error ExclusionsNotFinalized();
    error ExclusionsAlreadyFinalized();
    error InvalidExclusions();
    error InvalidRewardMode();
    error CancelPolicyMismatch();
    error InvalidDividendBounty();

    event DividendBountyUpdated(
        address indexed feeOwner, uint16 previousBountyBps, uint16 newBountyBps
    );

    event ExclusionsFinalized(address[] exclusions);
    event TokenActivated();
    event TokenPermanentlyCancelled(uint256 inventoryBurned);

    uint256 public constant MAX_EXCLUSIONS = 512;
    uint16 public constant MAX_DIVIDEND_BOUNTY_BPS = 1_000;
    uint16 public dividendBountyBps;
    address public immutable authority;
    address public immutable tokenFactory;
    address public immutable deploymentSource;
    bytes32 public immutable launchId;
    RewardModeV1 public immutable rewardMode;
    bool public immutable burnOnCancel;
    uint256 public immutable initialSupply;
    bool public active;
    bool public cancelled;
    bool public exclusionsFinalized;
    address public feeHub;
    address public rewardModule;
    uint256 public eligibleSupply;
    mapping(address account => bool excluded) public isExcluded;

    uint256 private _cancellationBurn;

    constructor(address authority_, address factory_, bytes32 launchId_, TokenConfigV1 memory config) {
        if (authority_ == address(0) || factory_ == address(0) || launchId_ == bytes32(0)) {
            revert InvalidTokenConfiguration();
        }
        LaunchTokenParametersV1.validate(config);
        authority = authority_;
        tokenFactory = factory_;
        deploymentSource = msg.sender;
        launchId = launchId_;
        rewardMode = config.rewardMode;
        burnOnCancel = config.burnOnCancel;
        initialSupply = config.supply;
    }

    /// @dev Called exactly once by the factory after hub creation. Dividend accounting is
    ///      embedded, so every fungible and NFT mutation shares the same internal checkpoints.
    function configureRewards(address hub, address module, address[] calldata assets) external {
        if (msg.sender != tokenFactory) revert Unauthorized();
        if (feeHub != address(0) || exclusionsFinalized || active || cancelled) revert AlreadyConfigured();
        if (hub == address(0) || hub.code.length == 0) revert InvalidDistributor();
        feeHub = hub;
        rewardModule = module;
        if (rewardMode == RewardModeV1.Dividends) {
            if (module != address(this)) revert InvalidRewardMode();
            _initializeRewards(assets, hub);
        } else if (rewardMode == RewardModeV1.Staking) {
            if (module == address(0) || module == address(this) || module.code.length == 0) {
                revert InvalidRewardMode();
            }
        } else {
            if (module != address(0) || assets.length != 0) revert InvalidRewardMode();
        }
    }

    function setDividendBountyBps(uint16 newBountyBps) external nonReentrant {
        if (rewardMode != RewardModeV1.Dividends || feeHub == address(0)) {
            revert InvalidRewardMode();
        }
        if (msg.sender != ILaunchFeeHubV2(feeHub).feeOwnerRegistry().feeOwner(address(this))) {
            revert Unauthorized();
        }
        if (newBountyBps > MAX_DIVIDEND_BOUNTY_BPS) revert InvalidDividendBounty();
        uint16 previousBountyBps = dividendBountyBps;
        dividendBountyBps = newBountyBps;
        emit DividendBountyUpdated(msg.sender, previousBountyBps, newBountyBps);
    }

    function finalizeExclusions(address[] calldata exclusions) external override {
        _requireAuthority();
        if (active || cancelled) revert AlreadyTerminal();
        if (exclusionsFinalized) revert ExclusionsAlreadyFinalized();
        if (exclusions.length > MAX_EXCLUSIONS) revert InvalidExclusions();
        if (rewardMode != RewardModeV1.None && feeHub == address(0)) revert InvalidRewardMode();
        uint256 excludedSupply = _exclude(address(this));
        excludedSupply += _exclude(authority);
        excludedSupply += _exclude(tokenFactory);
        excludedSupply += _exclude(deploymentSource);
        excludedSupply += _exclude(feeHub);
        excludedSupply += _exclude(rewardModule);
        for (uint256 i; i < exclusions.length; ++i) excludedSupply += _exclude(exclusions[i]);
        eligibleSupply = _tokenSupply() - excludedSupply;
        exclusionsFinalized = true;
        emit ExclusionsFinalized(exclusions);
    }

    function activate() external override {
        _requireAuthority();
        if (active || cancelled) revert AlreadyTerminal();
        if (!exclusionsFinalized) revert ExclusionsNotFinalized();
        active = true;
        emit TokenActivated();
    }

    function cancel(bool burnInventory) external override {
        _requireAuthority();
        if (active || cancelled) revert AlreadyTerminal();
        if (burnInventory != burnOnCancel) revert CancelPolicyMismatch();
        cancelled = true;
        uint256 inventory;
        if (burnInventory) {
            inventory = _tokenBalance(authority);
            if (inventory != 0) {
                _cancellationBurn = inventory;
                _burnInventory(inventory);
                _cancellationBurn = 0;
            }
        }
        emit TokenPermanentlyCancelled(inventory);
    }

    function totalBurned() external view returns (uint256) {
        return initialSupply - _tokenSupply();
    }

    function eligibleBalanceOf(address account) external view returns (uint256) {
        return _rewardShareOf(account);
    }

    function _beforeLifecycleTransfer(
        address caller, address from, address to, uint256 amount, bool nft
    ) internal {
        // Fixed supply is created only during construction, never through a public mint path.
        if (from == address(0) && address(this).code.length == 0) return;
        if (_cancellationBurn != 0 && caller == authority && from == authority
            && to == address(0) && amount == _cancellationBurn && !nft) {
            return;
        }
        if (cancelled) revert TokenCancelled();
        if (!exclusionsFinalized) revert ExclusionsNotFinalized();
        if (!active) {
            // Committed launch operations use fungible transfers. Direct NFT transfers are
            // never a preparation/activation operation, even with an approved NFT operator.
            if (nft || !ILaunchLifecycleV1(authority).authorizeTokenTransfer(
                address(this), caller, from, to, amount, false
            )) revert TransferInactive();
        }
        if (rewardMode != RewardModeV1.Dividends) return;
        if (from != address(0)) _checkpointRewards(from);
        if (to != address(0) && from != to) _checkpointRewards(to);
        if (from == to) return;
        bool fromEligible = from != address(0) && !isExcluded[from];
        bool toEligible = to != address(0) && !isExcluded[to];
        if (fromEligible) _setRewardShare(from, _tokenBalance(from) - amount);
        if (toEligible) _setRewardShare(to, _tokenBalance(to) + amount);
        uint256 supplyBefore = eligibleSupply;
        if (fromEligible && !toEligible) eligibleSupply -= amount;
        if (!fromEligible && toEligible) eligibleSupply += amount;
        if (supplyBefore == 0 && eligibleSupply != 0) _startQueuedRewards();
    }

    function _exclude(address account) private returns (uint256 excludedBalance) {
        if (account == address(0) || isExcluded[account]) return 0;
        isExcluded[account] = true;
        return _tokenBalance(account);
    }

    function _requireAuthority() private view {
        if (msg.sender != authority) revert Unauthorized();
    }

    function _rewardShareSupply() internal view override returns (uint256) {
        return rewardMode == RewardModeV1.Dividends && exclusionsFinalized ? eligibleSupply : 0;
    }

    function _rewardShareOf(address account) internal view override returns (uint256) {
        if (rewardMode != RewardModeV1.Dividends || !exclusionsFinalized || isExcluded[account]) return 0;
        return _tokenBalance(account);
    }

    function _rewardClaimFeeBps() internal view override returns (uint16) {
        return rewardMode == RewardModeV1.Dividends ? dividendBountyBps : 0;
    }

    function _availableRewardBalance(address asset) internal view override returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this));
    }

    function _tokenBalance(address account) internal view virtual returns (uint256);
    function _tokenSupply() internal view virtual returns (uint256);
    function _burnInventory(uint256 amount) internal virtual;
}
