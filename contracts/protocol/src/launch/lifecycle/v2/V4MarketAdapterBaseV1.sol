// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { ILaunchHookV1 } from "../../../hooks/v4/authoring/ILaunchHookV1.sol";
import { V4FeeCollectorV2 } from "../../fees/v2/V4FeeCollectorV2.sol";
import { V4FeeLiquidityLockerV2 } from "../../fees/v2/V4FeeLiquidityLockerV2.sol";
import { ILaunchFeeHubV3 } from "../../fees/v3/ILaunchFeeHubV3.sol";
import { ILaunchMarketAdapterV1, ILaunchLifecycleV1 } from "../v1/ILaunchLifecycleV1.sol";
import { MarketConfigV1, InitialBuyV1, MarketIdentityV1, PreparedMarketV1, PositionIdentityV1,
    LaunchVenueV1, LaunchOperationV1, LaunchExecutionContextV1, MarketLiveStateV1,
    LaunchCapabilitiesV1 } from "../v1/LaunchTypesV1.sol";
import { V4PositionConfigV1 } from "../v1/V4MarketConfigV2.sol";
import { ILaunchRegistryV2 } from "./ILaunchRegistryV2.sol";
import { V4MarketConfigV4 } from "./V4MarketConfigV4.sol";
import { PoolFeeCollectorFactoryV1 } from "./PoolFeeCollectorFactoryV1.sol";

/// @notice New-version ordinary-call lifecycle, sharing the original exact canonical
///         execution/custody logic across admitted topologies, not hook storage.
/// @dev No pool gate: pending direct manager manipulation fails continuity and remains
///      cancellable through the unchanged adapter-independent core cancellation path.
abstract contract V4MarketAdapterBaseV1 is ILaunchMarketAdapterV1, IUnlockCallback, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    error Unauthorized();
    error InvalidConfiguration();
    error InvalidMarket();
    error InvalidCallback();
    error QuoteDebtForbidden();
    error SlippageExceeded();
    error InexactTransfer();

    struct MarketState {
        PoolKey key;
        address token;
        address feeSource;
        bytes32 commitment;
        bytes32 canonicalId;
        bytes32 adapterId;
        uint160 openingSqrtPriceX96;
        uint256 tokenBudget;
        uint32 positionCount;
        uint32 configVersion;
        bool prepared;
        bool minted;
        bool activated;
        bytes32 committedPoolState;
    }
    struct BuyCallback { PoolKey key; address token; address recipient; SwapParams params; bytes32 stateBefore; }
    struct TokenEdge { address token; address caller; address from; address to; uint256 amount; }
    struct MarketReference { bytes32 launchId; uint32 indexPlusOne; }

    address public immutable override core;
    IPoolManager public immutable poolManager;
    V4FeeLiquidityLockerV2 public immutable locker;
    PoolFeeCollectorFactoryV1 public immutable collectorFactory;
    ILaunchRegistryV2 public immutable implementationRegistry;
    bytes32 public immutable PROFILE_ID;
    bytes32 private immutable _collectorFactoryCodeHash;
    mapping(bytes32 => mapping(uint32 => MarketState)) private _markets;
    mapping(bytes32 => bytes32) private _poolIdByMarketId;
    mapping(bytes32 => MarketReference) private _marketIndexOfCanonicalId;
    bytes32 private _unlockContext;
    TokenEdge private _tokenEdge;

    constructor(address core_, IPoolManager manager_, V4FeeLiquidityLockerV2 locker_,
        PoolFeeCollectorFactoryV1 helper_, ILaunchRegistryV2 registry_, bytes32 profileId_)
    {
        if (core_ == address(0) || core_ == address(this) || address(manager_).code.length == 0
            || address(locker_).code.length == 0 || address(helper_).code.length == 0
            || address(registry_).code.length == 0 || registry_.core() != core_ || profileId_ == bytes32(0)
            || address(locker_.poolManager()) != address(manager_) || locker_.launcher() != address(this)) {
            revert InvalidConfiguration();
        }
        core = core_;
        poolManager = manager_;
        locker = locker_;
        collectorFactory = helper_;
        implementationRegistry = registry_;
        PROFILE_ID = profileId_;
        _collectorFactoryCodeHash = address(helper_).codehash;
    }
    modifier onlyCore() { if (msg.sender != core) revert Unauthorized(); _; }

    function dependencyDigest() external view override returns (bytes32) {
        if (address(collectorFactory).codehash != _collectorFactoryCodeHash) revert InvalidConfiguration();
        return collectorFactory.dependencyDigest(address(this));
    }

    function _resolveConfiguration(address token, MarketConfigV1 calldata market)
        internal view virtual returns (V4MarketConfigV4 memory config, PoolKey memory key);
    function _prepareConfiguration(address token, MarketConfigV1 calldata market)
        internal virtual returns (V4MarketConfigV4 memory config, PoolKey memory key);

    function resolve(bytes32, address token, MarketConfigV1 calldata market)
        external view override returns (MarketIdentityV1 memory)
    {
        (V4MarketConfigV4 memory config, PoolKey memory key) = _resolveConfiguration(token, market);
        return _identity(key, config.sqrtPriceX96);
    }

    function prepareMarket(bytes32 launchId, uint32 index, address token, address hub, MarketConfigV1 calldata market)
        external override onlyCore nonReentrant returns (PreparedMarketV1 memory prepared)
    {
        _requireContext(launchId, index, LaunchOperationV1.Prepare, address(this));
        MarketState storage state = _markets[launchId][index];
        if (state.prepared) revert InvalidMarket();
        (V4MarketConfigV4 memory config, PoolKey memory key, V4FeeCollectorV2 collector) =
            _createSource(token, hub, market);
        prepared.identity = _identity(key, config.sqrtPriceX96);
        prepared.feeSource = address(collector);
        prepared.custody = address(locker);
        prepared.mintExecutor = address(locker);
        prepared.buyExecutor = address(this);
        prepared.positionCount = uint32(config.positions.length);
        prepared.exclusions = new address[](4);
        prepared.exclusions[0] = address(poolManager);
        prepared.exclusions[1] = address(locker);
        prepared.exclusions[2] = address(key.hooks);
        prepared.exclusions[3] = address(collector);
        state.key = key;
        state.token = token;
        state.feeSource = address(collector);
        state.commitment = keccak256(abi.encode(token, market));
        state.canonicalId = prepared.identity.canonicalId;
        state.adapterId = market.adapterId;
        state.configVersion = market.configVersion;
        state.openingSqrtPriceX96 = config.sqrtPriceX96;
        state.tokenBudget = market.tokenBudget;
        state.positionCount = prepared.positionCount;
        state.prepared = true;
        _poolIdByMarketId[state.canonicalId] = PoolId.unwrap(key.toId());
        _marketIndexOfCanonicalId[state.canonicalId] = MarketReference(launchId, index + 1);
    }

    function _createSource(address token, address hub, MarketConfigV1 calldata market)
        private returns (V4MarketConfigV4 memory config, PoolKey memory key, V4FeeCollectorV2 collector)
    {
        collectorFactory.validateHub(address(this), hub, token);
        (config, key) = _prepareConfiguration(token, market);
        bytes32 id = PoolId.unwrap(key.toId());
        ILaunchHookV1 root = ILaunchHookV1(address(key.hooks));
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (price != 0 || root.registered(id) || locker.positionCount(id) != 0 || locker.isSealed(id)) revert InvalidMarket();
        collector = collectorFactory.create(hub, locker, key, config.positions.length);
        root.registerPool(key, ILaunchHookV1.PoolConfig({
            collector: address(collector), liquidityLocker: address(locker), quoteCurrency: Currency.wrap(market.quoteAsset),
            feeMode: ILaunchHookV1.FeeMode(config.feeMode), hookFeePips: config.hookFeePips,
            protocolFeeDenominator: config.protocolFeeDenominator, treasury: config.treasury,
            externalLiquidityDisabled: config.externalLiquidityDisabled, oracleConfigId: config.oracleConfigId
        }));
        poolManager.initialize(key, config.sqrtPriceX96);
        // Source is real but not yet sealed: canonical sourceId is authenticated only by
        // unchanged core finalization, after every permanent position exists.
        if (config.developerBeneficiary == hub || config.developerBeneficiary == address(collector)) revert InvalidConfiguration();
        ILaunchFeeHubV3(hub).bindSourceTerms(address(collector), PROFILE_ID, config.termsDigest, config.developerFeeBps);
    }

    function validatePrepared(bytes32 launchId, uint32 index, address token, MarketConfigV1 calldata market,
        MarketIdentityV1 calldata identity) external view override
    {
        MarketState storage state = _requireMarket(launchId, index, token, market);
        if (state.minted || state.activated || keccak256(abi.encode(identity))
            != keccak256(abi.encode(_identity(state.key, identity.openingSqrtPriceX96)))) revert InvalidMarket();
        _requireEmptyOpening(state);
        ILaunchHookV1.PoolConfig memory binding = ILaunchHookV1(address(state.key.hooks)).poolConfig(PoolId.unwrap(state.key.toId()));
        if (binding.collector != state.feeSource || binding.liquidityLocker != address(locker)) revert InvalidMarket();
    }

    function mintAndLock(bytes32 launchId, uint32 index, address token, MarketConfigV1 calldata market)
        external override onlyCore nonReentrant returns (PositionIdentityV1[] memory positions, uint256 tokenSpent)
    {
        _requireContext(launchId, index, LaunchOperationV1.Mint, address(locker));
        MarketState storage state = _requireMarket(launchId, index, token, market);
        if (state.minted || state.activated) revert InvalidMarket();
        _requireEmptyOpening(state);
        V4MarketConfigV4 memory config = collectorFactory.decodeAndValidate(address(this), token, market);
        uint256 fundedBalance = SafeTransferLib.balanceOf(token, address(this));
        if (fundedBalance < market.tokenBudget) revert InexactTransfer();
        uint256 quoteBefore = SafeTransferLib.balanceOf(market.quoteAsset, address(this));
        positions = new PositionIdentityV1[](config.positions.length);
        SafeTransferLib.safeApproveWithRetry(token, address(locker), market.tokenBudget);
        bool tokenIs0 = token < market.quoteAsset;
        for (uint256 i; i < config.positions.length; ++i) {
            (uint256 positionIndex, uint256 spent) = _lockPosition(state.key, config.positions[i], tokenIs0, state.feeSource);
            if (positionIndex != i) revert InvalidMarket();
            tokenSpent += spent;
            positions[i] = _positionIdentity(state.canonicalId, i, config.positions[i]);
        }
        SafeTransferLib.safeApproveWithRetry(token, address(locker), 0);
        locker.sealPool(state.key);
        if (tokenSpent > market.tokenBudget || SafeTransferLib.balanceOf(token, address(this)) + tokenSpent != fundedBalance
            || SafeTransferLib.balanceOf(market.quoteAsset, address(this)) != quoteBefore) revert QuoteDebtForbidden();
        state.minted = true;
        state.committedPoolState = _poolStateHash(state.key);
        if (_poolPrice(state.key) != state.openingSqrtPriceX96) revert InvalidMarket();
        _sendExact(token, core, market.tokenBudget - tokenSpent);
    }

    function _lockPosition(PoolKey storage key, V4PositionConfigV1 memory p, bool tokenIs0, address source)
        private returns (uint256 positionIndex, uint256 tokenSpent)
    {
        uint256 amount0;
        uint256 amount1;
        (positionIndex, amount0, amount1) = locker.lock(key, V4FeeLiquidityLockerV2.LockParams({
            tickLower: p.tickLower, tickUpper: p.tickUpper, liquidity: p.liquidity, salt: p.salt,
            amount0Maximum: tokenIs0 ? p.maxTokenAmount : 0, amount1Maximum: tokenIs0 ? 0 : p.maxTokenAmount,
            feeRecipient: source
        }));
        tokenSpent = tokenIs0 ? amount0 : amount1;
    }

    function executeBuy(bytes32 launchId, uint32 index, address token, MarketConfigV1 calldata market, InitialBuyV1 calldata buy)
        external override onlyCore nonReentrant returns (uint256 quoteSpent, uint256 tokenOut)
    {
        _requireContext(launchId, index, LaunchOperationV1.Buy, address(this));
        MarketState storage state = _requireMarket(launchId, index, token, market);
        if (!state.minted || state.activated || buy.marketIndex != index || buy.quoteAmountIn == 0
            || buy.quoteAmountIn > uint256(uint128(type(int128).max)) || buy.recipient == address(0) || buy.recipient == core
            || buy.recipient == address(this) || buy.recipient == address(poolManager) || buy.recipient == address(locker)
            || buy.recipient == address(state.key.hooks) || buy.recipient == state.feeSource) revert InvalidConfiguration();
        uint256 quoteBefore = SafeTransferLib.balanceOf(market.quoteAsset, address(this));
        if (quoteBefore < buy.quoteAmountIn) revert InexactTransfer();
        uint256 tokenBefore = SafeTransferLib.balanceOf(token, address(this));
        bool zeroForOne = market.quoteAsset == Currency.unwrap(state.key.currency0);
        uint160 limit = buy.sqrtPriceLimitX96;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory data = abi.encode(BuyCallback({key: state.key, token: token, recipient: buy.recipient,
            params: SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(buy.quoteAmountIn), sqrtPriceLimitX96: limit}),
            stateBefore: state.committedPoolState}));
        _unlockContext = keccak256(data);
        bytes memory result = poolManager.unlock(data);
        if (_unlockContext != bytes32(0)) revert InvalidCallback();
        bytes32 stateAfter;
        (quoteSpent, tokenOut, stateAfter) = abi.decode(result, (uint256, uint256, bytes32));
        if (quoteSpent > buy.quoteAmountIn || tokenOut < buy.minTokenOut
            || SafeTransferLib.balanceOf(market.quoteAsset, address(this)) + quoteSpent != quoteBefore
            || SafeTransferLib.balanceOf(token, address(this)) != tokenBefore) revert InexactTransfer();
        if (_poolStateHash(state.key) != stateAfter) revert InvalidMarket();
        state.committedPoolState = stateAfter;
        _sendExact(market.quoteAsset, core, buy.quoteAmountIn - quoteSpent);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (_unlockContext == bytes32(0) || keccak256(data) != _unlockContext) revert InvalidCallback();
        _unlockContext = bytes32(0);
        BuyCallback memory action = abi.decode(data, (BuyCallback));
        if (_poolStateHash(action.key) != action.stateBefore) revert InvalidMarket();
        BalanceDelta delta = poolManager.swap(action.key, action.params, "");
        bool tokenIs0 = action.token == Currency.unwrap(action.key.currency0);
        int128 tokenDelta = tokenIs0 ? delta.amount0() : delta.amount1();
        int128 quoteDelta = tokenIs0 ? delta.amount1() : delta.amount0();
        if (quoteDelta > 0 || tokenDelta <= 0) revert SlippageExceeded();
        uint256 quoteSpent = uint256(-int256(quoteDelta));
        uint256 tokenOut = uint256(uint128(tokenDelta));
        bytes32 stateAfter = _poolStateHash(action.key);
        _settleDebt(tokenIs0 ? action.key.currency1 : action.key.currency0, quoteSpent);
        _takeExact(Currency.wrap(action.token), action.recipient, tokenOut);
        return abi.encode(quoteSpent, tokenOut, stateAfter);
    }

    function activateMarket(bytes32 launchId, uint32 index) external override onlyCore nonReentrant {
        _requireContext(launchId, index, LaunchOperationV1.Open, address(this));
        MarketState storage state = _markets[launchId][index];
        if (!state.prepared || !state.minted || state.activated) revert InvalidMarket();
        _requireEligible(state);
        // This is after every externally callable refund/inventory step in the core.
        if (_poolStateHash(state.key) != state.committedPoolState) revert InvalidMarket();
        _requireCanonicalOpening(state);
        state.activated = true;
        ILaunchHookV1(address(state.key.hooks)).completePoolOpening(state.key);
    }

    function _poolStateHash(PoolKey memory key) private view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        return keccak256(abi.encode(poolManager.extsload(slot),
            poolManager.extsload(bytes32(uint256(slot) + StateLibrary.LIQUIDITY_OFFSET))));
    }
    function _poolPrice(PoolKey memory key) private view returns (uint160) {
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        return price;
    }

    function authorizeTokenTransfer(bytes32 launchId, uint32 index, LaunchOperationV1 operation,
        address caller, address from, address to, uint256 amount, bool nft) external view override returns (bool)
    {
        if (msg.sender != core || nft || amount == 0) return false;
        MarketState storage state = _markets[launchId][index];
        if (!state.prepared) return false;
        LaunchExecutionContextV1 memory context = ILaunchLifecycleV1(core).executionContext();
        if (context.launchId != launchId || context.marketIndex != index || context.operation != operation
            || context.adapter != address(this) || context.token != state.token) return false;
        if (operation == LaunchOperationV1.Mint) {
            if (caller == core && from == core && to == address(this) && amount == state.tokenBudget) return true;
            if (caller == address(locker) && from == address(this) && to == address(poolManager) && amount <= state.tokenBudget) return true;
        }
        if (operation != LaunchOperationV1.Mint && operation != LaunchOperationV1.Buy) return false;
        TokenEdge storage edge = _tokenEdge;
        return edge.token == state.token && edge.caller == caller && edge.from == from && edge.to == to && edge.amount == amount;
    }

    function readMarket(bytes32 launchId, uint32 index) external view override returns (MarketLiveStateV1 memory result) {
        MarketState storage state = _markets[launchId][index];
        if (!state.prepared) revert InvalidMarket();
        bytes32 id = PoolId.unwrap(state.key.toId());
        (result.sqrtPriceX96, result.tick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(id));
        result.liquidity = StateLibrary.getLiquidity(poolManager, PoolId.wrap(id));
        result.publicTrading = state.activated && ILaunchLifecycleV1(core).isLaunchActive(launchId);
        result.oracleReadyAt = ILaunchHookV1(address(state.key.hooks)).oracleInitializedAt(id);
    }

    function readPosition(PositionIdentityV1 calldata position) external view override returns (uint128 liquidity, address owner) {
        bytes32 id = _poolIdByMarketId[position.marketId];
        if (id == bytes32(0) || position.manager != address(poolManager) || position.custody != address(locker)
            || position.tokenId >= locker.positionCount(id)) revert InvalidMarket();
        (int24 lower, int24 upper, uint128 locked, bytes32 salt,) = locker.locks(id, position.tokenId);
        if (lower != position.tickLower || upper != position.tickUpper || salt != position.salt || locked != position.liquidity)
            revert InvalidMarket();
        bytes32 positionKey = Position.calculatePositionKey(address(locker), lower, upper, salt);
        liquidity = StateLibrary.getPositionLiquidity(poolManager, PoolId.wrap(id), positionKey);
        owner = address(locker);
    }
    function marketOfCanonicalId(bytes32 canonicalId) external view returns (bytes32 launchId, uint32 index) {
        MarketReference storage ref = _marketIndexOfCanonicalId[canonicalId];
        if (ref.indexPlusOne == 0) revert InvalidMarket();
        return (ref.launchId, ref.indexPlusOne - 1);
    }

    function _key(address token, address quote, V4MarketConfigV4 memory config, address hook)
        internal pure returns (PoolKey memory)
    {
        return PoolKey({currency0: Currency.wrap(token < quote ? token : quote), currency1: Currency.wrap(token < quote ? quote : token),
            fee: config.lpFeePips, tickSpacing: config.tickSpacing, hooks: IHooks(hook)});
    }
    function _identity(PoolKey memory key, uint160 opening) private view returns (MarketIdentityV1 memory identity) {
        bytes32 id = PoolId.unwrap(key.toId());
        identity = MarketIdentityV1({venue: LaunchVenueV1.UniswapV4,
            canonicalId: keccak256(abi.encode(block.chainid, LaunchVenueV1.UniswapV4, address(poolManager), address(0), address(0), id, PROFILE_ID)),
            manager: address(poolManager), factory: address(0), pool: address(0), poolId: id, profileId: PROFILE_ID,
            currency0: Currency.unwrap(key.currency0), currency1: Currency.unwrap(key.currency1), fee: key.fee,
            tickSpacing: key.tickSpacing, hook: address(key.hooks), openingSqrtPriceX96: opening});
    }

    function _requireMarket(bytes32 launchId, uint32 index, address token, MarketConfigV1 calldata market)
        private view returns (MarketState storage state)
    {
        state = _markets[launchId][index];
        if (!state.prepared || state.token != token || state.commitment != keccak256(abi.encode(token, market))) revert InvalidMarket();
        _requireEligible(state);
    }
    function _requireEligible(MarketState storage state) private view {
        uint64 required = LaunchCapabilitiesV1.REQUIRED;
        if (state.positionCount > 1) required |= LaunchCapabilitiesV1.MULTI_POSITION;
        if (implementationRegistry.requireEligible(state.adapterId, PROFILE_ID, state.configVersion, required) != address(this))
            revert InvalidConfiguration();
    }
    function _requireEmptyOpening(MarketState storage state) private view {
        collectorFactory.validateEmptyOpening(poolManager, locker, state.key, state.openingSqrtPriceX96);
    }
    function _requireCanonicalOpening(MarketState storage state) private view {
        bytes32 id = PoolId.unwrap(state.key.toId());
        locker.validatePool(state.key);
        if (locker.positionCount(id) != state.positionCount || locker.feeRecipient(id) != state.feeSource) revert InvalidMarket();
    }
    function _requireContext(bytes32 launchId, uint32 index, LaunchOperationV1 operation, address executor) private view {
        LaunchExecutionContextV1 memory context = ILaunchLifecycleV1(core).executionContext();
        if (context.launchId != launchId || context.marketIndex != index || context.operation != operation
            || context.adapter != address(this) || context.executor != executor) revert Unauthorized();
    }
    function _positionIdentity(bytes32 marketId, uint256 index, V4PositionConfigV1 memory p)
        private view returns (PositionIdentityV1 memory)
    {
        return PositionIdentityV1({canonicalId: keccak256(abi.encode(block.chainid, marketId, address(poolManager),
                address(locker), index, p.tickLower, p.tickUpper, p.salt)), marketId: marketId, manager: address(poolManager),
            custody: address(locker), tokenId: index, tickLower: p.tickLower, tickUpper: p.tickUpper, salt: p.salt, liquidity: p.liquidity});
    }

    function _sendExact(address token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeSelf = SafeTransferLib.balanceOf(token, address(this));
        uint256 beforeRecipient = SafeTransferLib.balanceOf(token, recipient);
        _tokenEdge = TokenEdge(token, address(this), address(this), recipient, amount);
        SafeTransferLib.safeTransfer(token, recipient, amount);
        delete _tokenEdge;
        if (SafeTransferLib.balanceOf(token, address(this)) + amount != beforeSelf
            || SafeTransferLib.balanceOf(token, recipient) != beforeRecipient + amount) revert InexactTransfer();
    }
    function _settleDebt(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        uint256 beforeSelf = SafeTransferLib.balanceOf(token, address(this));
        uint256 beforeManager = SafeTransferLib.balanceOf(token, address(poolManager));
        poolManager.sync(currency);
        _tokenEdge = TokenEdge(token, address(this), address(this), address(poolManager), amount);
        SafeTransferLib.safeTransfer(token, address(poolManager), amount);
        delete _tokenEdge;
        if (poolManager.settle() != amount || SafeTransferLib.balanceOf(token, address(this)) + amount != beforeSelf
            || SafeTransferLib.balanceOf(token, address(poolManager)) != beforeManager + amount) revert InexactTransfer();
    }
    function _takeExact(Currency currency, address recipient, uint256 amount) private {
        address token = Currency.unwrap(currency);
        uint256 beforeManager = SafeTransferLib.balanceOf(token, address(poolManager));
        uint256 beforeRecipient = SafeTransferLib.balanceOf(token, recipient);
        _tokenEdge = TokenEdge(token, address(poolManager), address(poolManager), recipient, amount);
        poolManager.take(currency, recipient, amount);
        delete _tokenEdge;
        if (SafeTransferLib.balanceOf(token, address(poolManager)) + amount != beforeManager
            || SafeTransferLib.balanceOf(token, recipient) != beforeRecipient + amount) revert InexactTransfer();
    }
}
