// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IAbyssLaunchFactory } from "../../interfaces/IAbyssLaunch.sol";
import { ILaunchFeeSourceV1 } from "../../launch/fees/v1/ILaunchFeeHubV1.sol";
import { V4FeeLiquidityLockerV2 } from "../../launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import { TruncatedOracle } from "./TruncatedOracle.sol";
import { V4HookFlags } from "./V4HookFlags.sol";

interface ISharedLaunchFeeCollectorV2 is ILaunchFeeSourceV1 {
    function poolManager() external view returns (IPoolManager);
    function locker() external view returns (V4FeeLiquidityLockerV2);
    function poolId() external view returns (bytes32);
    function poolKey() external view returns (PoolKey memory);
}

/// @notice Registered multi-pool V4 fee custody with a genuine pool-local truncated oracle.
/// @dev Static LP fees and zero hook fees are supported. Oracle parameters are snapshotted from
///      the immutable canonical factory. ERC20 and ERC6909 donations are never fee liabilities.
contract SharedLaunchFeeHookV2 is IUnlockCallback, ReentrancyGuard {
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
    error FeeTooLarge();
    error InexactTransfer();
    error ClaimMismatch();
    error FeeSettlementRequired();

    uint24 public constant PIPS_DENOMINATOR = 1_000_000;
    uint16 public constant MAX_ORACLE_CARDINALITY = 4_096;
    uint160 public constant REQUIRED_HOOK_FLAGS = V4HookFlags.SHARED_LAUNCH_V2_PERMISSIONS;
    uint160 public constant ALL_HOOK_MASK = V4HookFlags.ALL_HOOK_MASK;
    uint256 private constant MAX_MANAGER_DELTA = uint256(uint128(type(int128).max));

    enum FeeMode {
        InputToken,
        QuoteOnly
    }

    struct PoolConfig {
        address collector;
        address liquidityLocker;
        Currency quoteCurrency;
        FeeMode feeMode;
        uint24 hookFeePips;
        uint8 protocolFeeDenominator;
        address treasury;
        bool externalLiquidityDisabled;
        bytes32 oracleConfigId;
    }

    /// @dev One packed slot per full PoolId. Configured capacity is not populated history.
    struct OracleState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
        int24 tick;
        uint64 lastBlock;
        uint64 initializedAt;
        int24 maxAbsTickMove;
        uint16 cardinalityCap;
    }

    IPoolManager public immutable poolManager;
    address public immutable registrar;
    IAbyssLaunchFactory public immutable oracleFactory;
    mapping(bytes32 poolId => bool value) public registered;
    mapping(bytes32 poolId => bool value) public initialized;
    mapping(bytes32 poolId => mapping(address asset => uint256 amount)) public pendingFees;
    mapping(bytes32 poolId => mapping(address asset => uint256 amount)) public
        pendingTreasurySweeps;
    mapping(address asset => uint256 amount) public aggregateLiabilities;
    mapping(bytes32 poolId => mapping(address asset => uint256 amount)) public settledFees;
    mapping(address asset => uint256 amount) public aggregateManagerClaims;
    mapping(bytes32 poolId => OracleState state) public oracleState;
    mapping(bytes32 poolId => TruncatedOracle.Observation[65_535] ring) public observations;
    mapping(bytes32 poolId => PoolKey key) private _keys;
    mapping(bytes32 poolId => PoolConfig config) private _configs;
    mapping(bytes32 poolId => uint256 completedAt) private _openingCompletedAt;
    bytes32[] private _poolIds;
    bytes32 private _unlockContext;
    bool private _feeCheckpointActive;

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

    constructor(IPoolManager manager_, address registrar_, IAbyssLaunchFactory oracleFactory_) {
        if (
            address(manager_).code.length == 0 || registrar_ == address(0)
                || registrar_ == address(manager_) || registrar_ == address(this)
                || address(oracleFactory_).code.length == 0
        ) revert InvalidConfiguration();
        if (!V4HookFlags.hasSharedLaunchV2Permissions(address(this))) revert InvalidHookAddress();
        poolManager = manager_;
        registrar = registrar_;
        oracleFactory = oracleFactory_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    /// @dev Locker zero-delta liquidity callbacks remain admissible during a checkpoint.
    ///      Token callbacks may not recursively grow fees or collect while its cash moves.
    modifier nonFeeReentrant() {
        if (_feeCheckpointActive) revert Reentrancy();
        _;
    }

    function pools() external view returns (bytes32[] memory) {
        return _poolIds;
    }

    function poolKey(bytes32 id) external view returns (PoolKey memory) {
        return _keys[id];
    }

    function poolConfig(bytes32 id) external view returns (PoolConfig memory) {
        return _configs[id];
    }

    /// @notice Validates the canonical registry entry; callers cannot supply numeric overrides.
    function validateOracleConfig(bytes32 oracleConfigId)
        public
        view
        returns (uint24 maxAbsTickMove, uint16 cardinality)
    {
        (maxAbsTickMove, cardinality) = oracleFactory.oracleConfigs(oracleConfigId);
        if (
            maxAbsTickMove == 0 || maxAbsTickMove > uint24(uint256(int256(TickMath.MAX_TICK)))
                || cardinality < 2 || cardinality > MAX_ORACLE_CARDINALITY
        ) revert InvalidConfiguration();
    }

    /// @notice Registrar-only registration must precede PoolManager initialization. No rebinds.
    function registerPool(PoolKey calldata key, PoolConfig calldata config) external nonReentrant {
        if (msg.sender != registrar) revert Unauthorized();
        bytes32 id = PoolId.unwrap(key.toId());
        if (registered[id]) revert AlreadyRegistered();
        _validateRegistration(key, config, id);
        (uint24 maxAbsTickMove, uint16 cardinality) = validateOracleConfig(config.oracleConfigId);
        _keys[id] = key;
        _configs[id] = config;
        oracleState[id].maxAbsTickMove = int24(maxAbsTickMove);
        oracleState[id].cardinalityCap = cardinality;
        registered[id] = true;
        _poolIds.push(id);
        emit PoolRegistered(id, config.collector, config.liquidityLocker);
    }

    /// @notice Registrar-only terminal opening completion (audit M2). Until it is called, only
    ///         the registered liquidity locker may add liquidity; afterwards the pool's frozen
    ///         `externalLiquidityDisabled` policy applies unchanged. There is no swap gate.
    /// @dev The lifecycle registrar calls this only after all final opening-state continuity
    ///      checks pass at the terminal activation boundary, with no external interaction between
    ///      completion and the irreversible Active transition.
    function completePoolOpening(PoolKey calldata key) external nonReentrant {
        if (msg.sender != registrar) revert Unauthorized();
        bytes32 id = _initializedPool(key);
        if (_openingCompletedAt[id] != 0) revert OpeningAlreadyComplete();
        _openingCompletedAt[id] = block.timestamp;
        emit OpeningCompleted(id, block.timestamp);
    }

    /// @notice Timestamp of terminal opening completion; 0 until the registrar completes it.
    /// @dev Lending consumers must treat this as the postactivation maturity anchor. It is
    ///      distinct from the scalar oracle genesis `oracleState(id).initializedAt`.
    function openingCompletedAt(bytes32 id) external view returns (uint256) {
        return _openingCompletedAt[id];
    }

    /// @notice Readiness check used by the bound source before hub configuration.
    function validateCollector(PoolKey calldata key, address collector, address liquidityLocker)
        external
        view
    {
        bytes32 id = _initializedPool(key);
        PoolConfig storage config = _configs[id];
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(id));
        if (
            config.collector != collector || config.liquidityLocker != liquidityLocker
                || sqrtPriceX96 == 0
        ) revert InvalidPool();
    }

    /// @dev Canonical genesis: no fabricated pre-launch history and no automatic ring growth.
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        nonReadReentrant
        returns (bytes4)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        if (!registered[id] || initialized[id] || address(key.hooks) != address(this)) {
            revert InvalidPool();
        }
        OracleState storage state = oracleState[id];
        (state.cardinality, state.cardinalityNext) =
            observations[id].initialize(uint32(block.timestamp));
        state.tick = TruncatedOracle.normalizeTick(tick, _quoteIsCurrency0(id));
        state.lastBlock = uint64(block.number);
        state.initializedAt = uint64(block.timestamp);
        initialized[id] = true;
        emit PoolInitialized(id);
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager nonReadReentrant returns (bytes4) {
        bytes32 id = _initializedPool(key);
        _validateLiquidityCaller(sender, id);
        _recordBeforeLiquidityChange(id, params);
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager nonReadReentrant returns (bytes4) {
        bytes32 id = _initializedPool(key);
        _validateLiquidityCaller(sender, id);
        _recordBeforeLiquidityChange(id, params);
        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice Specified-currency fee branches (audit M1) precharge the fee on the full request
    ///         and then require the swap to fill exactly. `afterSwap` reverts the entire swap on
    ///         any partial fill — price limit, exhausted/zero liquidity — so an incomplete fill
    ///         is never charged and the requested currency is never turned into debt. This is
    ///         rejection, not reconciliation; nothing is suppressed and no unspecified debt can
    ///         remain: a reverting swap accrues nothing because the manager call reverts as a
    ///         whole.
    /// @dev Unspecified-fee branches are charged only on the actual filled volume in afterSwap,
    ///      unchanged. Tight-limit full fills (price exactly reaching the limit with the full
    ///      specified amount exchanged) still pay the full fee.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReadReentrant
        nonFeeReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 id = _initializedPool(key);
        PoolConfig storage config = _configs[id];
        Currency specified = _specifiedCurrency(key, params);
        uint256 fee;
        if (config.hookFeePips != 0 && _isFeeCurrency(specified, key, params, config)) {
            fee = _fee(_abs(params.amountSpecified), config.hookFeePips);
        }
        // LP fees are input-denominated, even for exact output. Account for the adjusted
        // request, static/protocol fee, price limit, and every canonical rounding step.
        uint256 bound =
            V4FeeLiquidityLockerV2(config.liquidityLocker).inputFeeBound(key, params, fee);
        _checkpointLockerFees(key, params.zeroForOne ? bound : 0, params.zeroForOne ? 0 : bound);
        // Oracle cadence is independent of fee amount, mode, or the specified currency.
        _recordBeforeSwap(id);
        if (fee != 0) _accrue(id, specified, fee, config.protocolFeeDenominator);
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(int256(fee) << 128), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReadReentrant nonFeeReentrant returns (bytes4, int128) {
        bytes32 id = _initializedPool(key);
        // Swap-driven LP fee growth is checkpointed immediately on every swap (audit H1),
        // independent of hook fee amount, mode, or the specified currency.
        _checkpointLockerFees(key, 0, 0);
        PoolConfig storage config = _configs[id];
        Currency specified = _specifiedCurrency(key, params);
        Currency unspecified = Currency.unwrap(specified) == Currency.unwrap(key.currency0)
            ? key.currency1
            : key.currency0;
        if (config.hookFeePips != 0 && _isFeeCurrency(specified, key, params, config)) {
            // Reconciliation of the precharged specified fee (audit M1): the AMM was asked to
            // fill `amountSpecified + fee`. Only a complete fill of that adjusted amount is
            // admissible when a nonzero fee was actually precharged; a fee that rounds to zero
            // precharged nothing, so a partial fill stays admissible and unpaid.
            uint256 precharged = _fee(_abs(params.amountSpecified), config.hookFeePips);
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
        if (config.hookFeePips == 0 || !_isFeeCurrency(unspecified, key, params, config)) {
            return (this.afterSwap.selector, 0);
        }
        int128 amount = Currency.unwrap(unspecified) == Currency.unwrap(key.currency0)
            ? delta.amount0()
            : delta.amount1();
        uint256 fee = _fee(_abs(int256(amount)), config.hookFeePips);
        if (fee != 0) _accrue(id, unspecified, fee, config.protocolFeeDenominator);
        return (this.afterSwap.selector, int128(uint128(fee)));
    }

    /// @notice Donations are LP-fee growth events on locker positions (audit H1): the growth is
    ///         checkpointed immediately after the pool applies it. Donations remain excluded
    ///         from hook fee liabilities.
    function beforeDonate(
        address,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external onlyPoolManager nonReadReentrant nonFeeReentrant returns (bytes4) {
        // Donations accrue in their own currency; each positive manager delta is int128-cast.
        _checkpointLockerFees(key, amount0, amount1);
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        nonFeeReentrant
        nonReadReentrant
        returns (bytes4)
    {
        _checkpointLockerFees(key, 0, 0);
        return this.afterDonate.selector;
    }

    /// @notice Truncated quote-per-base tick and liquidity cumulatives for this full PoolId.
    /// @dev Exact boundaries, interpolation, counterfactual newest values, and uint32 wraparound
    ///      are inherited unchanged from TruncatedOracle. Older-than-genesis reads fail closed.
    function observeTruncated(bytes32 id, uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        OracleState storage state = oracleState[id];
        if (state.cardinality == 0) revert TruncatedOracle.InvalidObservationState();
        return observations[id].observe(
            uint32(block.timestamp),
            secondsAgos,
            state.tick,
            state.index,
            StateLibrary.getLiquidity(poolManager, PoolId.wrap(id)),
            state.cardinality
        );
    }

    /// @notice Permissionless, monotonic preparation capped by the registration snapshot.
    /// @dev Prepared slots remain uninitialized until subsequent canonical records populate them.
    function increaseObservationCardinalityNext(bytes32 id, uint16 requested)
        external
        nonReadReentrant
    {
        OracleState storage state = oracleState[id];
        if (requested > state.cardinalityCap) requested = state.cardinalityCap;
        uint16 oldNext = state.cardinalityNext;
        uint16 newNext = observations[id].grow(oldNext, requested);
        state.cardinalityNext = newNext;
        if (oldNext != newNext) emit IncreaseObservationCardinalityNext(id, oldNext, newNext);
    }

    function oracleInitializedAt(bytes32 id) external view returns (uint256) {
        return oracleState[id].initializedAt;
    }

    /// @notice Redeems only this pool's liabilities, always to its registered collector/treasury.
    /// @dev A zero-liability call is valid; there is no currency-only or alternate payout API.
    function collectFees(PoolKey calldata key)
        external
        nonReentrant
        nonFeeReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 id = _initializedPool(key);
        if (msg.sender != _configs[id].collector) revert Unauthorized();
        if (
            pendingFees[id][Currency.unwrap(key.currency0)] != 0
                || pendingFees[id][Currency.unwrap(key.currency1)] != 0
        ) {
            bytes memory payload = abi.encode(key);
            _unlockContext = keccak256(payload);
            bytes memory result = poolManager.unlock(payload);
            if (_unlockContext != bytes32(0)) revert InvalidCallback();
            (amount0, amount1) = abi.decode(result, (uint256, uint256));
        }
        emit FeesCollected(id, msg.sender, amount0, amount1);
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
        bytes32 id = PoolId.unwrap(key.toId());
        uint256 amount0 = _redeem(id, key.currency0);
        uint256 amount1 = _redeem(id, key.currency1);
        return abi.encode(amount0, amount1);
    }

    function _validateRegistration(PoolKey calldata key, PoolConfig calldata config, bytes32 id)
        private
        view
    {
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        address quote = Currency.unwrap(config.quoteCurrency);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(id));
        if (
            address(key.hooks) != address(this) || asset0 == address(0) || asset0 >= asset1
                || asset0.code.length == 0 || asset1.code.length == 0
                || key.fee > LPFeeLibrary.MAX_LP_FEE || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING || sqrtPriceX96 != 0
                || config.hookFeePips > PIPS_DENOMINATOR || (quote != asset0 && quote != asset1)
                || (config.protocolFeeDenominator != 0
                    && (config.protocolFeeDenominator < 4 || config.protocolFeeDenominator > 10))
                || (config.protocolFeeDenominator != 0 && config.treasury == address(0))
                || config.collector.code.length == 0 || config.liquidityLocker.code.length == 0
                || config.collector == config.liquidityLocker || config.collector == address(this)
                || config.collector == address(poolManager)
                || config.liquidityLocker == address(this)
                || config.liquidityLocker == address(poolManager)
        ) revert InvalidConfiguration();
        ISharedLaunchFeeCollectorV2 collector = ISharedLaunchFeeCollectorV2(config.collector);
        address hub = collector.hub();
        address[] memory sourceAssets = collector.assets();
        if (
            address(collector.poolManager()) != address(poolManager)
                || address(collector.locker()) != config.liquidityLocker || collector.poolId() != id
                || keccak256(abi.encode(collector.poolKey())) != id
                || address(V4FeeLiquidityLockerV2(config.liquidityLocker).poolManager())
                    != address(poolManager) || sourceAssets.length != 2 || sourceAssets[0] != asset0
                || sourceAssets[1] != asset1 || hub.code.length == 0 || hub == address(this)
                || hub == config.collector || hub == config.liquidityLocker
                || hub == address(poolManager) || hub == asset0 || hub == asset1
                || config.treasury == address(this) || config.treasury == config.collector
                || config.treasury == config.liquidityLocker
                || config.treasury == address(poolManager) || config.treasury == hub
        ) revert InvalidConfiguration();
    }

    function _initializedPool(PoolKey calldata key) private view returns (bytes32 id) {
        id = PoolId.unwrap(key.toId());
        if (!initialized[id] || address(key.hooks) != address(this)) revert InvalidPool();
    }

    function _validateLiquidityCaller(address sender, bytes32 id) private view {
        PoolConfig storage config = _configs[id];
        // Audit M2: before the registrar completes the terminal opening, only the registered
        // locker may add liquidity, so quote-only foreign LP cannot seed an uncommitted opening.
        // After completion the pool's frozen externalLiquidityDisabled policy applies unchanged.
        if (_openingCompletedAt[id] == 0) {
            if (sender != config.liquidityLocker) revert OpeningNotComplete();
        } else if (config.externalLiquidityDisabled && sender != config.liquidityLocker) {
            revert ExternalLiquidityDisabled();
        }
    }

    /// @dev LP fee growth checkpoint into the registered V2 locker (audit H1 + H1-ROUNDING-01).
    ///      Runs inside this active manager callback after every swap and donation with a zero
    ///      incoming bound (parking only at the threshold), and before swaps/donations with the
    ///      event's maximum single-position fee bound so accrued growth can never reach the
    ///      signed int128 cast limit. Pools whose locker has no positions yet are skipped.
    function _checkpointLockerFees(PoolKey calldata key, uint256 bound0, uint256 bound1) private {
        bytes32 id = PoolId.unwrap(key.toId());
        address locker = _configs[id].liquidityLocker;
        if (V4FeeLiquidityLockerV2(locker).positionCount(id) == 0) return;
        _feeCheckpointActive = true;
        (uint256 amount0, uint256 amount1) =
            V4FeeLiquidityLockerV2(locker).checkpointFees(key, bound0, bound1);
        _feeCheckpointActive = false;
        emit LpFeesCheckpointed(id, locker, amount0, amount1);
    }

    function _quoteIsCurrency0(bytes32 id) private view returns (bool) {
        return Currency.unwrap(_configs[id].quoteCurrency) == Currency.unwrap(_keys[id].currency0);
    }

    /// @dev The same-block exit precedes manager reads. Record the previously persisted tick and
    ///      pre-swap liquidity, then clamp toward the normalized pre-swap spot, never the result.
    function _recordBeforeSwap(bytes32 id) private {
        if (block.number == oracleState[id].lastBlock) return;
        PoolId pool = PoolId.wrap(id);
        (, int24 spotTick,,) = StateLibrary.getSlot0(poolManager, pool);
        _record(id, spotTick, StateLibrary.getLiquidity(poolManager, pool));
    }

    function _recordBeforeLiquidityChange(bytes32 id, ModifyLiquidityParams calldata params)
        private
    {
        if (params.liquidityDelta == 0 || block.number == oracleState[id].lastBlock) return;
        PoolId pool = PoolId.wrap(id);
        (, int24 spotTick,,) = StateLibrary.getSlot0(poolManager, pool);
        if (spotTick < params.tickLower || spotTick >= params.tickUpper) return;
        _record(id, spotTick, StateLibrary.getLiquidity(poolManager, pool));
    }

    function _record(bytes32 id, int24 spotTick, uint128 activeLiquidity) private {
        OracleState storage state = oracleState[id];
        (state.index, state.cardinality) = observations[id].write(
            state.index,
            uint32(block.timestamp),
            state.tick,
            activeLiquidity,
            state.cardinality,
            state.cardinalityNext
        );
        state.tick = TruncatedOracle.nextTruncatedTick(
            state.tick, spotTick, state.maxAbsTickMove, _quoteIsCurrency0(id)
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

    function _fee(uint256 amount, uint24 pips) private pure returns (uint256 fee) {
        fee = FixedPointMathLib.fullMulDiv(amount, pips, PIPS_DENOMINATOR);
        if (fee > uint256(uint128(type(int128).max))) revert FeeTooLarge();
    }

    function _abs(int256 amount) private pure returns (uint256) {
        if (amount == type(int256).min) revert FeeTooLarge();
        return uint256(amount < 0 ? -amount : amount);
    }

    function _accrue(bytes32 id, Currency currency, uint256 amount, uint8 denominator)
        private
        nonReentrant
    {
        address asset = Currency.unwrap(currency);
        uint256 claims = pendingFees[id][asset] - settledFees[id][asset];
        if (amount > MAX_MANAGER_DELTA - claims) _settleClaims(id, currency, claims);
        uint256 treasury = denominator == 0 ? 0 : (amount / denominator) * 125 / 100;
        pendingFees[id][asset] += amount;
        pendingTreasurySweeps[id][asset] += treasury;
        aggregateLiabilities[asset] += amount;
        aggregateManagerClaims[asset] += amount;
        uint256 beforeClaims = poolManager.balanceOf(address(this), uint160(asset));
        poolManager.mint(address(this), uint160(asset), amount);
        uint256 afterClaims = poolManager.balanceOf(address(this), uint160(asset));
        if (
            afterClaims < beforeClaims || afterClaims - beforeClaims != amount
                || afterClaims < aggregateManagerClaims[asset]
        ) revert ClaimMismatch();
        emit FeeAccrued(id, asset, amount, treasury);
    }

    function _redeem(bytes32 id, Currency currency) private returns (uint256 net) {
        address asset = Currency.unwrap(currency);
        uint256 gross = pendingFees[id][asset];
        if (gross == 0) return 0;
        _settleClaims(id, currency, gross - settledFees[id][asset]);
        uint256 treasury = pendingTreasurySweeps[id][asset];
        pendingFees[id][asset] = 0;
        pendingTreasurySweeps[id][asset] = 0;
        settledFees[id][asset] = 0;
        aggregateLiabilities[asset] -= gross;
        PoolConfig storage config = _configs[id];
        net = gross - treasury;
        _transferExact(asset, config.treasury, treasury);
        _transferExact(asset, config.collector, net);
    }

    /// @dev Cap each pool/currency's manager-backed liability at int128.max. Large separately
    ///      settled accruals move into ERC20 custody without paying the collector early. A later
    ///      callback may have temporarily taken the manager's cash: require repayment/settlement
    ///      before another oversized unpaid batch, rather than assuming old claims are liquid.
    function _settleClaims(bytes32 id, Currency currency, uint256 claims) private {
        if (claims == 0) return;
        address asset = Currency.unwrap(currency);
        if (SafeTransferLib.balanceOf(asset, address(poolManager)) < claims) {
            revert FeeSettlementRequired();
        }
        aggregateManagerClaims[asset] -= claims;
        _burnExact(asset, claims);
        _takeExact(currency, address(this), claims);
        settledFees[id][asset] += claims;
    }

    function _burnExact(address asset, uint256 amount) private {
        uint256 beforeClaims = poolManager.balanceOf(address(this), uint160(asset));
        poolManager.burn(address(this), uint160(asset), amount);
        uint256 afterClaims = poolManager.balanceOf(address(this), uint160(asset));
        if (
            afterClaims > beforeClaims || beforeClaims - afterClaims != amount
                || afterClaims < aggregateManagerClaims[asset]
        ) revert ClaimMismatch();
    }

    function _takeExact(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        address asset = Currency.unwrap(currency);
        uint256 beforeManager = SafeTransferLib.balanceOf(asset, address(poolManager));
        uint256 beforeRecipient = SafeTransferLib.balanceOf(asset, recipient);
        poolManager.take(currency, recipient, amount);
        uint256 afterManager = SafeTransferLib.balanceOf(asset, address(poolManager));
        uint256 afterRecipient = SafeTransferLib.balanceOf(asset, recipient);
        if (
            afterManager > beforeManager || beforeManager - afterManager != amount
                || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount
        ) revert InexactTransfer();
    }

    function _transferExact(address asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeSource = SafeTransferLib.balanceOf(asset, address(this));
        uint256 beforeRecipient = SafeTransferLib.balanceOf(asset, recipient);
        SafeTransferLib.safeTransfer(asset, recipient, amount);
        uint256 afterSource = SafeTransferLib.balanceOf(asset, address(this));
        uint256 afterRecipient = SafeTransferLib.balanceOf(asset, recipient);
        if (
            afterSource > beforeSource || beforeSource - afterSource != amount
                || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount
        ) revert InexactTransfer();
    }
}
