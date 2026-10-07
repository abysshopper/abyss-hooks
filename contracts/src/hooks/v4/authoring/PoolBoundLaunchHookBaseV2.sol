// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LaunchHookReentrancyGuardV1 } from "./LaunchHookReentrancyGuardV1.sol";
import { LaunchHookFeeRateV2, LaunchHookFeeContextV2 } from "./LaunchHookFeeRateV2.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IAbyssLaunchFactory } from "../../../interfaces/IAbyssLaunch.sol";
import { ILaunchFeeSourceV1 } from "../../../launch/fees/v1/ILaunchFeeSourceV1.sol";
import { ILaunchFeeHubV2 } from "../../../launch/fees/v2/ILaunchFeeHubV2.sol";
import { ILaunchFeeHubV3 } from "../../../launch/fees/v3/ILaunchFeeHubV3.sol";
import { V4FeeLiquidityLockerV2 } from "../../../launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import { ILaunchLifecycleV1 } from "../../../launch/lifecycle/v1/ILaunchLifecycleV1.sol";
import { LaunchOperationV1, LaunchPhaseV1, LaunchModeV1 } from "../../../launch/lifecycle/v1/LaunchTypesV1.sol";
import { PoolBoundHookParametersV2 } from "../PoolBoundHookParametersV2.sol";
import { V4HookFlags } from "../V4HookFlags.sol";
import { ILaunchHookV1 } from "./ILaunchHookV1.sol";

interface IPoolBoundLaunchHookRegistrarV2 {
    function core() external view returns (address);
    function poolManager() external view returns (address);
    function oracleFactory() external view returns (address);
    function locker() external view returns (address);
}

interface IPoolBoundLaunchHookValidationCollectorV2 is ILaunchFeeSourceV1 {
    function poolManager() external view returns (IPoolManager);
    function locker() external view returns (V4FeeLiquidityLockerV2);
    function hookRoot() external view returns (address);
    function poolId() external view returns (bytes32);
    function poolKey() external view returns (PoolKey memory);
    function expectedPositionCount() external view returns (uint256);
}

/// @notice Versioned one-market scalar accounting with an authenticated frozen read-only rate seam.
/// @dev V2 constructor economics bind creator fee settings; the full-key collector/locker ABI is unchanged.
///      Final callbacks, custody, full-fill, LP checkpoint and payment guards are nonvirtual.
///      Registration and author-payment checks run directly against the frozen core fields.
///      Inheritance is not a sandbox: added selectors, assembly and the full artifact need review.
abstract contract PoolBoundLaunchHookBaseV2 is ILaunchHookV1, LaunchHookReentrancyGuardV1, LaunchHookFeeRateV2 {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidHookAddress();
    error InvalidPool();
    error AlreadyRegistered();
    error ExternalLiquidityDisabled();
    error OpeningNotComplete();
    error OpeningAlreadyComplete();
    error IncompleteFill();
    error InvalidCallback();
    error InexactTransfer();
    error ClaimMismatch();
    error FeeSettlementRequired();

    uint24 public constant override PIPS_DENOMINATOR = 1_000_000;
    uint160 public constant override REQUIRED_HOOK_FLAGS = V4HookFlags.SHARED_LAUNCH_V2_PERMISSIONS;
    uint160 public constant override ALL_HOOK_MASK = V4HookFlags.ALL_HOOK_MASK;
    uint256 private constant MAX_MANAGER_DELTA = uint256(uint128(type(int128).max));

    /// @dev Scalar aggregate liabilities equal pendingFees; retain the remaining counters and
    ///      exact burn/take ordering without storing a redundant second copy of that amount.
    struct FeeAccounting {
        uint256 pendingFees;
        uint256 pendingTreasurySweeps;
        uint256 settledFees;
        uint256 aggregateManagerClaims;
    }

    IPoolManager public immutable override poolManager;
    address public immutable override registrar;
    IAbyssLaunchFactory public immutable override oracleFactory;
    address public immutable core;
    address public immutable liquidityLocker;
    address public immutable token;
    bytes32 public immutable boundPoolId;
    bytes32 public immutable deploymentConfigHash;
    bytes32 public immutable marketCommitment;
    uint160 public immutable openingSqrtPriceX96;
    uint32 public immutable expectedPositionCount;
    /// @dev Immutable creator policy: minimum pips[0:24], sensitivity[24:56].
    uint256 private immutable _creatorFeePolicy;
    address private immutable _asset0;
    address private immutable _asset1;

    PoolKey private _key;
    PoolConfig private _config;
    FeeAccounting private _currency0Accounting;
    FeeAccounting private _currency1Accounting;
    PendingSwapFee private _pendingSwapFee;
    bool private _registered;
    bool private _initialized;
    uint256 private _openingCompletedAt;
    bytes32 private _unlockContext;
    bool private _feeCheckpointActive;
    bool private _authorTermsValidated;

    event PoolRegistered(bytes32 indexed poolId, address indexed collector, address indexed locker);
    event PoolInitialized(bytes32 indexed poolId);
    event FeeAccrued(
        bytes32 indexed poolId, address indexed asset, uint256 gross, uint256 treasury
    );
    event FeesCollected(
        bytes32 indexed poolId, address indexed collector, uint256 amount0, uint256 amount1
    );
    event OpeningCompleted(bytes32 indexed poolId, uint256 indexed completedAt);
    event LpFeesCheckpointed(
        bytes32 indexed poolId, address indexed locker, uint256 amount0, uint256 amount1
    );

    constructor(PoolBoundHookParametersV2 memory parameters) {
        _validateConstructor(parameters);
        if (!V4HookFlags.hasSharedLaunchV2Permissions(address(this))) revert InvalidHookAddress();
        poolManager = IPoolManager(parameters.poolManager);
        registrar = parameters.registrar;
        oracleFactory = IAbyssLaunchFactory(parameters.oracleFactory);
        core = parameters.core;
        liquidityLocker = parameters.liquidityLocker;
        token = parameters.token;
        deploymentConfigHash = keccak256(abi.encode(parameters));
        marketCommitment = parameters.marketCommitment;
        openingSqrtPriceX96 = parameters.sqrtPriceX96;
        expectedPositionCount = parameters.expectedPositionCount;
        _creatorFeePolicy = uint256(parameters.minimumHookFeePips)
            | (uint256(parameters.feeSensitivityPipsSecondsPerTick) << 24);

        bool quoteIs0 = parameters.quoteCurrency < parameters.token;
        address asset0 = quoteIs0 ? parameters.quoteCurrency : parameters.token;
        address asset1 = quoteIs0 ? parameters.token : parameters.quoteCurrency;
        _asset0 = asset0;
        _asset1 = asset1;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(asset0),
            currency1: Currency.wrap(asset1),
            fee: parameters.lpFeePips,
            tickSpacing: parameters.tickSpacing,
            hooks: IHooks(address(this))
        });
        boundPoolId = PoolId.unwrap(key.toId());
        _key = key;
        _config = PoolConfig({
            collector: address(0),
            liquidityLocker: parameters.liquidityLocker,
            quoteCurrency: Currency.wrap(parameters.quoteCurrency),
            feeMode: FeeMode(parameters.feeMode),
            hookFeePips: parameters.hookFeePips,
            protocolFeeDenominator: parameters.protocolFeeDenominator,
            treasury: parameters.treasury,
            externalLiquidityDisabled: parameters.externalLiquidityDisabled,
            oracleConfigId: parameters.oracleConfigId
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    /// @dev Only the locker's zero-delta liquidity callbacks are allowed during a checkpoint.
    modifier nonFeeReentrant() {
        if (_feeCheckpointActive) revert Reentrancy();
        _;
    }

    function minimumHookFeePips() public view returns (uint24) {
        return uint24(_creatorFeePolicy);
    }

    function feeSensitivityPipsSecondsPerTick() public view returns (uint32) {
        return uint32(_creatorFeePolicy >> 24);
    }

    function pools() external view override returns (bytes32[] memory ids) {
        ids = new bytes32[](_registered ? 1 : 0);
        if (_registered) ids[0] = boundPoolId;
    }

    function registered(bytes32 id) external view override returns (bool) {
        _requireBoundPool(id);
        return _registered;
    }

    function initialized(bytes32 id) external view override returns (bool) {
        _requireBoundPool(id);
        return _initialized;
    }

    function poolKey(bytes32 id) external view override returns (PoolKey memory) {
        _requireBoundPool(id);
        return _key;
    }

    function poolConfig(bytes32 id) external view override returns (PoolConfig memory) {
        _requireBoundPool(id);
        return _config;
    }

    function pendingFees(bytes32 id, address asset) external view override returns (uint256) {
        _requireBoundPool(id);
        return _accounting(asset).pendingFees;
    }

    function pendingTreasurySweeps(bytes32 id, address asset)
        external
        view
        override
        returns (uint256)
    {
        _requireBoundPool(id);
        return _accounting(asset).pendingTreasurySweeps;
    }

    function settledFees(bytes32 id, address asset) external view override returns (uint256) {
        _requireBoundPool(id);
        return _accounting(asset).settledFees;
    }

    function aggregateLiabilities(address asset) external view override returns (uint256) {
        return _accounting(asset).pendingFees;
    }

    function aggregateManagerClaims(address asset) external view override returns (uint256) {
        return _accounting(asset).aggregateManagerClaims;
    }

    /// @notice The registrar binds only the collector, once, inside the exact core Prepare call.
    function registerPool(PoolKey calldata key, PoolConfig calldata config)
        external
        override
        nonReentrant
    {
        if (msg.sender != registrar) revert Unauthorized();
        _requireBoundPool(PoolId.unwrap(key.toId()));
        if (_registered) revert AlreadyRegistered();
        _validateRegistration(config);
        _onPoolRegistered(config);
        _config.collector = config.collector;
        _registered = true;
        emit PoolRegistered(boundPoolId, config.collector, liquidityLocker);
    }

    /// @notice One-shot terminal opening completion, separate from optional oracle genesis.
    /// @dev Call only after all externally callable opening work and final continuity checks;
    ///      there is no general swap gate or beforeInitialize permission.
    function completePoolOpening(PoolKey calldata key) external override nonReentrant {
        if (msg.sender != registrar) revert Unauthorized();
        _initializedPool(key);
        if (_openingCompletedAt != 0) revert OpeningAlreadyComplete();
        _openingCompletedAt = block.timestamp;
        emit OpeningCompleted(boundPoolId, block.timestamp);
    }

    function openingCompletedAt(bytes32 id) external view override returns (uint256) {
        _requireBoundPool(id);
        return _openingCompletedAt;
    }

    function validateCollector(PoolKey calldata key, address collector, address locker)
        external
        view
        override
    {
        _initializedPool(key);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(boundPoolId));
        if (
            _config.collector != collector || liquidityLocker != locker || sqrtPriceX96 == 0
        ) revert InvalidPool();
        _validateAuthorTerms();
    }

    /// @dev Only the exact planned registrar and price initialize the bound pool.
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override
        onlyPoolManager
        nonReadReentrant
        returns (bytes4)
    {
        _requireBoundPool(PoolId.unwrap(key.toId()));
        if (
            !_registered || _initialized || sender != registrar
                || sqrtPriceX96 != openingSqrtPriceX96
        ) revert InvalidPool();
        _onPoolInitialized(tick);
        _initialized = true;
        emit PoolInitialized(boundPoolId);
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override onlyPoolManager nonReadReentrant returns (bytes4) {
        _initializedPool(key);
        _validateLiquidityCaller(sender, params);
        _authenticateAuthorTerms();
        _onBeforeLiquidityChange(params);
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override onlyPoolManager nonReadReentrant returns (bytes4) {
        _initializedPool(key);
        _validateLiquidityCaller(sender, params);
        _onBeforeLiquidityChange(params);
        return this.beforeRemoveLiquidity.selector;
    }

    /// @dev Freeze before checkpoints. Specified fees precharge the full request and require an
    ///      exact fill; unspecified fees charge actual filled volume at precisely the frozen rate.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        nonReadReentrant
        nonFeeReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _initializedPool(key);
        _authenticateAuthorTerms();
        PoolConfig storage config = _config;
        uint24 rate = _freezeSwapRate(sender, params);
        Currency specified = _specifiedCurrency(key, params);
        uint256 fee;
        if (rate != 0 && _isFeeCurrency(specified, key, params, config)) {
            fee = _fee(_abs(params.amountSpecified), rate);
        }
        uint256 bound =
            V4FeeLiquidityLockerV2(liquidityLocker).inputFeeBound(key, params, fee);
        _checkpointLockerFees(key, params.zeroForOne ? bound : 0, params.zeroForOne ? 0 : bound);
        if (fee != 0) _accrue(specified, fee, config.protocolFeeDenominator);
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(int256(fee) << 128), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager nonReadReentrant nonFeeReentrant returns (bytes4, int128) {
        _initializedPool(key);
        uint24 rate = _consumeRate(_pendingSwapFee, boundPoolId, sender, params);
        _checkpointLockerFees(key, 0, 0);
        PoolConfig storage config = _config;
        Currency specified = _specifiedCurrency(key, params);
        Currency unspecified = Currency.unwrap(specified) == Currency.unwrap(key.currency0)
            ? key.currency1
            : key.currency0;
        if (rate != 0 && _isFeeCurrency(specified, key, params, config)) {
            uint256 precharged = _fee(_abs(params.amountSpecified), rate);
            if (precharged != 0) {
                int128 specifiedAmount = Currency.unwrap(specified)
                    == Currency.unwrap(key.currency0)
                    ? delta.amount0()
                    : delta.amount1();
                if (specifiedAmount != params.amountSpecified + int256(precharged)) {
                    revert IncompleteFill();
                }
            }
        }
        if (rate == 0 || !_isFeeCurrency(unspecified, key, params, config)) {
            return (this.afterSwap.selector, 0);
        }
        int128 amount = Currency.unwrap(unspecified) == Currency.unwrap(key.currency0)
            ? delta.amount0()
            : delta.amount1();
        uint256 fee = _fee(_abs(int256(amount)), rate);
        if (fee != 0) _accrue(unspecified, fee, config.protocolFeeDenominator);
        return (this.afterSwap.selector, int128(uint128(fee)));
    }

    /// @notice Current authenticated hook-rate preview, not an eventual exact-output fee amount.
    /// @dev Uses the actual manager pre-swap price/liquidity and the original signed request.
    ///      Does not reserve a swap context, notify observers or mutate payment authentication.
    function feeRate(SwapParams calldata params) external view nonReadReentrant returns (uint24) {
        if (!_initialized) revert InvalidPool();
        _validateAuthorTerms();
        (LaunchHookFeeContextV2 memory context,) = _swapRateContext(params);
        return _boundedRate(context);
    }

    function _freezeSwapRate(address sender, SwapParams calldata params)
        private
        returns (uint24 rate)
    {
        (LaunchHookFeeContextV2 memory context, int24 spotTick) = _swapRateContext(params);
        uint128 activeLiquidity = context.activeLiquidity;
        rate = _freezeRate(_pendingSwapFee, context, sender, params);
        // The read-only seam may mutate memory; observers receive the authenticated value snapshot.
        _onBeforeSwap(spotTick, activeLiquidity);
    }

    function _swapRateContext(SwapParams calldata params)
        private
        view
        returns (LaunchHookFeeContextV2 memory context, int24 spotTick)
    {
        PoolId pool = PoolId.wrap(boundPoolId);
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee,) = StateLibrary.getSlot0(poolManager, pool);
        if (protocolFee != 0) revert InvalidConfiguration();
        spotTick = tick;
        uint256 creatorFeePolicy = _creatorFeePolicy;
        context = LaunchHookFeeContextV2({
            poolId: boundPoolId,
            sqrtPriceX96: sqrtPriceX96,
            activeLiquidity: StateLibrary.getLiquidity(poolManager, pool),
            amountSpecified: params.amountSpecified,
            zeroForOne: params.zeroForOne,
            maximumPips: _config.hookFeePips,
            minimumPips: uint24(creatorFeePolicy),
            feeSensitivityPipsSecondsPerTick: uint32(creatorFeePolicy >> 24),
            feeMode: _config.feeMode
        });
    }

    /// @dev Donations checkpoint LP growth but never become hook-fee liabilities.
    function beforeDonate(
        address,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override onlyPoolManager nonReadReentrant nonFeeReentrant returns (bytes4) {
        _initializedPool(key);
        _checkpointLockerFees(key, amount0, amount1);
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        onlyPoolManager
        nonFeeReentrant
        nonReadReentrant
        returns (bytes4)
    {
        _initializedPool(key);
        _checkpointLockerFees(key, 0, 0);
        return this.afterDonate.selector;
    }

    function oracleInitializedAt(bytes32 id) external view override returns (uint256) {
        _requireBoundPool(id);
        return _oracleInitializedAt();
    }

    /// @notice Collector-only redemption of tracked fees to frozen collector/protocol treasury.
    /// @dev No alternate-recipient, author payout, currency-only preclaim or principal sweep API.
    function collectFees(PoolKey calldata key)
        external
        override
        nonReentrant
        nonFeeReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _initializedPool(key);
        if (msg.sender != _config.collector) revert Unauthorized();
        if (_currency0Accounting.pendingFees != 0 || _currency1Accounting.pendingFees != 0) {
            bytes memory payload = abi.encode(key);
            _unlockContext = keccak256(payload);
            bytes memory result = poolManager.unlock(payload);
            if (_unlockContext != bytes32(0)) revert InvalidCallback();
            (amount0, amount1) = abi.decode(result, (uint256, uint256));
        }
        emit FeesCollected(boundPoolId, msg.sender, amount0, amount1);
    }

    function unlockCallback(bytes calldata data)
        external
        override
        onlyPoolManager
        returns (bytes memory)
    {
        if (_unlockContext == bytes32(0) || keccak256(data) != _unlockContext) {
            revert InvalidCallback();
        }
        _unlockContext = bytes32(0);
        PoolKey memory key = abi.decode(data, (PoolKey));
        _requireBoundPool(PoolId.unwrap(key.toId()));
        if (!_initialized) revert InvalidPool();
        uint256 amount0 = _redeem(key.currency0);
        uint256 amount1 = _redeem(key.currency1);
        return abi.encode(amount0, amount1);
    }

    function _validateConstructor(PoolBoundHookParametersV2 memory parameters) private view {
        if (
            parameters.poolManager.code.length == 0 || parameters.registrar.code.length == 0
                || parameters.oracleFactory.code.length == 0 || parameters.core.code.length == 0
                || parameters.liquidityLocker.code.length == 0
                || parameters.quoteCurrency.code.length == 0 || parameters.token == address(0)
                || parameters.token == parameters.quoteCurrency || parameters.token == address(this)
                || parameters.registrar == parameters.core
                || parameters.registrar == parameters.poolManager
                || parameters.registrar == address(this) || parameters.core == address(this)
                || parameters.liquidityLocker == address(this)
                || parameters.liquidityLocker == parameters.poolManager
                || parameters.lpFeePips != 0
                || parameters.tickSpacing < TickMath.MIN_TICK_SPACING
                || parameters.tickSpacing > TickMath.MAX_TICK_SPACING
                || parameters.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || parameters.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
                || parameters.hookFeePips > PIPS_DENOMINATOR
                || parameters.minimumHookFeePips > parameters.hookFeePips
                || parameters.feeMode > uint8(FeeMode.QuoteOnly)
                || (parameters.protocolFeeDenominator != 0
                    && (parameters.protocolFeeDenominator < 4
                        || parameters.protocolFeeDenominator > 10))
                || (parameters.protocolFeeDenominator != 0 && parameters.treasury == address(0))
                || parameters.treasury == address(this)
                || parameters.treasury == parameters.poolManager
                || parameters.treasury == parameters.liquidityLocker
                || parameters.marketCommitment == bytes32(0)
                || parameters.expectedPositionCount == 0 || parameters.expectedPositionCount > 32
        ) revert InvalidConfiguration();
        IPoolBoundLaunchHookRegistrarV2 adapter =
            IPoolBoundLaunchHookRegistrarV2(parameters.registrar);
        V4FeeLiquidityLockerV2 locker = V4FeeLiquidityLockerV2(parameters.liquidityLocker);
        if (
            adapter.core() != parameters.core || adapter.poolManager() != parameters.poolManager
                || adapter.oracleFactory() != parameters.oracleFactory
                || adapter.locker() != parameters.liquidityLocker
                || locker.launcher() != parameters.registrar
                || address(locker.poolManager()) != parameters.poolManager
        ) revert InvalidConfiguration();
    }

    function _validateRegistration(PoolConfig calldata config) private view {
        IPoolManager manager = poolManager;
        address locker = liquidityLocker;
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(boundPoolId));
        if (
            _asset0.code.length == 0 || _asset1.code.length == 0 || sqrtPriceX96 != 0
                || config.liquidityLocker != locker
                || Currency.unwrap(config.quoteCurrency) != Currency.unwrap(_config.quoteCurrency)
                || config.feeMode != _config.feeMode || config.hookFeePips != _config.hookFeePips
                || config.protocolFeeDenominator != _config.protocolFeeDenominator
                || config.treasury != _config.treasury
                || config.externalLiquidityDisabled != _config.externalLiquidityDisabled
                || config.oracleConfigId != _config.oracleConfigId
                || config.collector.code.length == 0 || config.collector == locker
                || config.collector == address(this) || config.collector == address(manager)
        ) revert InvalidConfiguration();
        _validateCollectorBinding(config.collector);
    }

    function _validateCollectorBinding(address collectorAddress) private view {
        address manager = address(poolManager);
        address locker = liquidityLocker;
        address asset0 = _asset0;
        address asset1 = _asset1;
        address hub = _wordAddress(_staticWord(collectorAddress, ILaunchFeeSourceV1.hub.selector));
        bool sourceAssetsMatch = _staticAssetsMatch(collectorAddress, asset0, asset1);
        if (
            _wordAddress(_staticWord(collectorAddress, IPoolBoundLaunchHookValidationCollectorV2.poolManager.selector)) != manager
                || _wordAddress(_staticWord(collectorAddress, IPoolBoundLaunchHookValidationCollectorV2.locker.selector)) != locker
                || _wordAddress(_staticWord(collectorAddress, IPoolBoundLaunchHookValidationCollectorV2.hookRoot.selector)) != address(this)
                || _staticWord(collectorAddress, IPoolBoundLaunchHookValidationCollectorV2.poolId.selector) != boundPoolId
                || _staticPoolKeyHash(collectorAddress) != boundPoolId
                || uint256(_staticWord(collectorAddress, IPoolBoundLaunchHookValidationCollectorV2.expectedPositionCount.selector)) != expectedPositionCount
                || _wordAddress(_staticWord(locker, V4FeeLiquidityLockerV2.poolManager.selector)) != manager
                || _wordAddress(_staticWord(locker, V4FeeLiquidityLockerV2.launcher.selector)) != registrar
                || _staticPoolWord(locker, V4FeeLiquidityLockerV2.positionCount.selector) != bytes32(0)
                || _wordBool(_staticPoolWord(locker, V4FeeLiquidityLockerV2.isSealed.selector))
                || _staticPoolWord(locker, V4FeeLiquidityLockerV2.positionsHash.selector) != bytes32(0)
                || _wordAddress(_staticPoolWord(locker, V4FeeLiquidityLockerV2.feeRecipient.selector)) != address(0)
                || !sourceAssetsMatch
                || hub.code.length == 0 || hub == address(this) || hub == collectorAddress
                || hub == locker || hub == manager
                || hub == asset0 || hub == asset1
                || _config.treasury == hub || _config.treasury == collectorAddress
        ) revert InvalidConfiguration();
        if (
            _wordAddress(_staticWord(hub, ILaunchFeeHubV2.launchToken.selector)) != token
                || _wordAddress(_staticWord(hub, ILaunchFeeHubV2.configurator.selector)) != core
                || _wordBool(_staticWord(hub, ILaunchFeeHubV2.finalized.selector))
        ) revert InvalidConfiguration();
        _validatePrepareContext(hub);
    }

    function _validatePrepareContext(address hub) private view {
        address lifecycle = core;
        uint256 ptr = _staticGetter(
            lifecycle, ILaunchLifecycleV1.executionContext.selector, bytes32(0), 4, 352
        );
        {
            uint256 maxOperation = uint256(type(LaunchOperationV1).max);
            // Eleven static ABI words; validate even the custody/recipient fields not compared below.
            assembly ("memory-safe") {
                if or(shr(32, mload(add(ptr, 0x20))), gt(mload(add(ptr, 0x40)), maxOperation)) {
                    revert(0, 0)
                }
                let end := add(ptr, 0x140)
                for { let cursor := add(ptr, 0x60) } lt(cursor, end) { cursor := add(cursor, 0x20) } {
                    if shr(160, mload(cursor)) { revert(0, 0) }
                }
            }
        }
        address adapter = registrar;
        address launchToken = token;
        bytes32 launchId = _wordAt(ptr, 0);
        if (
            launchId == bytes32(0) || uint256(_wordAt(ptr, 0x40)) != uint256(LaunchOperationV1.Prepare)
                || _wordAt(ptr, 0x60) != bytes32(uint256(uint160(adapter)))
                || _wordAt(ptr, 0x80) != bytes32(uint256(uint160(adapter)))
                || _wordAt(ptr, 0xa0) != bytes32(uint256(uint160(launchToken)))
                || _wordAt(ptr, 0xc0) != bytes32(uint256(uint160(Currency.unwrap(_config.quoteCurrency))))
                || _wordAt(ptr, 0xe0) != bytes32(uint256(uint160(address(poolManager))))
        ) revert Unauthorized();
        // Snapshot the index before the next getter reuses the context scratch buffer.
        uint32 marketIndex = uint32(uint256(_wordAt(ptr, 0x20)));
        ptr = _staticGetter(
            lifecycle, ILaunchLifecycleV1.readLaunchProgress.selector, launchId, 36, 448
        );
        {
            uint256 maxMode = uint256(type(LaunchModeV1).max);
            uint256 maxPhase = uint256(type(LaunchPhaseV1).max);
            // Fourteen static words: creator, mode/phase, token/hub/rewards, then four uint32 counters.
            assembly ("memory-safe") {
                if or(
                    shr(160, mload(add(ptr, 0x40))),
                    or(gt(mload(add(ptr, 0x80)), maxMode), gt(mload(add(ptr, 0xa0)), maxPhase))
                ) { revert(0, 0) }
                let end := add(ptr, 0x120)
                for { let cursor := add(ptr, 0xc0) } lt(cursor, end) { cursor := add(cursor, 0x20) } {
                    if shr(160, mload(cursor)) { revert(0, 0) }
                }
                end := add(ptr, 0x1a0)
                for { let cursor := add(ptr, 0x120) } lt(cursor, end) { cursor := add(cursor, 0x20) } {
                    if shr(32, mload(cursor)) { revert(0, 0) }
                }
            }
        }
        if (
            _wordAt(ptr, 0) != launchId || uint256(_wordAt(ptr, 0xa0)) != uint256(LaunchPhaseV1.Preparing)
                || _wordAt(ptr, 0xc0) != bytes32(uint256(uint160(launchToken)))
                || _wordAt(ptr, 0xe0) != bytes32(uint256(uint160(hub)))
                || marketIndex >= uint256(_wordAt(ptr, 0x140))
        ) revert Unauthorized();
    }

    /// @dev Source terms are bound after initialize, before the first canonical mint.
    ///      Set the lifetime guard only after successful authentication of the one-shot hub terms.
    function _authenticateAuthorTerms() private {
        if (_authorTermsValidated) return;
        _validateAuthorTerms();
        _authorTermsValidated = true;
    }

    function _validateAuthorTerms() private view {
        if (_authorTermsValidated) return;
        address collector = _config.collector;
        address hub = _wordAddress(_staticWord(collector, ILaunchFeeSourceV1.hub.selector));
        uint256 ptr = _staticGetter(
            hub, ILaunchFeeHubV3.sourceTerms.selector, bytes32(uint256(uint160(collector))), 36, 192
        );
        // Six static words: two addresses, two bytes32 commitments, then two uint16 fee fields.
        assembly ("memory-safe") {
            if or(shr(160, mload(ptr)), shr(160, mload(add(ptr, 0x60)))) { revert(0, 0) }
            if shr(16, or(mload(add(ptr, 0x80)), mload(add(ptr, 0xa0)))) { revert(0, 0) }
            // Later hub getters borrow scratch memory; retain these terms without another copy.
            mstore(0x40, add(ptr, 0xc0))
        }
        uint16 requiredBps = authorFeeBps();
        if (
            requiredBps > 9_999
                || _wordAddress(_staticWord(hub, ILaunchFeeHubV2.launchToken.selector)) != token
                || _wordAddress(_staticWord(hub, ILaunchFeeHubV2.configurator.selector)) != core
                || _wordAt(ptr, 0) != bytes32(uint256(uint160(registrar)))
                || _wordAt(ptr, 0x20) == bytes32(0) || _wordAt(ptr, 0x40) == bytes32(0)
                || _wordAt(ptr, 0x60) == bytes32(0) || uint256(_wordAt(ptr, 0xa0)) != requiredBps
                || uint256(_wordAt(ptr, 0xa0)) > uint256(_wordAt(ptr, 0x80))
        ) revert InvalidConfiguration();
    }

    /// @dev Retain the dynamic ABI offset and bounds rules without allocating the returned array.
    ///      Full-word equality against clean frozen addresses also rejects dirty address words.
    function _staticAssetsMatch(address target, address asset0, address asset1)
        private
        view
        returns (bool matches)
    {
        uint256 ptr = _staticGetter(target, ILaunchFeeSourceV1.assets.selector, bytes32(0), 4, 32);
        uint256 expected0 = uint160(asset0);
        uint256 expected1 = uint160(asset1);
        assembly ("memory-safe") {
            let size := returndatasize()
            let offset := mload(ptr)
            if or(gt(offset, 0xffffffffffffffff), gt(offset, sub(size, 32))) { revert(0, 0) }
            returndatacopy(ptr, offset, 32)
            let length := mload(ptr)
            if or(
                gt(length, 0xffffffffffffffff),
                gt(length, div(sub(sub(size, offset), 32), 32))
            ) { revert(0, 0) }
            if eq(length, 2) {
                returndatacopy(ptr, add(offset, 32), 64)
                matches := and(eq(mload(ptr), expected0), eq(mload(add(ptr, 32)), expected1))
            }
        }
    }

    /// @dev Equality with the frozen canonical full-key hash also rejects dirty address/fee/tick words.
    function _staticPoolKeyHash(address target) private view returns (bytes32 value) {
        uint256 ptr = _staticGetter(
            target, IPoolBoundLaunchHookValidationCollectorV2.poolKey.selector, bytes32(0), 4, 160
        );
        assembly ("memory-safe") {
            value := keccak256(ptr, 160)
        }
    }

    function _staticWord(address target, bytes4 selector) private view returns (bytes32 value) {
        uint256 ptr = _staticGetter(target, selector, bytes32(0), 4, 32);
        assembly ("memory-safe") {
            value := mload(ptr)
        }
    }

    function _staticPoolWord(address target, bytes4 selector) private view returns (bytes32 value) {
        uint256 ptr = _staticGetter(target, selector, boundPoolId, 36, 32);
        assembly ("memory-safe") {
            value := mload(ptr)
        }
    }

    /// @dev Read a validated static tuple without default-initializing a memory struct over it.
    function _wordAt(uint256 ptr, uint256 offset) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(ptr, offset))
        }
    }

    /// @dev Borrow scratch memory consumed immediately by the fixed-layout getter callers.
    ///      Preserve minimum return length, trailing data acceptance and exact target reverts.
    function _staticGetter(
        address target, bytes4 selector, bytes32 argument, uint256 inputSize, uint256 outputSize
    ) private view returns (uint256 ptr) {
        assembly ("memory-safe") {
            ptr := mload(0x40)
            mstore(ptr, selector)
            if eq(inputSize, 36) { mstore(add(ptr, 4), argument) }
            if iszero(staticcall(gas(), target, ptr, inputSize, ptr, outputSize)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), outputSize) { revert(0, 0) }
        }
    }

    function _wordAddress(bytes32 word) private pure returns (address value) {
        assembly ("memory-safe") {
            if shr(160, word) { revert(0, 0) }
            value := word
        }
    }

    function _wordBool(bytes32 word) private pure returns (bool value) {
        assembly ("memory-safe") {
            if gt(word, 1) { revert(0, 0) }
            value := word
        }
    }

    function _requireBoundPool(bytes32 id) internal view {
        if (id != boundPoolId) revert InvalidPool();
    }

    function _initializedPool(PoolKey calldata key) private view {
        _requireBoundPool(PoolId.unwrap(key.toId()));
        if (!_initialized) revert InvalidPool();
    }

    function _accounting(address asset) private view returns (FeeAccounting storage accounting) {
        if (asset == _asset0) return _currency0Accounting;
        if (asset == _asset1) return _currency1Accounting;
        revert InvalidPool();
    }

    function _validateLiquidityCaller(address sender, ModifyLiquidityParams calldata params)
        private
        view
    {
        if (_feeCheckpointActive && (sender != liquidityLocker || params.liquidityDelta != 0)) {
            revert Reentrancy();
        }
        if (_openingCompletedAt == 0) {
            if (sender != liquidityLocker) revert OpeningNotComplete();
        } else if (_config.externalLiquidityDisabled && sender != liquidityLocker) {
            revert ExternalLiquidityDisabled();
        }
    }

    /// @dev Canonical V2 event-bound/headroom-driven parking, including the no-position skip.
    function _checkpointLockerFees(PoolKey calldata key, uint256 bound0, uint256 bound1) private {
        if (V4FeeLiquidityLockerV2(liquidityLocker).positionCount(boundPoolId) == 0) return;
        _feeCheckpointActive = true;
        (uint256 amount0, uint256 amount1) =
            V4FeeLiquidityLockerV2(liquidityLocker).checkpointFees(key, bound0, bound1);
        _feeCheckpointActive = false;
        emit LpFeesCheckpointed(boundPoolId, liquidityLocker, amount0, amount1);
    }

    /// @dev Core-only hooks have no observer; optional composition supplies these notifications.
    function _onPoolRegistered(PoolConfig calldata) internal virtual {}

    function _onPoolInitialized(int24) internal virtual {}

    function _onBeforeLiquidityChange(ModifyLiquidityParams calldata) internal virtual {}

    function _onBeforeSwap(int24, uint128) internal virtual {}

    function _oracleInitializedAt() internal view virtual returns (uint256) {
        return 0;
    }

    function _isFeeCurrency(
        Currency currency,
        PoolKey calldata key,
        SwapParams calldata params,
        PoolConfig storage config
    ) private view returns (bool) {
        Currency selected = config.feeMode == FeeMode.QuoteOnly
            ? config.quoteCurrency
            : (params.zeroForOne ? key.currency0 : key.currency1);
        return Currency.unwrap(currency) == Currency.unwrap(selected);
    }

    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (Currency)
    {
        return (params.amountSpecified < 0) == params.zeroForOne ? key.currency0 : key.currency1;
    }

    function _accrue(Currency currency, uint256 amount, uint8 denominator) private nonReentrant {
        address asset = Currency.unwrap(currency);
        FeeAccounting storage accounting = _accounting(asset);
        uint256 claims = accounting.pendingFees - accounting.settledFees;
        if (amount > MAX_MANAGER_DELTA - claims) _settleClaims(currency, accounting, claims);
        // Preserve upstream policy exactly, including division order. This is not an author fee:
        // denominator 4 means (amount / 4) * 125 / 100, NOT amount / 4 or an author recipient.
        uint256 treasury = denominator == 0 ? 0 : (amount / denominator) * 125 / 100;
        accounting.pendingFees += amount;
        accounting.pendingTreasurySweeps += treasury;
        accounting.aggregateManagerClaims += amount;
        uint256 beforeClaims = poolManager.balanceOf(address(this), uint160(asset));
        poolManager.mint(address(this), uint160(asset), amount);
        uint256 afterClaims = poolManager.balanceOf(address(this), uint160(asset));
        // The first comparison makes the subsequent difference non-underflowing.
        unchecked {
            if (
                afterClaims < beforeClaims || afterClaims - beforeClaims != amount
                    || afterClaims < accounting.aggregateManagerClaims
            ) revert ClaimMismatch();
        }
        emit FeeAccrued(boundPoolId, asset, amount, treasury);
    }

    function _redeem(Currency currency) private returns (uint256 net) {
        address asset = Currency.unwrap(currency);
        FeeAccounting storage accounting = _accounting(asset);
        uint256 gross = accounting.pendingFees;
        if (gross == 0) return 0;
        _settleClaims(currency, accounting, gross - accounting.settledFees);
        uint256 treasury = accounting.pendingTreasurySweeps;
        accounting.pendingFees = 0;
        accounting.pendingTreasurySweeps = 0;
        accounting.settledFees = 0;
        net = gross - treasury;
        _transferExact(asset, _config.treasury, treasury);
        _transferExact(asset, _config.collector, net);
    }

    /// @dev Burn before taking cash; only after exact take succeeds mark tracked ERC20 fees.
    ///      Temporarily absent manager cash requires repayment/settlement, never a fake fallback.
    function _settleClaims(Currency currency, FeeAccounting storage accounting, uint256 claims)
        private
    {
        if (claims == 0) return;
        address asset = Currency.unwrap(currency);
        if (SafeTransferLib.balanceOf(asset, address(poolManager)) < claims) {
            revert FeeSettlementRequired();
        }
        accounting.aggregateManagerClaims -= claims;
        _burnExact(asset, accounting, claims);
        _takeExact(currency, address(this), claims);
        accounting.settledFees += claims;
    }

    function _burnExact(address asset, FeeAccounting storage accounting, uint256 amount) private {
        uint256 beforeClaims = poolManager.balanceOf(address(this), uint160(asset));
        poolManager.burn(address(this), uint160(asset), amount);
        uint256 afterClaims = poolManager.balanceOf(address(this), uint160(asset));
        unchecked {
            if (
                afterClaims > beforeClaims || beforeClaims - afterClaims != amount
                    || afterClaims < accounting.aggregateManagerClaims
            ) revert ClaimMismatch();
        }
    }

    function _takeExact(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        address asset = Currency.unwrap(currency);
        uint256 beforeManager = SafeTransferLib.balanceOf(asset, address(poolManager));
        uint256 beforeRecipient = SafeTransferLib.balanceOf(asset, recipient);
        poolManager.take(currency, recipient, amount);
        uint256 afterManager = SafeTransferLib.balanceOf(asset, address(poolManager));
        uint256 afterRecipient = SafeTransferLib.balanceOf(asset, recipient);
        // Short-circuit order checks make both differences non-underflowing.
        unchecked {
            if (
                afterManager > beforeManager || beforeManager - afterManager != amount
                    || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount
            ) revert InexactTransfer();
        }
    }

    function _transferExact(address asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeSource = SafeTransferLib.balanceOf(asset, address(this));
        uint256 beforeRecipient = SafeTransferLib.balanceOf(asset, recipient);
        SafeTransferLib.safeTransfer(asset, recipient, amount);
        uint256 afterSource = SafeTransferLib.balanceOf(asset, address(this));
        uint256 afterRecipient = SafeTransferLib.balanceOf(asset, recipient);
        unchecked {
            if (
                afterSource > beforeSource || beforeSource - afterSource != amount
                    || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount
            ) revert InexactTransfer();
        }
    }
}
