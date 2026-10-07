// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LaunchHookReentrancyGuardV1 } from "./LaunchHookReentrancyGuardV1.sol";
import { LaunchHookFeeRateV2, LaunchHookFeeContextV2 } from "./LaunchHookFeeRateV2.sol";
import { PoolBoundLaunchHookValidationV2 } from "./PoolBoundLaunchHookValidationV2.sol";
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
import { V4FeeLiquidityLockerV2 } from "../../../launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import { PoolBoundHookParametersV1 } from "../PoolBoundHookParametersV1.sol";
import { TruncatedOracle } from "../TruncatedOracle.sol";
import { V4HookFlags } from "../V4HookFlags.sol";
import { ILaunchHookV1 } from "./ILaunchHookV1.sol";

interface IPoolBoundLaunchHookRegistrarV2 {
    function core() external view returns (address);
    function poolManager() external view returns (address);
    function oracleFactory() external view returns (address);
    function locker() external view returns (address);
}

/// @notice Versioned one-market scalar accounting with an authenticated frozen pure rate seam.
/// @dev The constructor tuple and full-key V2 collector/locker ABI stay unchanged.
///      Final callbacks, custody, full-fill, oracle and LP checkpoint guards are nonvirtual.
///      Cold registration and author-payment checks live in a fixed constructor-created helper.
///      Inheritance is not a sandbox: added selectors, assembly and the full artifact need review.
abstract contract PoolBoundLaunchHookBaseV2 is ILaunchHookV1, LaunchHookReentrancyGuardV1, LaunchHookFeeRateV2 {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using TruncatedOracle for TruncatedOracle.Observation[65_535];

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
    uint16 public constant override MAX_ORACLE_CARDINALITY = 4_096;
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
    PoolBoundLaunchHookValidationV2 public immutable validationHelper;
    address private immutable _asset0;
    address private immutable _asset1;
    bool private immutable _quoteIs0;

    PoolKey private _key;
    PoolConfig private _config;
    OracleState private _oracleState;
    TruncatedOracle.Observation[65_535] private _observations;
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
    event IncreaseObservationCardinalityNext(
        bytes32 indexed poolId, uint16 cardinalityNextOld, uint16 cardinalityNextNew
    );
    event OpeningCompleted(bytes32 indexed poolId, uint256 indexed completedAt);
    event LpFeesCheckpointed(
        bytes32 indexed poolId, address indexed locker, uint256 amount0, uint256 amount1
    );

    constructor(PoolBoundHookParametersV1 memory parameters) {
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
        validationHelper = new PoolBoundLaunchHookValidationV2();

        bool quoteIs0 = parameters.quoteCurrency < parameters.token;
        address asset0 = quoteIs0 ? parameters.quoteCurrency : parameters.token;
        address asset1 = quoteIs0 ? parameters.token : parameters.quoteCurrency;
        _asset0 = asset0;
        _asset1 = asset1;
        _quoteIs0 = quoteIs0;
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
        (uint24 maxAbsTickMove, uint16 cardinality) =
            validateOracleConfig(parameters.oracleConfigId);
        _oracleState.maxAbsTickMove = int24(maxAbsTickMove);
        _oracleState.cardinalityCap = cardinality;
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

    function oracleState(bytes32 id)
        external
        view
        override
        returns (
            uint16 index,
            uint16 cardinality,
            uint16 cardinalityNext,
            int24 tick,
            uint64 lastBlock,
            uint64 initializedAt,
            int24 maxAbsTickMove,
            uint16 cardinalityCap
        )
    {
        _requireBoundPool(id);
        OracleState storage state = _oracleState;
        return (
            state.index,
            state.cardinality,
            state.cardinalityNext,
            state.tick,
            state.lastBlock,
            state.initializedAt,
            state.maxAbsTickMove,
            state.cardinalityCap
        );
    }

    function observations(bytes32 id, uint256 index)
        external
        view
        override
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool observationInitialized
        )
    {
        _requireBoundPool(id);
        TruncatedOracle.Observation storage observation = _observations[index];
        return (
            observation.blockTimestamp,
            observation.tickCumulative,
            observation.secondsPerLiquidityCumulativeX128,
            observation.initialized
        );
    }

    /// @notice Validates the canonical registry entry; numeric overrides are never accepted.
    function validateOracleConfig(bytes32 oracleConfigId)
        public
        view
        override
        returns (uint24 maxAbsTickMove, uint16 cardinality)
    {
        (maxAbsTickMove, cardinality) = oracleFactory.oracleConfigs(oracleConfigId);
        if (
            maxAbsTickMove == 0 || maxAbsTickMove > uint24(uint256(int256(TickMath.MAX_TICK)))
                || cardinality < 2 || cardinality > MAX_ORACLE_CARDINALITY
        ) revert InvalidConfiguration();
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
        validationHelper.validateRegistration(config);
        (uint24 maxAbsTickMove, uint16 cardinality) = validateOracleConfig(config.oracleConfigId);
        if (
            int24(maxAbsTickMove) != _oracleState.maxAbsTickMove
                || cardinality != _oracleState.cardinalityCap
        ) revert InvalidConfiguration();
        _config.collector = config.collector;
        _registered = true;
        emit PoolRegistered(boundPoolId, config.collector, liquidityLocker);
    }

    /// @notice One-shot terminal opening completion, separate from genuine oracle genesis.
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

    /// @dev Only the exact planned registrar/price initializes; no fabricated oracle history.
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
        OracleState storage state = _oracleState;
        (state.cardinality, state.cardinalityNext) =
            _observations.initialize(uint32(block.timestamp));
        state.tick = TruncatedOracle.normalizeTick(tick, _quoteIs0);
        state.lastBlock = uint64(block.number);
        state.initializedAt = uint64(block.timestamp);
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
        _recordBeforeLiquidityChange(params);
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
        _recordBeforeLiquidityChange(params);
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
    ///      Does not reserve a swap context, update the oracle or mutate payment authentication.
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
        // The pure seam may mutate memory; the oracle uses the authenticated value snapshot.
        if (block.number != _oracleState.lastBlock) _record(spotTick, activeLiquidity);
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
        context = LaunchHookFeeContextV2({
            poolId: boundPoolId,
            sqrtPriceX96: sqrtPriceX96,
            activeLiquidity: StateLibrary.getLiquidity(poolManager, pool),
            amountSpecified: params.amountSpecified,
            zeroForOne: params.zeroForOne,
            maximumPips: _config.hookFeePips,
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

    /// @notice Quote-per-base tick and liquidity cumulatives for the exact single pool.
    /// @dev Canonical V2 interpolation, boundaries and modular counters; pre-genesis fails closed.
    function observeTruncated(bytes32 id, uint32[] calldata secondsAgos)
        external
        view
        override
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        _requireBoundPool(id);
        OracleState storage state = _oracleState;
        if (state.cardinality == 0) revert TruncatedOracle.InvalidObservationState();
        return _observations.observe(
            uint32(block.timestamp),
            secondsAgos,
            state.tick,
            state.index,
            StateLibrary.getLiquidity(poolManager, PoolId.wrap(boundPoolId)),
            state.cardinality
        );
    }

    /// @notice Monotonic capacity preparation capped by the frozen constructor snapshot.
    function increaseObservationCardinalityNext(bytes32 id, uint16 requested)
        external
        override
        nonReadReentrant
    {
        _requireBoundPool(id);
        OracleState storage state = _oracleState;
        if (requested > state.cardinalityCap) requested = state.cardinalityCap;
        uint16 oldNext = state.cardinalityNext;
        uint16 newNext = _observations.grow(oldNext, requested);
        state.cardinalityNext = newNext;
        if (oldNext != newNext) emit IncreaseObservationCardinalityNext(id, oldNext, newNext);
    }

    function oracleInitializedAt(bytes32 id) external view override returns (uint256) {
        _requireBoundPool(id);
        return _oracleState.initializedAt;
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

    function _validateConstructor(PoolBoundHookParametersV1 memory parameters) private view {
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

    /// @dev Source terms are bound after initialize, before the first canonical mint.
    ///      Set the lifetime guard only after successful authentication of the one-shot hub terms.
    function _authenticateAuthorTerms() private {
        if (_authorTermsValidated) return;
        validationHelper.validateAuthorTerms();
        _authorTermsValidated = true;
    }

    function _validateAuthorTerms() private view {
        if (!_authorTermsValidated) validationHelper.validateAuthorTerms();
    }

    function _requireBoundPool(bytes32 id) private view {
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

    function _recordBeforeLiquidityChange(ModifyLiquidityParams calldata params) private {
        if (params.liquidityDelta == 0 || block.number == _oracleState.lastBlock) return;
        PoolId pool = PoolId.wrap(boundPoolId);
        (, int24 spotTick,,) = StateLibrary.getSlot0(poolManager, pool);
        if (spotTick < params.tickLower || spotTick >= params.tickUpper) return;
        _record(spotTick, StateLibrary.getLiquidity(poolManager, pool));
    }

    function _record(int24 spotTick, uint128 activeLiquidity) private {
        OracleState storage state = _oracleState;
        (state.index, state.cardinality) = _observations.write(
            state.index,
            uint32(block.timestamp),
            state.tick,
            activeLiquidity,
            state.cardinality,
            state.cardinalityNext
        );
        state.tick = TruncatedOracle.nextTruncatedTick(
            state.tick, spotTick, state.maxAbsTickMove, _quoteIs0
        );
        state.lastBlock = uint64(block.number);
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
