// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

import { ILaunchFeeOwnerRegistry } from "../../../interfaces/ILaunchRewards.sol";
import { ILaunchFeeSourceV1 } from "../v1/ILaunchFeeHubV1.sol";
import {
    ExecutorPaymentV2,
    FeeAssetPolicyV2,
    ILaunchFeeRewardsV2
} from "../v2/ILaunchFeeHubV2.sol";
import { ILaunchRegistryV2 } from "../../lifecycle/v2/ILaunchRegistryV2.sol";
import { ILaunchFeeHubV3, SourceTermsV3 } from "./ILaunchFeeHubV3.sol";

interface ILaunchFeeTokenV3 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function burn(uint256 amount) external;
}

/// @notice Opt-in source-aware routing with independently reserved owner and developer credits.
/// @dev Developer terms freeze the rate and stable author identity only at binding. Harvest
///      never calls the author; withdrawals use live registry routing, not admission eligibility.
contract LaunchFeeHubV3 is ILaunchFeeHubV3, ReentrancyGuard {
    error InvalidBinding();
    error InvalidPolicy();
    error InvalidExecutorFee();
    error InvalidSourceTerms();
    error InvalidAssetCount();
    error InvalidSourceCount();
    error UnsupportedAsset();
    error IncompatibleRewards();
    error InexactCollection();
    error InexactTransfer();
    error InexactBurn();
    error TransferFailed();
    error Unauthorized();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidRecipient();
    error NothingToClaim();
    error AuthorPayoutChanged();
    error NativeCurrencyUnsupported();

    event SourceTermsBound(
        address indexed source,
        bytes32 indexed profileId,
        address indexed beneficiary,
        address adapter,
        bytes32 termsDigest,
        uint16 maximumDeveloperFeeBps,
        uint16 developerFeeBps
    );
    event SourcesConfigured(address[] sources, address indexed rewards);
    event Distributed(
        address indexed asset,
        address indexed owner,
        address indexed executor,
        uint256 newlyCollected,
        uint256 executorAmount,
        uint256 ownerAmount,
        uint256 developerAmount,
        uint256 rewardsAmount,
        uint256 burnAmount
    );
    event OwnerFeesCredited(address indexed owner, address indexed asset, uint256 amount);
    event OwnerFeesClaimed(
        address indexed owner, address indexed asset, address indexed recipient, uint256 amount
    );
    event DeveloperFeesCredited(
        address indexed authorId, address indexed source, address indexed asset, uint256 amount
    );
    event DeveloperFeesClaimed(
        address indexed authorId, address indexed asset, address indexed payout, uint256 amount
    );

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant override MAX_EXECUTOR_FEE_BPS = 1_000;
    uint256 public constant MAX_ASSETS = 8;
    uint256 public constant MAX_SOURCES = 16;
    uint16 public constant override economicVersion = 3;

    uint8 private constant ASSET_RECIPIENT_EXCLUSION = 1;
    uint8 private constant SYSTEM_RECIPIENT_EXCLUSION = 2;

    address public immutable override launchToken;
    ILaunchFeeOwnerRegistry public immutable override feeOwnerRegistry;
    address public immutable override configurator;
    ILaunchRegistryV2 public immutable override implementationRegistry;
    uint16 public immutable override protocolMaximumDeveloperFeeBps;
    uint16 public override executorFeeBps;
    bool public immutable override requiresOwner;
    bool public immutable override requiresRewards;
    bool public override finalized;
    bool private _hasDeveloperFees;
    address public override rewards;
    bytes32 public override rewardAssetsHash;

    mapping(address owner => mapping(address asset => uint256 amount))
        public
        override claimableOwnerFees;
    mapping(address asset => uint256 amount) public override reservedOwnerFees;
    mapping(address authorId => mapping(address asset => uint256 amount))
        public
        override claimableDeveloperFees;
    mapping(address asset => uint256 amount) public override reservedDeveloperFees;
    mapping(address source => bytes32 id) public override sourceId;
    mapping(bytes32 id => address source) public override sourceById;

    address[] private _assets;
    address[] private _sources;
    address[] private _termSources;
    address[] private _rewardAssets;
    mapping(address asset => uint48 packedPolicy) private _policies;
    mapping(address asset => uint256 indexPlusOne) private _assetIndex;
    mapping(address asset => uint256 indexPlusOne) private _rewardAssetIndex;
    mapping(address source => address[] assets_) private _sourceAssets;
    mapping(address source => uint256 mask) private _sourceAssetMask;
    mapping(address source => SourceTermsV3 terms) private _sourceTerms;
    mapping(address recipient => uint8 exclusions) private _excludedRecipients;

    struct SplitAmounts {
        uint256 owner;
        uint256 rewards;
        uint256 burn;
    }

    struct HarvestAsset {
        uint256 collected;
        uint256 inventory;
        uint256 executor;
        uint256 owner;
        uint256 developer;
        uint256 rewards;
        uint256 burn;
    }

    struct RewardSnapshot {
        uint256[] amounts;
        uint256[] balances;
        uint256[] available;
    }

    constructor(
        address launchToken_,
        ILaunchFeeOwnerRegistry feeOwnerRegistry_,
        FeeAssetPolicyV2[] memory policies_,
        uint16 executorFeeBps_,
        address configurator_,
        ILaunchRegistryV2 implementationRegistry_
    ) {
        if (
            launchToken_ == address(0) || launchToken_.code.length == 0
                || address(feeOwnerRegistry_).code.length == 0 || configurator_ == address(0)
                || configurator_ == address(this)
                || address(implementationRegistry_).code.length == 0
        ) revert InvalidBinding();
        uint16 maximum = implementationRegistry_.protocolMaximumDeveloperFeeBps();
        if (maximum >= BPS_DENOMINATOR) revert InvalidSourceTerms();
        uint256 count = policies_.length;
        if (count == 0 || count > MAX_ASSETS) revert InvalidAssetCount();
        if (executorFeeBps_ > MAX_EXECUTOR_FEE_BPS) revert InvalidExecutorFee();

        bool ownerRequired;
        bool rewardsRequired;
        address previous;
        for (uint256 i; i < count; ++i) {
            FeeAssetPolicyV2 memory entry = policies_[i];
            if (entry.asset == address(0)) revert NativeCurrencyUnsupported();
            if (entry.asset <= previous || entry.asset.code.length == 0) revert InvalidBinding();
            if (
                uint256(entry.ownerBps) + entry.rewardsBps + entry.burnBps != BPS_DENOMINATOR
                    || (entry.burnBps != 0 && entry.asset != launchToken_)
            ) revert InvalidPolicy();
            ILaunchFeeTokenV3(entry.asset).balanceOf(address(this));
            _assets.push(entry.asset);
            _assetIndex[entry.asset] = i + 1;
            _policies[entry.asset] = uint48(entry.ownerBps) | (uint48(entry.rewardsBps) << 16)
                | (uint48(entry.burnBps) << 32);
            _excludedRecipients[entry.asset] = ASSET_RECIPIENT_EXCLUSION;
            ownerRequired = ownerRequired || entry.ownerBps != 0;
            rewardsRequired = rewardsRequired || entry.rewardsBps != 0;
            previous = entry.asset;
        }
        if (_assetIndex[launchToken_] == 0) revert InvalidBinding();

        launchToken = launchToken_;
        feeOwnerRegistry = feeOwnerRegistry_;
        configurator = configurator_;
        implementationRegistry = implementationRegistry_;
        protocolMaximumDeveloperFeeBps = maximum;
        executorFeeBps = executorFeeBps_;
        requiresOwner = ownerRequired;
        requiresRewards = rewardsRequired;
        _excludedRecipients[configurator_] |= SYSTEM_RECIPIENT_EXCLUSION;
        _excludedRecipients[msg.sender] |= SYSTEM_RECIPIENT_EXCLUSION;
        _excludedRecipients[address(feeOwnerRegistry_)] |= SYSTEM_RECIPIENT_EXCLUSION;
        _excludedRecipients[address(implementationRegistry_)] |= SYSTEM_RECIPIENT_EXCLUSION;
    }

    receive() external payable {
        revert NativeCurrencyUnsupported();
    }

    function assets() external view override returns (address[] memory) {
        return _assets;
    }

    function sources() external view override returns (address[] memory) {
        return _sources;
    }

    function rewardAssets() external view override returns (address[] memory) {
        return _rewardAssets;
    }

    function policy(address asset) external view override returns (FeeAssetPolicyV2 memory) {
        if (_assetIndex[asset] == 0) revert UnsupportedAsset();
        uint48 packed = _policies[asset];
        return FeeAssetPolicyV2(asset, uint16(packed), uint16(packed >> 16), uint16(packed >> 32));
    }

    function sourceAssets(address source) external view override returns (address[] memory) {
        return _sourceAssets[source];
    }

    function sourceTerms(address source) external view override returns (SourceTermsV3 memory) {
        return _sourceTerms[source];
    }

    function bindSourceTerms(
        address source,
        bytes32 profileId,
        bytes32 termsDigest,
        uint16 developerFeeBps
    ) external override nonReentrant {
        if (finalized) revert AlreadyConfigured();
        if (_sourceTerms[source].adapter != address(0)) revert AlreadyConfigured();
        if (_termSources.length == MAX_SOURCES) revert InvalidSourceCount();
        if (
            source == address(this) || _excludedRecipients[source] != 0 || source.code.length == 0
                || ILaunchFeeSourceV1(source).hub() != address(this)
        ) revert InvalidBinding();
        SourceTermsV3 memory terms;
        bool enabled;
        (
            terms.adapter,
            terms.beneficiary,
            terms.maximumDeveloperFeeBps,
            terms.termsDigest,
            enabled
        ) = implementationRegistry.developerTerms(profileId);
        if (msg.sender != terms.adapter || terms.adapter.code.length == 0) revert Unauthorized();
        if (
            !enabled || profileId == bytes32(0) || termsDigest == bytes32(0)
                || terms.termsDigest != termsDigest
                || terms.maximumDeveloperFeeBps > protocolMaximumDeveloperFeeBps
                || developerFeeBps > terms.maximumDeveloperFeeBps
        ) revert InvalidSourceTerms();
        _excludeSourceCustody(source);
        _excludedRecipients[source] |= SYSTEM_RECIPIENT_EXCLUSION;
        _validateRecipient(terms.beneficiary);
        terms.profileId = profileId;
        terms.developerFeeBps = developerFeeBps;
        _sourceTerms[source] = terms;
        _termSources.push(source);
        if (developerFeeBps != 0 && !_hasDeveloperFees) _hasDeveloperFees = true;
        emit SourceTermsBound(
            source,
            profileId,
            terms.beneficiary,
            terms.adapter,
            termsDigest,
            terms.maximumDeveloperFeeBps,
            developerFeeBps
        );
    }

    function configureSources(address[] calldata sources_, address rewards_)
        external
        override
        nonReentrant
    {
        if (msg.sender != configurator) revert Unauthorized();
        if (finalized) revert AlreadyConfigured();
        uint256 count = sources_.length;
        if (count == 0 || count > MAX_SOURCES) revert InvalidSourceCount();
        if (requiresRewards) {
            address[] memory supported = _validateRewards(rewards_);
            _rewardAssets = supported;
            rewardAssetsHash = keccak256(abi.encode(supported));
            for (uint256 i; i < supported.length; ++i) {
                _rewardAssetIndex[supported[i]] = i + 1;
            }
        } else if (rewards_ != address(0)) {
            revert IncompatibleRewards();
        }
        for (uint256 i; i < count; ++i) {
            _bindSource(sources_[i], rewards_);
        }
        if (rewards_ != address(0) && _isExcludedRewardRecipient(rewards_)) {
            revert IncompatibleRewards();
        }
        rewards = rewards_;
        // Validate after the entire membership/custody set is known. No prepared economic
        // binding may silently disappear from finalization or pay another source's custody.
        for (uint256 i; i < _termSources.length; ++i) {
            address source = _termSources[i];
            if (sourceId[source] == bytes32(0)) revert InvalidSourceTerms();
            SourceTermsV3 storage terms = _sourceTerms[source];
            _validateRecipient(terms.beneficiary);
            if (terms.developerFeeBps != 0 && !_hasOwnerAsset(source)) revert InvalidSourceTerms();
        }
        if (requiresOwner) _validateRecipient(feeOwnerRegistry.feeOwner(launchToken));
        finalized = true;
        for (uint256 i; i < _termSources.length; ++i) {
            SourceTermsV3 storage terms = _sourceTerms[_termSources[i]];
            if (terms.developerFeeBps != 0) {
                implementationRegistry.registerAuthorHub(terms.beneficiary);
            }
        }
        emit SourcesConfigured(sources_, rewards_);
    }

    function setExecutorFeeBps(uint16 newFeeBps) external override nonReentrant {
        if (msg.sender != feeOwnerRegistry.feeOwner(launchToken)) revert Unauthorized();
        if (newFeeBps > MAX_EXECUTOR_FEE_BPS) revert InvalidExecutorFee();
        uint16 previousFeeBps = executorFeeBps;
        executorFeeBps = newFeeBps;
        emit ExecutorFeeUpdated(msg.sender, previousFeeBps, newFeeBps);
    }

    function claimAndSplit()
        external
        override
        nonReentrant
        returns (ExecutorPaymentV2[] memory payments)
    {
        if (!finalized) revert NotConfigured();
        _validateRecipient(msg.sender);
        uint16 feeBps = executorFeeBps;
        RewardSnapshot memory rewardSnapshot = _snapshotRewards();
        uint256 count = _assets.length;
        HarvestAsset[] memory accounting = new HarvestAsset[](count);
        uint256[] memory sourceAmounts =
            new uint256[](_hasDeveloperFees ? _sources.length * count : 0);
        uint256[8] memory beforeBalances;
        for (uint256 i; i < count; ++i) {
            address asset = _assets[i];
            uint256 balance = _balanceOf(asset, address(this));
            uint256 reserved = _reserved(asset);
            if (balance < reserved) revert InexactTransfer();
            accounting[i].inventory = balance - reserved;
        }
        for (uint256 i; i < _sources.length; ++i) {
            _collectSource(_sources[i], i * count, accounting, sourceAmounts, beforeBalances);
        }

        address owner;
        if (requiresOwner) {
            owner = feeOwnerRegistry.feeOwner(launchToken);
            _validateRecipient(owner);
        }
        // Reserve every asset's two credit classes before the first executor/reward/burn call.
        payments = new ExecutorPaymentV2[](count);
        for (uint256 i; i < count; ++i) {
            _reserveAsset(i, feeBps, owner, accounting[i], sourceAmounts);
            payments[i] = ExecutorPaymentV2(_assets[i], accounting[i].executor);
        }
        bool fundedRewards;
        for (uint256 i; i < count; ++i) {
            HarvestAsset memory amounts = accounting[i];
            address asset = _assets[i];
            _payAsset(asset, owner, amounts);
            if (amounts.rewards != 0) {
                rewardSnapshot.amounts[_rewardAssetIndex[asset] - 1] = amounts.rewards;
                fundedRewards = true;
            }
        }
        if (fundedRewards) {
            ILaunchFeeRewardsV2(rewards).notifyRewardAmounts(rewardSnapshot.amounts);
        }
        _checkRewardSnapshot(rewardSnapshot);
        // Unexpected callbacks cannot turn another asset's reserves into fee inventory or
        // leave untracked donations behind after a successful harvest.
        for (uint256 i; i < count; ++i) {
            address asset = _assets[i];
            if (_balanceOf(asset, address(this)) != _reserved(asset)) revert InexactTransfer();
        }
    }

    function _payAsset(address asset, address owner, HarvestAsset memory amounts) private {
        if (amounts.executor != 0) _transferExact(asset, msg.sender, amounts.executor);
        if (amounts.rewards != 0) _transferExact(asset, rewards, amounts.rewards);
        if (amounts.burn != 0) _burnExact(asset, amounts.burn);
        emit Distributed(
            asset,
            owner,
            msg.sender,
            amounts.collected,
            amounts.executor,
            amounts.owner,
            amounts.developer,
            amounts.rewards,
            amounts.burn
        );
    }

    function claimOwnerFees(address asset, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (_assetIndex[asset] == 0) revert UnsupportedAsset();
        _validateRecipient(recipient);
        amount = claimableOwnerFees[msg.sender][asset];
        if (amount == 0) revert NothingToClaim();
        claimableOwnerFees[msg.sender][asset] = 0;
        reservedOwnerFees[asset] -= amount;
        _transferExact(asset, recipient, amount);
        if (_balanceOf(asset, address(this)) < _reserved(asset)) revert InexactTransfer();
        emit OwnerFeesClaimed(msg.sender, asset, recipient, amount);
    }

    /// @notice Permissionless withdrawal to the author's current registry-controlled payout.
    function claimDeveloperFees(address authorId, address asset)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (_assetIndex[asset] == 0) revert UnsupportedAsset();
        amount = claimableDeveloperFees[authorId][asset];
        if (amount == 0) return 0;
        address payout = implementationRegistry.authorPayout(authorId);
        _validateRecipient(payout);
        claimableDeveloperFees[authorId][asset] = 0;
        reservedDeveloperFees[asset] -= amount;
        _transferExact(asset, payout, amount);
        if (_balanceOf(asset, address(this)) < _reserved(asset)) revert InexactTransfer();
        if (implementationRegistry.authorPayout(authorId) != payout) revert AuthorPayoutChanged();
        emit DeveloperFeesClaimed(authorId, asset, payout, amount);
    }

    function _bindSource(address source, address rewards_) private {
        if (
            source == address(this) || source == rewards_ || source.code.length == 0
                || sourceId[source] != bytes32(0) || _assetIndex[source] != 0
        ) revert InvalidBinding();
        ILaunchFeeSourceV1 bound = ILaunchFeeSourceV1(source);
        if (bound.hub() != address(this)) revert InvalidBinding();
        bound.validateBinding();
        bytes32 id = bound.sourceId();
        if (id == bytes32(0) || sourceById[id] != address(0)) revert InvalidBinding();
        address[] memory sourceAssets_ = bound.assets();
        if (sourceAssets_.length == 0 || sourceAssets_.length > _assets.length) {
            revert InvalidBinding();
        }
        uint256 mask;
        address previous;
        for (uint256 i; i < sourceAssets_.length; ++i) {
            address asset = sourceAssets_[i];
            uint256 index = _assetIndex[asset];
            if (asset <= previous || index == 0) revert InvalidBinding();
            mask |= uint256(1) << (index - 1);
            previous = asset;
        }
        sourceId[source] = id;
        sourceById[id] = source;
        _sourceAssets[source] = sourceAssets_;
        _sourceAssetMask[source] = mask;
        _sources.push(source);
        _excludedRecipients[source] |= SYSTEM_RECIPIENT_EXCLUSION;
        _excludeSourceCustody(source);
    }

    /// @dev The unchanged source ABI has no custody enumeration. Canonical V4/Abyss sources
    ///      expose these immutable getters; absent getters on other zero-author sources are
    ///      not admission. These reads only exclude destinations and never grant entitlement.
    function _excludeSourceCustody(address source) private {
        _excludeCustodyGetter(source, bytes4(keccak256("locker()")));
        _excludeCustodyGetter(source, bytes4(keccak256("poolManager()")));
        _excludeCustodyGetter(source, bytes4(keccak256("hookRoot()")));
        _excludeCustodyGetter(source, bytes4(keccak256("positionManager()")));
        _excludeCustodyGetter(source, bytes4(keccak256("pool()")));
    }

    function _excludeCustodyGetter(address source, bytes4 selector) private {
        bool ok;
        uint256 raw;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gas(), source, ptr, 4, ptr, 32)
            ok := and(ok, eq(returndatasize(), 32))
            raw := mload(ptr)
        }
        if (ok && raw <= type(uint160).max && raw != 0) {
            _excludedRecipients[address(uint160(raw))] |= SYSTEM_RECIPIENT_EXCLUSION;
        }
    }

    function _hasOwnerAsset(address source) private view returns (bool) {
        address[] storage sourceAssets_ = _sourceAssets[source];
        for (uint256 i; i < sourceAssets_.length; ++i) {
            if (uint16(_policies[sourceAssets_[i]]) != 0) return true;
        }
        return false;
    }

    /// @dev The core-only factory pins the launch token; its canonical token factory initializes
    ///      that token's distributor only for embedded dividends. Only its asset exclusion may
    ///      be waived for rewards. Infrastructure/source custody and all payout exclusions remain.
    function _isExcludedRewardRecipient(address recipient) private view returns (bool) {
        uint8 exclusions = _excludedRecipients[recipient];
        return
            exclusions != 0 && (recipient != launchToken || exclusions != ASSET_RECIPIENT_EXCLUSION);
    }

    function _validateRewards(address rewards_) private view returns (address[] memory supported) {
        if (
            rewards_ == address(this) || rewards_.code.length == 0
                || _isExcludedRewardRecipient(rewards_)
        ) {
            revert IncompatibleRewards();
        }
        ILaunchFeeRewardsV2 stream = ILaunchFeeRewardsV2(rewards_);
        if (stream.distributor() != address(this)) revert IncompatibleRewards();
        supported = stream.rewardAssets();
        if (finalized) {
            if (keccak256(abi.encode(supported)) != rewardAssetsHash) revert IncompatibleRewards();
            return supported;
        }
        if (supported.length == 0 || supported.length > MAX_ASSETS) revert IncompatibleRewards();
        address previous;
        uint256 mask;
        for (uint256 i; i < supported.length; ++i) {
            address asset = supported[i];
            if (asset <= previous || asset.code.length == 0) revert IncompatibleRewards();
            uint256 index = _assetIndex[asset];
            if (index != 0) mask |= uint256(1) << (index - 1);
            previous = asset;
        }
        for (uint256 i; i < _assets.length; ++i) {
            if (uint16(_policies[_assets[i]] >> 16) != 0 && (mask & (uint256(1) << i)) == 0) {
                revert IncompatibleRewards();
            }
        }
    }

    function _validateRecipient(address recipient) private view {
        if (
            recipient == address(0) || recipient == address(this) || recipient == rewards
                || _excludedRecipients[recipient] != 0
        ) revert InvalidRecipient();
    }

    function _snapshotRewards() private view returns (RewardSnapshot memory snapshot) {
        if (!requiresRewards) return snapshot;
        _validateRewards(rewards);
        uint256 count = _rewardAssets.length;
        snapshot.amounts = new uint256[](count);
        snapshot.balances = new uint256[](count);
        snapshot.available = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            address asset = _rewardAssets[i];
            snapshot.balances[i] = _balanceOf(asset, rewards);
            snapshot.available[i] = ILaunchFeeRewardsV2(rewards).rewardAvailableBalance(asset);
        }
    }

    function _checkRewardSnapshot(RewardSnapshot memory snapshot) private view {
        for (uint256 i; i < _rewardAssets.length; ++i) {
            address asset = _rewardAssets[i];
            if (
                _balanceOf(asset, rewards) != snapshot.balances[i] + snapshot.amounts[i]
                    || ILaunchFeeRewardsV2(rewards).rewardAvailableBalance(asset)
                        != snapshot.available[i] + snapshot.amounts[i]
            ) revert InexactTransfer();
        }
    }

    function _collectSource(
        address source,
        uint256 row,
        HarvestAsset[] memory accounting,
        uint256[] memory sourceAmounts,
        uint256[8] memory beforeBalances
    ) private {
        uint256 count = _assets.length;
        for (uint256 i; i < count; ++i) {
            beforeBalances[i] = _balanceOf(_assets[i], address(this));
        }
        uint256[] memory amounts = ILaunchFeeSourceV1(source).collect();
        if (amounts.length != _sourceAssets[source].length) revert InexactCollection();
        uint256 mask = _sourceAssetMask[source];
        uint256 reportIndex;
        for (uint256 i; i < count; ++i) {
            uint256 reported;
            if ((mask & (uint256(1) << i)) != 0) reported = amounts[reportIndex++];
            uint256 afterBalance = _balanceOf(_assets[i], address(this));
            if (afterBalance < beforeBalances[i] || afterBalance - beforeBalances[i] != reported) {
                revert InexactCollection();
            }
            if (sourceAmounts.length != 0) sourceAmounts[row + i] = reported;
            accounting[i].collected += reported;
        }
    }

    function _reserveAsset(
        uint256 index,
        uint16 feeBps,
        address owner,
        HarvestAsset memory amounts,
        uint256[] memory sourceAmounts
    ) private {
        address asset = _assets[index];
        amounts.executor = FixedPointMathLib.fullMulDiv(amounts.collected, feeBps, BPS_DENOMINATOR);
        SplitAmounts memory fees =
            _splitAmounts(amounts.collected - amounts.executor, _policies[asset]);
        SplitAmounts memory inventory = _splitAmounts(amounts.inventory, _policies[asset]);
        amounts.developer =
            _reserveDeveloperFees(index, fees.owner, amounts.collected, sourceAmounts);
        amounts.owner = fees.owner - amounts.developer + inventory.owner;
        amounts.rewards = fees.rewards + inventory.rewards;
        amounts.burn = fees.burn + inventory.burn;
        if (amounts.owner != 0) {
            claimableOwnerFees[owner][asset] += amounts.owner;
            reservedOwnerFees[asset] += amounts.owner;
            emit OwnerFeesCredited(owner, asset, amounts.owner);
        }
    }

    function _reserveDeveloperFees(
        uint256 index,
        uint256 ownerAmount,
        uint256 collected,
        uint256[] memory sourceAmounts
    ) private returns (uint256 total) {
        if (!_hasDeveloperFees || collected == 0 || ownerAmount == 0) return 0;
        address asset = _assets[index];
        uint256 count = _assets.length;
        for (uint256 i; i < _sources.length; ++i) {
            address source = _sources[i];
            SourceTermsV3 storage terms = _sourceTerms[source];
            uint256 sourceAmount = sourceAmounts[i * count + index];
            if (terms.developerFeeBps == 0 || sourceAmount == 0) continue;
            uint256 attributed = FixedPointMathLib.fullMulDiv(ownerAmount, sourceAmount, collected);
            uint256 amount =
                FixedPointMathLib.fullMulDiv(attributed, terms.developerFeeBps, BPS_DENOMINATOR);
            if (amount == 0) continue;
            total += amount;
            claimableDeveloperFees[terms.beneficiary][asset] += amount;
            reservedDeveloperFees[asset] += amount;
            emit DeveloperFeesCredited(terms.beneficiary, source, asset, amount);
        }
    }

    function _splitAmounts(uint256 amount, uint48 packed)
        private
        pure
        returns (SplitAmounts memory split)
    {
        uint16 ownerBps = uint16(packed);
        uint16 rewardsBps = uint16(packed >> 16);
        split.owner = FixedPointMathLib.fullMulDiv(amount, ownerBps, BPS_DENOMINATOR);
        split.rewards = FixedPointMathLib.fullMulDiv(amount, rewardsBps, BPS_DENOMINATOR);
        split.burn = FixedPointMathLib.fullMulDiv(amount, uint16(packed >> 32), BPS_DENOMINATOR);
        uint256 remainder = amount - split.owner - split.rewards - split.burn;
        if (ownerBps != 0) split.owner += remainder;
        else if (rewardsBps != 0) split.rewards += remainder;
        else split.burn += remainder;
    }

    function _reserved(address asset) private view returns (uint256) {
        return reservedOwnerFees[asset] + reservedDeveloperFees[asset];
    }

    function _balanceOf(address asset, address account) private view returns (uint256) {
        return ILaunchFeeTokenV3(asset).balanceOf(account);
    }

    function _transferExact(address asset, address recipient, uint256 amount) private {
        uint256 senderBefore = _balanceOf(asset, address(this));
        uint256 recipientBefore = _balanceOf(asset, recipient);
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xa9059cbb))
            mstore(add(ptr, 4), recipient)
            mstore(add(ptr, 36), amount)
            success := call(gas(), asset, 0, ptr, 68, 0, 32)
            success := and(
                success,
                or(iszero(returndatasize()), and(eq(returndatasize(), 32), eq(mload(0), 1)))
            )
        }
        if (!success) revert TransferFailed();
        uint256 senderAfter = _balanceOf(asset, address(this));
        uint256 recipientAfter = _balanceOf(asset, recipient);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount
                || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount
        ) revert InexactTransfer();
    }

    function _burnExact(address asset, uint256 amount) private {
        uint256 balanceBefore = _balanceOf(asset, address(this));
        uint256 supplyBefore = ILaunchFeeTokenV3(asset).totalSupply();
        ILaunchFeeTokenV3(asset).burn(amount);
        uint256 balanceAfter = _balanceOf(asset, address(this));
        uint256 supplyAfter = ILaunchFeeTokenV3(asset).totalSupply();
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount
                || supplyAfter > supplyBefore || supplyBefore - supplyAfter != amount
        ) revert InexactBurn();
    }
}
