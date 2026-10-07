// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { ProtocolFeeLibrary } from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { FixedPoint128 } from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Permanently holds up to 32 positions per pool behind a sealed, collector-only boundary.
/// @dev There is deliberately no withdrawal, public partial claim, recipient change, or unseal.
///      V2 adds hook-guarded, headroom-driven LP fee checkpoints (audit H1). Each pool/currency
///      retains at most int128.max manager claims; before exceeding that accounting boundary,
///      old claims must be settled into tracked ERC20 custody. Temporarily unavailable manager
///      cash requires the unlocked caller to repay/settle and retry. This is not a supply cap.
///      Principal custody and the historical V1 locker and its consumers are unchanged.
contract V4FeeLiquidityLockerV2 is IUnlockCallback, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    error Unauthorized();
    error InvalidConfiguration();
    error AlreadyLocked();
    error PoolSealed();
    error PoolNotSealed();
    error SlippageExceeded();
    error InvalidCallback();
    error InexactTransfer();
    error PoolNotInitialized();
    error NothingToCheckpoint();
    error CheckpointMismatch();
    error FeeSettlementRequired();

    uint256 public constant MAX_POSITIONS = 32;
    uint256 private constant MAX_MANAGER_DELTA = uint256(uint128(type(int128).max));
    uint256 private constant PIPS_DENOMINATOR = 1_000_000;

    /// @dev Parking threshold: once estimated owed fees reach this fraction of the signed int128
    ///      cast bound they are poked and parked proactively, well before the cast limit.
    uint256 private constant CHECKPOINT_THRESHOLD = uint256(uint128(type(int128).max)) / 2;
    uint256 private constant Q128 = FixedPoint128.Q128;

    struct Lock {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        address feeRecipient;
    }

    struct LockParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
        address feeRecipient;
    }

    struct CallbackData {
        PoolKey key;
        bool adding;
        ModifyLiquidityParams params;
    }

    IPoolManager public immutable poolManager;
    address public immutable launcher;
    mapping(bytes32 poolId => uint256 count) public positionCount;
    mapping(bytes32 poolId => mapping(uint256 index => Lock position)) public locks;
    mapping(bytes32 poolId => bool value) public isSealed;
    mapping(bytes32 poolId => address recipient) public feeRecipient;
    mapping(bytes32 poolId => bytes32 configHash) public positionsHash;
    mapping(bytes32 poolId => mapping(address asset => uint256 amount)) private _pendingClaims;
    mapping(bytes32 poolId => mapping(address asset => uint256 amount)) public settledFees;
    mapping(bytes32 poolId => PoolKey key) private _keys;
    mapping(bytes32 poolId => mapping(bytes32 positionKey => bool used)) private _positionKeys;
    bytes32 private _unlockContext;

    event LiquidityPermanentlyLocked(
        bytes32 indexed poolId,
        uint256 indexed positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt,
        uint256 amount0,
        uint256 amount1
    );
    event PoolPermanentlySealed(
        bytes32 indexed poolId, address indexed collector, bytes32 positionsHash
    );
    event FeesClaimed(
        bytes32 indexed poolId,
        uint256 indexed positionIndex,
        address indexed collector,
        uint256 amount0,
        uint256 amount1
    );
    /// @dev Emitted per checkpointed position inside the caller's active manager callback.
    event LpFeesCheckpointed(
        bytes32 indexed poolId, uint256 indexed positionIndex, uint256 amount0, uint256 amount1
    );

    constructor(IPoolManager manager_, address launcher_) {
        if (
            address(manager_).code.length == 0 || launcher_ == address(0)
                || launcher_ == address(manager_) || launcher_ == address(this)
        ) revert InvalidConfiguration();
        poolManager = manager_;
        launcher = launcher_;
    }

    function poolKey(bytes32 id) external view returns (PoolKey memory) {
        return _keys[id];
    }

    function lock(PoolKey calldata key, LockParams calldata position)
        external
        nonReentrant
        returns (uint256 positionIndex, uint256 amount0, uint256 amount1)
    {
        if (msg.sender != launcher) revert Unauthorized();
        _validateKey(key);
        bytes32 id = PoolId.unwrap(key.toId());
        if (isSealed[id]) revert PoolSealed();
        positionIndex = positionCount[id];
        if (
            positionIndex >= MAX_POSITIONS || position.tickLower >= position.tickUpper
                || position.tickLower < TickMath.MIN_TICK || position.tickUpper > TickMath.MAX_TICK
                || position.tickLower % key.tickSpacing != 0
                || position.tickUpper % key.tickSpacing != 0 || position.liquidity == 0
                || position.feeRecipient.code.length == 0 || position.feeRecipient == address(this)
                || position.feeRecipient == address(poolManager)
                || position.feeRecipient == address(key.hooks)
        ) revert InvalidConfiguration();
        bytes32 positionKey =
            keccak256(abi.encode(position.tickLower, position.tickUpper, position.salt));
        if (_positionKeys[id][positionKey]) revert AlreadyLocked();
        if (positionIndex == 0) {
            _keys[id] = key;
            feeRecipient[id] = position.feeRecipient;
        } else if (feeRecipient[id] != position.feeRecipient) {
            revert InvalidConfiguration();
        }
        CallbackData memory action = CallbackData({
            key: key,
            adding: true,
            params: ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(uint256(position.liquidity)),
                salt: position.salt
            })
        });
        (amount0, amount1) = _unlock(action);
        if (amount0 > position.amount0Maximum || amount1 > position.amount1Maximum) {
            revert SlippageExceeded();
        }
        locks[id][positionIndex] = Lock(
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.salt,
            position.feeRecipient
        );
        _positionKeys[id][positionKey] = true;
        positionCount[id] = positionIndex + 1;
        emit LiquidityPermanentlyLocked(
            id,
            positionIndex,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.salt,
            amount0,
            amount1
        );
    }

    /// @notice Freezes the complete pool-local position set and its one collector recipient.
    function sealPool(PoolKey calldata key) external nonReentrant {
        if (msg.sender != launcher) revert Unauthorized();
        bytes32 id = PoolId.unwrap(key.toId());
        if (isSealed[id]) revert PoolSealed();
        _validatePositions(key, id);
        bytes32 configHash;
        for (uint256 i; i < positionCount[id]; ++i) {
            configHash = keccak256(abi.encode(configHash, i, locks[id][i]));
        }
        positionsHash[id] = configHash;
        isSealed[id] = true;
        emit PoolPermanentlySealed(id, feeRecipient[id], configHash);
    }

    /// @notice Checks sealed custody against actual PoolManager position liquidity.
    function validatePool(PoolKey calldata key) external view {
        bytes32 id = PoolId.unwrap(key.toId());
        if (!isSealed[id]) revert PoolNotSealed();
        _validatePositions(key, id);
    }

    /// @notice Pool-local collectible LP fees, including manager claims and settled ERC20 custody.
    function pendingClaims(bytes32 poolId, address asset) external view returns (uint256) {
        return _pendingClaims[poolId][asset];
    }

    /// @notice Only the sealed collector can claim, and every bound position is always included.
    /// @dev Poke each position once, settle int128-bounded groups of fresh fee credit, and
    ///      transfer all tracked ERC20 fees once per currency. No amount-proportional chunks.
    function claimFees(PoolKey calldata key)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        if (!isSealed[id]) revert PoolNotSealed();
        if (msg.sender != feeRecipient[id]) revert Unauthorized();
        CallbackData memory action;
        action.key = key;
        return _unlock(action);
    }

    function _unlock(CallbackData memory action)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory payload = abi.encode(action);
        _unlockContext = keccak256(payload);
        bytes memory result = poolManager.unlock(payload);
        if (_unlockContext != bytes32(0)) revert InvalidCallback();
        return abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (_unlockContext == bytes32(0) || keccak256(data) != _unlockContext) {
            revert InvalidCallback();
        }
        _unlockContext = bytes32(0);
        CallbackData memory action = abi.decode(data, (CallbackData));
        if (action.adding) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(action.key, action.params, "");
            uint256 amount0 = _debt(delta.amount0());
            uint256 amount1 = _debt(delta.amount1());
            _payExact(action.key.currency0, amount0);
            _payExact(action.key.currency1, amount1);
            return abi.encode(amount0, amount1);
        }
        bytes32 id = PoolId.unwrap(action.key.toId());
        uint256 credit0;
        uint256 credit1;
        for (uint256 i; i < positionCount[id]; ++i) {
            (uint256 amount0, uint256 amount1) = _checkpointPosition(action.key, id, i);
            credit0 = _addFeeCredit(id, action.key.currency0, credit0, amount0);
            credit1 = _addFeeCredit(id, action.key.currency1, credit1, amount1);
            emit FeesClaimed(id, i, feeRecipient[id], amount0, amount1);
        }
        _settleFeeCredit(id, action.key.currency0, credit0);
        _settleFeeCredit(id, action.key.currency1, credit1);
        return abi.encode(
            _redeemParked(id, action.key.currency0), _redeemParked(id, action.key.currency1)
        );
    }

    /// @dev The fresh credit is bounded by the fixed position count, unlike lifetime claims.
    ///      Grouping it avoids per-position ERC6909 mint/burn and ERC20 transfers at collection.
    function _addFeeCredit(bytes32 id, Currency currency, uint256 credit, uint256 amount)
        private
        returns (uint256)
    {
        if (amount > MAX_MANAGER_DELTA - credit) {
            _settleFeeCredit(id, currency, credit);
            return amount;
        }
        return credit + amount;
    }

    function _settleFeeCredit(bytes32 id, Currency currency, uint256 credit) private {
        if (credit == 0) return;
        address asset = Currency.unwrap(currency);
        _takeExact(currency, address(this), credit);
        _pendingClaims[id][asset] += credit;
        settledFees[id][asset] += credit;
    }

    /// @notice Hook-root checkpoint of accrued LP fees, executed inside the caller's active
    ///         manager callback with no nested unlock. Event-bound and headroom-driven
    ///         (audit H1 + H1-ROUNDING-01).
    /// @dev Guards: only the pool's hook contract (`key.hooks`) may call, the pool must be
    ///      initialized, and recorded lock membership must match actual manager liquidity.
    ///      `bound0`/`bound1` bound this event's input-denominated LP fee exposure in each
    ///      currency. A position is poked only if its existing fee plus the corresponding
    ///      bound threatens the signed cast, or its integer owed fee reaches the parking
    ///      threshold. Smaller growth remains in the canonical accumulator between pokes.
    function checkpointFees(PoolKey calldata key, uint256 bound0, uint256 bound1)
        external
        nonReentrant
        returns (uint256 total0, uint256 total1)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        if (msg.sender != address(key.hooks)) revert Unauthorized();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(id));
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        uint256 count = positionCount[id];
        if (count == 0) revert NothingToCheckpoint();
        PoolKey memory checkpointKey = key;
        for (uint256 i; i < count; ++i) {
            if (!_dueForCheckpoint(PoolId.wrap(id), locks[id][i], bound0, bound1)) continue;
            (uint256 amount0, uint256 amount1) = _checkpointPosition(checkpointKey, id, i);
            if (amount0 == 0 && amount1 == 0) continue;
            emit LpFeesCheckpointed(id, i, amount0, amount1);
            total0 += amount0;
            total1 += amount1;
        }
        // Decide rollover from the complete checkpoint, before any current unpaid credit
        // enters the old claim slot. Position order must not force cashing fresh fees.
        _parkFees(id, key.currency0, total0, count);
        _parkFees(id, key.currency1, total1, count);
    }

    /// @dev One locked position's accrued fees: membership check and zero-delta redemption.
    function _checkpointPosition(PoolKey memory key, bytes32 id, uint256 i)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        Lock storage position = locks[id][i];
        if (position.liquidity == 0) revert InvalidConfiguration();
        bytes32 positionKey = Position.calculatePositionKey(
            address(this), position.tickLower, position.tickUpper, position.salt
        );
        if (
            StateLibrary.getPositionLiquidity(poolManager, PoolId.wrap(id), positionKey)
                != position.liquidity
        ) revert InvalidConfiguration();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: 0,
            salt: position.salt
        });
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        amount0 = _credit(delta.amount0());
        amount1 = _credit(delta.amount1());
    }

    /// @dev Poke decision. Estimated owed fees use fullMulDiv over the canonical position
    ///      accumulator delta (current feeGrowthInside minus the position's cached last value)
    ///      scaled by uint128 liquidity — the same quantity `Position.update` floors, so the
    ///      estimate can never overstate the floored poke by more than the sub-unit remainder.
    ///      Poke when (a) estimated owed + this event's max incoming fee + one raw unit reaches
    ///      the signed int128 cast limit — the unfloored accrual is then guaranteed to stay
    ///      within it, so a later poke (including claimFees) can never SafeCastOverflow — or
    ///      (b) estimated owed has reached the parking threshold.
    function _dueForCheckpoint(PoolId pool, Lock storage position, uint256 bound0, uint256 bound1)
        private
        view
        returns (bool)
    {
        (uint128 liquidity, uint256 growthInside0LastX128, uint256 growthInside1LastX128) = StateLibrary.getPositionInfo(
            poolManager, pool, address(this), position.tickLower, position.tickUpper, position.salt
        );
        if (liquidity != position.liquidity) revert InvalidConfiguration();
        (uint256 growthInside0, uint256 growthInside1) = StateLibrary.getFeeGrowthInside(
            poolManager, pool, position.tickLower, position.tickUpper
        );
        // Canonical Position.update intentionally subtracts modulo 2^256.
        // Global and inside fee growth may wrap while the owed fee remains small.
        uint256 growthDelta0;
        uint256 growthDelta1;
        unchecked {
            growthDelta0 = growthInside0 - growthInside0LastX128;
            growthDelta1 = growthInside1 - growthInside1LastX128;
        }
        uint256 owed0 = FullMath.mulDiv(growthDelta0, liquidity, Q128);
        uint256 owed1 = FullMath.mulDiv(growthDelta1, liquidity, Q128);
        return _needsHeadroom(owed0, bound0) || _needsHeadroom(owed1, bound1);
    }

    function _needsHeadroom(uint256 owed, uint256 incoming) private pure returns (bool) {
        uint256 limit = incoming >= MAX_MANAGER_DELTA - 1 ? 0 : MAX_MANAGER_DELTA - 1 - incoming;
        return owed > limit || owed >= CHECKPOINT_THRESHOLD;
    }

    /// @dev Upper bound on input-currency LP fees, never an output-unit proxy. Each
    /// canonical step charges ceil(grossInput * swapFee / 1e6); summing ceilings adds
    /// at most one unit per step. Protocol extraction only reduces this LP exposure.
    /// Across the price interval, usable liquidity is at most uint128.max, so its
    /// input integral plus one rounding unit per tick-grid step bounds net input.
    /// Intersect that price-limited bound with the signed manager input ceiling
    /// (and adjusted exact-input request). No pool state is simulated or mutated.
    function inputFeeBound(PoolKey calldata key, SwapParams calldata params, uint256 precharged)
        external
        view
        returns (uint256 bound)
    {
        (uint160 spot,, uint24 packedProtocol, uint24 lpFee) =
            StateLibrary.getSlot0(poolManager, key.toId());
        if (lpFee == 0 || params.amountSpecified == 0) return 0;
        uint16 protocol = params.zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(packedProtocol)
            : ProtocolFeeLibrary.getOneForZeroFee(packedProtocol);
        uint24 swapFee =
            protocol == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(protocol, lpFee);
        uint256 gross = MAX_MANAGER_DELTA + 1; // negative int128.min is valid manager input
        if (params.amountSpecified < 0) {
            uint256 requested = uint256(-params.amountSpecified) - precharged;
            if (requested < gross) gross = requested;
        }
        if (swapFee == PIPS_DENOMINATOR) return gross;
        // Each visited bitmap boundary is on this grid, including uninitialized boundaries.
        uint256 steps = uint256(uint24(TickMath.MAX_TICK - TickMath.MIN_TICK))
            / uint256(uint24(key.tickSpacing)) + 2;
        bound = FullMath.mulDivRoundingUp(gross, swapFee, PIPS_DENOMINATOR) + steps;
        if (bound > gross) bound = gross;
        uint256 netInput = params.zeroForOne
            ? SqrtPriceMath.getAmount0Delta(params.sqrtPriceLimitX96, spot, type(uint128).max, true)
            : SqrtPriceMath.getAmount1Delta(spot, params.sqrtPriceLimitX96, type(uint128).max, true);
        uint256 priceBound = FullMath.mulDivRoundingUp(
            netInput + steps, swapFee, PIPS_DENOMINATOR - swapFee
        ) + steps;
        if (priceBound < bound) bound = priceBound;
    }

    function _parkFees(bytes32 id, Currency currency, uint256 amount, uint256 count) private {
        if (amount == 0) return;
        address asset = Currency.unwrap(currency);
        uint256 claims = _pendingClaims[id][asset] - settledFees[id][asset];
        if (amount > MAX_MANAGER_DELTA - claims) _settleParked(id, currency, claims);
        // A checkpoint can cover old accrual on several positions. Cash only its excess
        // over one safe claim slot; these groups are bounded by the position count.
        for (uint256 i; i < count && amount > MAX_MANAGER_DELTA; ++i) {
            uint256 excess = amount - MAX_MANAGER_DELTA;
            uint256 chunk = excess > MAX_MANAGER_DELTA ? MAX_MANAGER_DELTA : excess;
            if (SafeTransferLib.balanceOf(asset, address(poolManager)) < chunk) {
                revert FeeSettlementRequired();
            }
            _settleFeeCredit(id, currency, chunk);
            amount -= chunk;
        }
        _pendingClaims[id][asset] += amount;
        _mintExact(currency, amount);
    }

    /// @dev A backed ERC6909 claim does not imply transferable cash during an unlock: any
    ///      caller can take that cash temporarily. Do not grow an oversized unpaid batch or
    ///      loop over redemption chunks; require repayment/settlement before retry instead.
    function _settleParked(bytes32 id, Currency currency, uint256 claims) private {
        if (claims == 0) return;
        address asset = Currency.unwrap(currency);
        if (SafeTransferLib.balanceOf(asset, address(poolManager)) < claims) {
            revert FeeSettlementRequired();
        }
        _burnExact(currency, claims);
        _takeExact(currency, address(this), claims);
        settledFees[id][asset] += claims;
    }

    function _redeemParked(bytes32 id, Currency currency) private returns (uint256 total) {
        address asset = Currency.unwrap(currency);
        total = _pendingClaims[id][asset];
        if (total == 0) return 0;
        _settleParked(id, currency, total - settledFees[id][asset]);
        _pendingClaims[id][asset] = 0;
        settledFees[id][asset] = 0;
        _transferExact(asset, feeRecipient[id], total);
    }

    function _mintExact(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        uint160 claimId = uint160(Currency.unwrap(currency));
        uint256 beforeClaims = poolManager.balanceOf(address(this), claimId);
        poolManager.mint(address(this), claimId, amount);
        uint256 afterClaims = poolManager.balanceOf(address(this), claimId);
        if (afterClaims <= beforeClaims || afterClaims - beforeClaims != amount) {
            revert CheckpointMismatch();
        }
    }

    function _burnExact(Currency currency, uint256 amount) private {
        uint160 claimId = uint160(Currency.unwrap(currency));
        uint256 beforeClaims = poolManager.balanceOf(address(this), claimId);
        poolManager.burn(address(this), claimId, amount);
        uint256 afterClaims = poolManager.balanceOf(address(this), claimId);
        if (afterClaims > beforeClaims || beforeClaims - afterClaims != amount) {
            revert CheckpointMismatch();
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
        if (
            afterManager > beforeManager || beforeManager - afterManager != amount
                || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount
        ) revert InexactTransfer();
    }

    function _transferExact(address asset, address recipient, uint256 amount) private {
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

    function _validateKey(PoolKey calldata key) private view {
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (
            asset0 == address(0) || asset0 >= asset1 || asset0.code.length == 0
                || asset1.code.length == 0 || key.fee > LPFeeLibrary.MAX_LP_FEE
                || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING || sqrtPriceX96 == 0
        ) revert InvalidConfiguration();
    }

    function _validatePositions(PoolKey calldata key, bytes32 id) private view {
        _validateKey(key);
        uint256 count = positionCount[id];
        if (count == 0 || count > MAX_POSITIONS || feeRecipient[id] == address(0)) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < count; ++i) {
            Lock storage position = locks[id][i];
            bytes32 positionKey = Position.calculatePositionKey(
                address(this), position.tickLower, position.tickUpper, position.salt
            );
            uint128 liquidity =
                StateLibrary.getPositionLiquidity(poolManager, PoolId.wrap(id), positionKey);
            if (
                position.liquidity == 0 || liquidity != position.liquidity
                    || position.feeRecipient != feeRecipient[id]
            ) revert InvalidConfiguration();
        }
    }

    function _payExact(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        address asset = Currency.unwrap(currency);
        uint256 beforeManager = SafeTransferLib.balanceOf(asset, address(poolManager));
        uint256 beforeLauncher = SafeTransferLib.balanceOf(asset, launcher);
        poolManager.sync(currency);
        SafeTransferLib.safeTransferFrom(asset, launcher, address(poolManager), amount);
        if (poolManager.settle() != amount) revert InexactTransfer();
        uint256 afterManager = SafeTransferLib.balanceOf(asset, address(poolManager));
        uint256 afterLauncher = SafeTransferLib.balanceOf(asset, launcher);
        if (
            afterManager < beforeManager || afterManager - beforeManager != amount
                || afterLauncher > beforeLauncher || beforeLauncher - afterLauncher != amount
        ) revert InexactTransfer();
    }

    function _credit(int128 delta) private pure returns (uint256) {
        if (delta < 0) revert InvalidConfiguration();
        return uint256(uint128(delta));
    }

    function _debt(int128 delta) private pure returns (uint256) {
        if (delta > 0) revert InvalidConfiguration();
        return uint256(-int256(delta));
    }
}
