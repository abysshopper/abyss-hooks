// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ILaunchFeeRewardsV2 } from "../../../fees/v2/ILaunchFeeHubV2.sol";

/// @notice Immutable, bounded ERC20 reward streams. Funding precedes notification.
/// @dev Each asset is released over seven days, including sub-second-rate amounts. A top-up
///      preserves an existing stream's finish. Empty-supply emissions are queued, not awarded
///      retroactively. Global fractions accumulate only while ownership is unchanged; a share
///      mutation closes the sub-unit residue to the oldest old holder. Account fractions stay
///      with their owner, including after exit. The same residue is claimable by that holder.
abstract contract MultiAssetStreamV1 is ILaunchFeeRewardsV2, ReentrancyGuard {
    error Unauthorized();
    error AlreadyConfigured();
    error InvalidRewardAssets();
    error InvalidDistributor();
    error UnsupportedRewardAsset();
    error InvalidClaimRange();
    error ZeroAddress();
    error ZeroAmount();
    error NothingToClaim();
    error RewardBalanceDeficit();
    error InexactTransfer();
    error RewardShareSupplyTooLarge();

    event RewardsConfigured(address indexed distributor, address[] assets);
    event RewardNotified(address indexed asset, uint256 amount, uint256 periodFinish);
    event RewardQueued(address indexed asset, uint256 amount);
    event RewardPaid(address indexed beneficiary, address indexed asset, uint256 amount);
    event RewardClaimBountyPaid(
        address indexed executor, address indexed beneficiary, address indexed asset, uint256 amount
    );

    uint256 public constant MAX_REWARD_ASSETS = 8;
    uint256 public constant REWARDS_DURATION = 7 days;
    // The largest decimal magnitude fitting uint256 preserves the original decimal precision.
    // With supply <= MAGNITUDE, unresolved global residue is strictly below one raw asset unit.
    // Whole and fractional index limbs allow the complete uint256 reward-funding domain.
    uint256 public constant MAX_REWARD_SHARE_SUPPLY = 1e77;
    uint256 internal constant MAGNITUDE = MAX_REWARD_SHARE_SUPPLY;

    struct RewardData {
        uint256 streamStart;
        uint256 periodFinish;
        uint256 scheduled;
        uint256 released;
        uint256 queued;
        uint256 wholePerShare;
        uint256 magnifiedPerShare;
        uint256 magnifiedRemainder;
        uint256 accountedBalance;
        uint256 totalFunded;
        uint256 totalPaid;
    }

    address private _distributor;
    address[] internal _rewardAssets;
    mapping(address asset => bool supported) public supportsRewardAsset;
    mapping(address asset => RewardData data) public rewardData;
    mapping(address asset => mapping(address account => uint256 paid)) public accountMagnifiedPaid;
    mapping(address asset => mapping(address account => uint256 paid)) public accountWholePaid;
    mapping(address asset => mapping(address account => uint256 remainder)) public accountRemainder;
    mapping(address asset => mapping(address account => uint256 amount)) public accruedRewards;
    mapping(address asset => mapping(address account => uint256 amount)) public lifetimeRewardsPaid;

    address private _firstRewardHolder;
    address private _lastRewardHolder;
    mapping(address account => address next) private _nextRewardHolder;
    mapping(address account => address previous) private _previousRewardHolder;

    function rewardAssets() external view override returns (address[] memory) {
        return _rewardAssets;
    }

    function distributor() external view override returns (address) {
        return _distributor;
    }


    function rewardAvailableBalance(address asset) public view override returns (uint256) {
        _requireAsset(asset);
        return _availableRewardBalance(asset);
    }


    /// @notice Amounts follow the immutable ascending-address asset order; zero entries are valid.
    function notifyRewardAmounts(uint256[] calldata amounts) external override nonReentrant {
        _requireDistributor();
        uint256 length = _rewardAssets.length;
        if (amounts.length != length) revert InvalidRewardAssets();
        // Validate the complete pre-funded vector before changing any schedule.
        for (uint256 i; i < length; ++i) {
            address asset = _rewardAssets[i];
            if (_availableRewardBalance(asset) < rewardData[asset].accountedBalance + amounts[i]) {
                revert RewardBalanceDeficit();
            }
        }
        for (uint256 i; i < length; ++i) {
            if (amounts[i] != 0) _notify(_rewardAssets[i], amounts[i]);
        }
    }

    function earned(address account, address asset) public view returns (uint256 amount) {
        _requireAsset(asset);
        (uint256 whole, uint256 fraction, uint256 residue) = _previewAccumulator(asset);
        (whole, fraction) = _indexDelta(
            whole, fraction, accountWholePaid[asset][account], accountMagnifiedPaid[asset][account]
        );
        (uint256 increment, uint256 remainder) = _accountReward(
            _rewardShareOf(account), whole, fraction, accountRemainder[asset][account]
        );
        amount = accruedRewards[asset][account] + increment;
        if (account == _firstRewardHolder) {
            (uint256 bonus,) = _addFraction(remainder, residue);
            amount += bonus;
        }
    }

    function pendingRewards(address account) external view returns (uint256[] memory amounts) {
        uint256 length = _rewardAssets.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) amounts[i] = earned(account, _rewardAssets[i]);
    }

    /// @notice Checkpoints one account across the complete bounded asset set.
    function checkpoint(address account) external nonReentrant {
        if (account == address(0)) revert ZeroAddress();
        _checkpointRewards(account);
    }

    function claim() external nonReentrant returns (uint256[] memory amounts) {
        return _claimRewards(msg.sender, 0, _rewardAssets.length);
    }

    function claimFor(address beneficiary) external nonReentrant returns (uint256[] memory amounts) {
        if (beneficiary == address(0)) revert ZeroAddress();
        return _claimRewards(beneficiary, 0, _rewardAssets.length);
    }

    /// @notice Claims a bounded contiguous page, applying any configured dividend payout bounty.
    function claimRange(address beneficiary, uint256 start, uint256 count)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (beneficiary == address(0)) revert ZeroAddress();
        return _claimRewards(beneficiary, start, count);
    }

    function _initializeRewards(address[] memory assets, address distributor_) internal {
        if (_distributor != address(0)) revert AlreadyConfigured();
        if (distributor_ == address(0) || distributor_.code.length == 0) revert InvalidDistributor();
        uint256 length = assets.length;
        if (length == 0 || length > MAX_REWARD_ASSETS) revert InvalidRewardAssets();
        address previous;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            if (asset <= previous || asset.code.length == 0) revert InvalidRewardAssets();
            supportsRewardAsset[asset] = true;
            _rewardAssets.push(asset);
            previous = asset;
        }
        _distributor = distributor_;
        emit RewardsConfigured(distributor_, assets);
    }

    function _notify(address asset, uint256 amount) private {
        RewardData storage data = rewardData[asset];
        uint256 supply = _rewardShareSupply();
        _updateReward(asset, supply);
        uint256 accountedAfter = data.accountedBalance + amount;
        if (_availableRewardBalance(asset) < accountedAfter) revert RewardBalanceDeficit();
        data.accountedBalance = accountedAfter;
        data.totalFunded += amount;
        _schedule(asset, amount, supply);
        emit RewardNotified(asset, amount, data.periodFinish);
    }

    function _checkpointRewards(address account) internal {
        uint256 supply = _rewardShareSupply();
        uint256 shares = _rewardShareOf(account);
        for (uint256 i; i < _rewardAssets.length; ++i) {
            address asset = _rewardAssets[i];
            _updateReward(asset, supply);
            RewardData storage data = rewardData[asset];
            (uint256 whole, uint256 fraction) = _indexDelta(
                data.wholePerShare, data.magnifiedPerShare,
                accountWholePaid[asset][account], accountMagnifiedPaid[asset][account]
            );
            if (whole != 0 || fraction != 0) {
                (uint256 increment, uint256 remainder) = _accountReward(
                    shares, whole, fraction, accountRemainder[asset][account]
                );
                accruedRewards[asset][account] += increment;
                accountRemainder[asset][account] = remainder;
                accountWholePaid[asset][account] = data.wholePerShare;
                accountMagnifiedPaid[asset][account] = data.magnifiedPerShare;
            }
        }
    }

    /// @dev All affected old balances must be checkpointed before changing membership/shares.
    ///      O(1) membership chooses a pre-transition owner for strictly sub-unit global dust.
    function _setRewardShare(address account, uint256 sharesAfter) internal {
        uint256 sharesBefore = _rewardShareOf(account);
        if (sharesBefore == sharesAfter) return;
        _closeRewardEpoch();
        if (sharesBefore == 0 && sharesAfter != 0) {
            address last = _lastRewardHolder;
            if (last == address(0)) _firstRewardHolder = account;
            else _nextRewardHolder[last] = account;
            _previousRewardHolder[account] = last;
            _lastRewardHolder = account;
        } else if (sharesBefore != 0 && sharesAfter == 0) {
            address previous = _previousRewardHolder[account];
            address next = _nextRewardHolder[account];
            if (previous == address(0)) _firstRewardHolder = next;
            else _nextRewardHolder[previous] = next;
            if (next == address(0)) _lastRewardHolder = previous;
            else _previousRewardHolder[next] = previous;
            delete _previousRewardHolder[account];
            delete _nextRewardHolder[account];
        }
    }

    function _closeRewardEpoch() private {
        address beneficiary = _firstRewardHolder;
        if (beneficiary == address(0)) return;
        _checkpointRewards(beneficiary);
        for (uint256 i; i < _rewardAssets.length; ++i) {
            address asset = _rewardAssets[i];
            RewardData storage data = rewardData[asset];
            uint256 residue = data.magnifiedRemainder;
            if (residue == 0) continue;
            data.magnifiedRemainder = 0;
            (uint256 bonus, uint256 remainder) = _addFraction(
                accountRemainder[asset][beneficiary], residue
            );
            accruedRewards[asset][beneficiary] += bonus;
            accountRemainder[asset][beneficiary] = remainder;
        }
    }

    /// @dev Call after the first eligible balance is credited, with all balances checkpointed.
    function _startQueuedRewards() internal {
        uint256 supply = _rewardShareSupply();
        if (supply == 0) return;
        for (uint256 i; i < _rewardAssets.length; ++i) {
            address asset = _rewardAssets[i];
            _updateReward(asset, supply);
            if (rewardData[asset].queued != 0) _schedule(asset, 0, supply);
        }
    }

    function _claimRewards(address beneficiary, uint256 start, uint256 count)
        internal
        returns (uint256[] memory amounts)
    {
        uint256 length = _rewardAssets.length;
        if (count == 0 || start >= length || count > length - start) revert InvalidClaimRange();
        if (beneficiary == _firstRewardHolder) _closeRewardEpoch();
        _checkpointRewards(beneficiary);
        amounts = new uint256[](count);
        bool paidAny;
        uint16 feeBps = _rewardClaimFeeBps();
        for (uint256 i; i < count; ++i) {
            address asset = _rewardAssets[start + i];
            uint256 amount = accruedRewards[asset][beneficiary];
            uint256 bounty = msg.sender == beneficiary
                ? 0
                : FixedPointMathLib.fullMulDiv(amount, feeBps, 10_000);
            uint256 payout = amount - bounty;
            amounts[i] = payout;
            if (amount == 0) continue;
            paidAny = true;
            RewardData storage data = rewardData[asset];
            accruedRewards[asset][beneficiary] = 0;
            data.accountedBalance -= amount;
            data.totalPaid += amount;
            lifetimeRewardsPaid[asset][beneficiary] += payout;
            _transferRewardExact(asset, beneficiary, payout);
            emit RewardPaid(beneficiary, asset, payout);
            if (bounty != 0) {
                _transferRewardExact(asset, msg.sender, bounty);
                emit RewardClaimBountyPaid(msg.sender, beneficiary, asset, bounty);
            }
        }
        if (!paidAny) revert NothingToClaim();
    }

    function _updateReward(address asset, uint256 supply) private {
        RewardData storage data = rewardData[asset];
        uint256 cumulative = _releasedAt(data);
        uint256 emitted = cumulative - data.released;
        if (emitted != 0) {
            data.released = cumulative;
            if (supply == 0) {
                data.queued += emitted;
            } else {
                (uint256 whole, uint256 fraction, uint256 residue) = _scaledReward(
                    emitted, supply, data.magnifiedRemainder
                );
                (uint256 rollover, uint256 accumulator) = _addFraction(data.magnifiedPerShare, fraction);
                data.wholePerShare += whole + rollover;
                data.magnifiedPerShare = accumulator;
                data.magnifiedRemainder = residue;
            }
        }
    }

    function _schedule(address asset, uint256 added, uint256 supply) private {
        RewardData storage data = rewardData[asset];
        uint256 total = added + data.queued + (data.scheduled - data.released);
        uint256 finish = data.periodFinish;
        data.queued = 0;
        data.scheduled = 0;
        data.released = 0;
        data.streamStart = block.timestamp;
        data.periodFinish = 0;
        if (supply == 0) {
            data.queued = total;
            emit RewardQueued(asset, total);
            return;
        }
        data.scheduled = total;
        data.periodFinish = finish > block.timestamp ? finish : block.timestamp + REWARDS_DURATION;
    }

    function _releasedAt(RewardData storage data) private view returns (uint256) {
        if (data.periodFinish == 0) return 0;
        if (block.timestamp >= data.periodFinish) return data.scheduled;
        return FixedPointMathLib.fullMulDiv(
            data.scheduled, block.timestamp - data.streamStart,
            data.periodFinish - data.streamStart
        );
    }

    function _previewAccumulator(address asset)
        private
        view
        returns (uint256 whole, uint256 fraction, uint256 residue)
    {
        RewardData storage data = rewardData[asset];
        whole = data.wholePerShare;
        fraction = data.magnifiedPerShare;
        residue = data.magnifiedRemainder;
        uint256 supply = _rewardShareSupply();
        uint256 emitted = _releasedAt(data) - data.released;
        if (supply != 0 && emitted != 0) {
            (uint256 increment, uint256 scaled, uint256 remainder) = _scaledReward(emitted, supply, residue);
            (uint256 rollover, uint256 accumulator) = _addFraction(fraction, scaled);
            whole += increment + rollover;
            fraction = accumulator;
            residue = remainder;
        }
    }

    function _scaledReward(uint256 amount, uint256 denominator, uint256 carry)
        private
        pure
        returns (uint256 whole, uint256 fraction, uint256 residue)
    {
        whole = amount / denominator;
        uint256 fractionalAmount = amount % denominator;
        fraction = FixedPointMathLib.fullMulDiv(fractionalAmount, MAGNITUDE, denominator);
        residue = mulmod(fractionalAmount, MAGNITUDE, denominator);
        if (carry >= denominator - residue) {
            ++fraction;
            residue = carry - (denominator - residue);
            if (fraction == MAGNITUDE) {
                ++whole;
                fraction = 0;
            }
        } else {
            residue += carry;
        }
    }

    function _indexDelta(uint256 whole, uint256 fraction, uint256 paidWhole, uint256 paidFraction)
        private
        pure
        returns (uint256 deltaWhole, uint256 deltaFraction)
    {
        deltaWhole = whole - paidWhole;
        if (fraction < paidFraction) {
            --deltaWhole;
            deltaFraction = MAGNITUDE - (paidFraction - fraction);
        } else {
            deltaFraction = fraction - paidFraction;
        }
    }

    function _accountReward(uint256 shares, uint256 whole, uint256 fraction, uint256 carry)
        private
        pure
        returns (uint256 amount, uint256 remainder)
    {
        amount = shares * whole + FixedPointMathLib.fullMulDiv(shares, fraction, MAGNITUDE);
        (uint256 bonus, uint256 fractional) = _addFraction(mulmod(shares, fraction, MAGNITUDE), carry);
        amount += bonus;
        remainder = fractional;
    }

    function _addFraction(uint256 left, uint256 right)
        private
        pure
        returns (uint256 whole, uint256 fraction)
    {
        if (right >= MAGNITUDE - left) {
            whole = 1;
            fraction = right - (MAGNITUDE - left);
        } else {
            fraction = left + right;
        }
    }

    function _transferRewardExact(address asset, address beneficiary, uint256 amount) private {
        uint256 sourceBefore = SafeTransferLib.balanceOf(asset, address(this));
        uint256 beneficiaryBefore = SafeTransferLib.balanceOf(asset, beneficiary);
        SafeTransferLib.safeTransfer(asset, beneficiary, amount);
        uint256 sourceAfter = SafeTransferLib.balanceOf(asset, address(this));
        uint256 beneficiaryAfter = SafeTransferLib.balanceOf(asset, beneficiary);
        if (
            sourceAfter > sourceBefore || sourceBefore - sourceAfter != amount
                || beneficiaryAfter < beneficiaryBefore || beneficiaryAfter - beneficiaryBefore != amount
        ) revert InexactTransfer();
        if (_availableRewardBalance(asset) < rewardData[asset].accountedBalance) {
            revert RewardBalanceDeficit();
        }
    }

    function _requireAsset(address asset) internal view {
        if (!supportsRewardAsset[asset]) revert UnsupportedRewardAsset();
    }

    function _requireDistributor() private view {
        if (msg.sender != _distributor || _distributor == address(0)) revert Unauthorized();
    }

    /// @dev Staking has no payout bounty; dividend tokens override this independently.
    function _rewardClaimFeeBps() internal view virtual returns (uint16) {
        return 0;
    }

    function _rewardShareSupply() internal view virtual returns (uint256);
    function _rewardShareOf(address account) internal view virtual returns (uint256);
    function _availableRewardBalance(address asset) internal view virtual returns (uint256);
}
