// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LaunchDeltaAccountingFixture } from "./LaunchDeltaAccountingFixture.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { IAbyssLaunchFactory } from "../src/interfaces/IAbyssLaunch.sol";
import { LaunchOrchestratorV1, LaunchImplementationRegistryV2, PoolMarketAdapterV1, PoolFeeCollectorFactoryV1, V4FeeCollectorV2 } from "../src/interfaces/IForkLaunch.sol";
import { PoolHookDeployerV1 } from "../src/hooks/v4/authoring/PoolHookDeployerV1.sol";
import { PoolBoundLaunchHookBaseV2 } from "../src/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";
import { ILaunchHookAuthorTerms } from "../src/hooks/v4/authoring/ILaunchHookAuthorTerms.sol";
import { ILaunchHookOracleV1 } from "../src/hooks/v4/authoring/ILaunchHookOracleV1.sol";
import { TruncatedOracle } from "../src/hooks/v4/TruncatedOracle.sol";
import { PoolBoundHookParametersV1 } from "../src/hooks/v4/PoolBoundHookParametersV1.sol";
import { V4FeeLiquidityLockerV2 } from "../src/launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import { FeeAssetPolicyV2 } from "../src/launch/fees/v2/ILaunchFeeHubV2.sol";
import { ILaunchFeeHubV3 } from "../src/launch/fees/v3/ILaunchFeeHubV3.sol";
import { LaunchEnvelopeV2, LaunchBoundsV2 } from "../src/launch/lifecycle/v2/ILaunchRegistryV2.sol";
import { V4MarketConfigV5 } from "../src/launch/lifecycle/v2/V4MarketConfigV5.sol";
import { V4PositionConfigV1 } from "../src/launch/lifecycle/v1/V4MarketConfigV2.sol";
import { LaunchPlanV1, TokenConfigV1, TokenKindV1, RewardModeV1, AssetFundingV1, FundingKindV1, MarketConfigV1, InitialBuyV1, LaunchModeV1, LaunchPhaseV1, LaunchReceiptV1, PreparedMarketV1, ProfileRegistrationV1 } from "../src/launch/lifecycle/v1/LaunchTypesV1.sol";
import { ForkTrader, IERC20Fork, IWETHFork } from "./ForkTrader.sol";

interface IOracleAdminFork {
    struct OracleConfig { uint24 maxAbsTickMove; uint16 cardinality; }
    function owner() external view returns (address);
    function registerOracleConfig(OracleConfig calldata config) external returns (bytes32);
}

interface IHookFeeRatePreviewFork {
    function feeRate(SwapParams calldata params) external view returns (uint24);
}

interface IContractOwnerFork {
    function owner() external view returns (address);
}

contract HookLaunchTest is LaunchDeltaAccountingFixture {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    uint256 private constant AUTHOR_KEY = 0xa110ce;
    uint16 private constant EXECUTOR_BPS = 275;
    string private manifest;
    LaunchOrchestratorV1 private core;
    LaunchImplementationRegistryV2 private registry;
    IPoolManager private manager;
    PoolMarketAdapterV1 private adapter;
    PoolHookDeployerV1 private deployer;
    V4FeeLiquidityLockerV2 private locker;
    LaunchEnvelopeV2 private envelope;
    bytes32 private profileId;
    bytes32 private adapterId;
    bytes32 private oracleId;
    address private author;
    address private creator;
    address private executor;
    IWETHFork private weth;
    ForkTrader private trader;
    uint16 private developerBps;

    struct Receipts {
        address token;
        address hook;
        bytes32 poolId;
        uint256 treasuryPaid;
        uint256 ownerPaid;
        uint256 authorPaid;
        uint256 expectedOwnerPaid;
        uint256 expectedAuthorPaid;
        uint256 hookFeesCollected;
        uint256 lpFeesCollected;
        uint256 tradeCount;
    }

    function setUp() public {
        manifest = vm.readFile(vm.envString("HOOK_FORK_MANIFEST"));
        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));
        assertEq(block.number, vm.parseJsonUint(manifest, ".forkBlock"));
        string[] memory names = vm.parseJsonKeys(manifest, ".addresses");
        for (uint256 i; i < names.length; ++i) {
            address target = _address(names[i]);
            assertEq(target.codehash, vm.parseJsonBytes32(manifest, string.concat(".codeHashes.", names[i])), names[i]);
        }
        core = LaunchOrchestratorV1(_address("core"));
        registry = LaunchImplementationRegistryV2(_address("registry"));
        manager = IPoolManager(_address("manager"));
        weth = IWETHFork(_address("wrappedNative"));
        assertEq(address(core.registry()), address(registry));
        assertEq(address(registry.core()), address(core));
        author = vm.addr(AUTHOR_KEY);
        creator = makeAddr("hook launch creator");
        executor = makeAddr("hook fee executor");
        developerBps = uint16(vm.envUint("HOOK_MAX_DEVELOPER_BPS"));
        require(developerBps <= registry.protocolMaximumDeveloperFeeBps(), "developer ceiling exceeds deployed protocol maximum");
        _admitCandidate();
        trader = new ForkTrader(manager);
        vm.deal(creator, 3_000 ether);
        vm.startPrank(creator);
        weth.deposit{value: 2_000 ether}();
        assertTrue(weth.approve(core.fundingEscrow(), type(uint256).max));
        assertTrue(weth.approve(address(trader), type(uint256).max));
        vm.stopPrank();
    }

    function testLaunchTradesAndExactRoyaltyClaims() public {
        uint256 flags = vm.envUint("HOOK_FEE_MODE_FLAGS");
        uint256 scenarios;
        for (uint8 mode; mode < 2; ++mode) {
            if ((flags & (uint256(1) << mode)) == 0) continue;
            Receipts memory received = _scenario(mode, 100_001 + mode);
            assertEq(received.tradeCount, 4);
            emit log_named_uint("fee mode", mode);
            emit log_named_uint("WETH author paid", received.authorPaid);
            emit log_named_uint("WETH owner paid", received.ownerPaid);
            _writeReceipts(received);
            ++scenarios;
        }
        assertGt(scenarios, 0);
    }

    function testLaunchRejectsReducedAuthorPayment() public {
        vm.skip(developerBps == 0);
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        LaunchPlanV1 memory plan = _planWithFees(mode, 200_001, developerBps - 1, 0);
        vm.startPrank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        core.prepareMarkets(plan, 0, 1);
        vm.expectRevert();
        core.activateLaunch(plan);
        vm.stopPrank();
        assertFalse(core.isLaunchActive(launchId));
        (, PreparedMarketV1 memory prepared) = core.directory().market(launchId, 0);
        assertEq(StateLibrary.getLiquidity(manager, PoolIdLibrary.toId(PoolKey(
            Currency.wrap(prepared.identity.currency0), Currency.wrap(prepared.identity.currency1),
            prepared.identity.fee, prepared.identity.tickSpacing, IHooks(prepared.identity.hook)
        ))), 0, "mismatched payment must not acquire liquidity");
    }

    function testRegisteredPayoutReceivesHookRoyalties() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        address payout = makeAddr("registered author payout");
        vm.prank(author);
        registry.setAuthorPayout(author, payout);
        Receipts memory received = _scenarioWithFees(mode, 300_001, 10_000);
        assertGt(received.hookFeesCollected, 0);
        assertEq(received.lpFeesCollected, 0);
        assertEq(received.authorPaid, received.expectedAuthorPaid);
        assertEq(received.ownerPaid, received.expectedOwnerPaid);
        assertEq(weth.balanceOf(payout), received.authorPaid);
        assertEq(weth.balanceOf(author), 0, "stable identity is not the payout destination");
    }

    function testConfiguredZeroHookFeeIsFree() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        Receipts memory received = _scenarioWithFees(mode, 400_001, 0);
        assertEq(received.hookFeesCollected, 0);
        assertEq(received.lpFeesCollected, 0);
        assertEq(received.treasuryPaid, 0);
        assertEq(received.authorPaid, 0);
        assertEq(received.ownerPaid, 0);
    }

    function testLaunchRejectsNonzeroPoolLPFee() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        LaunchPlanV1 memory plan = _planWithPoolFee(mode, 500_001, developerBps, 10_000, 3_000);
        vm.startPrank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        vm.expectRevert();
        core.prepareMarkets(plan, 0, 1);
        vm.stopPrank();
        assertFalse(core.isLaunchActive(launchId));
        assertEq(core.readLaunchProgress(launchId).preparedMarkets, 0);
    }

    function testTradingRejectsPoolManagerProtocolFee() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        Receipts memory received = _scenarioWithFees(mode, 600_001, 10_000);
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        vm.prank(IContractOwnerFork(address(manager)).owner());
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 100);
        SwapBalances memory beforeBalances = _snapshotSwapBalances(key, creator);
        SwapParams memory params = SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert();
        IHookFeeRatePreviewFork(received.hook).feeRate(params);
        vm.prank(creator);
        vm.expectRevert();
        trader.trade(key, params);
        assertEq(IERC20Fork(Currency.unwrap(key.currency0)).balanceOf(creator), beforeBalances.amount0);
        assertEq(IERC20Fork(Currency.unwrap(key.currency1)).balanceOf(creator), beforeBalances.amount1);
        _assertHookFeeBacking(manager, key);
    }

    function testDynamicExampleTracksObservedPriceVelocity() public {
        vm.skip(!vm.envOr("HOOK_ORACLE_VELOCITY_EXAMPLE", false));
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        Receipts memory received = _scenario(mode, 1_200_001);
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        bool sellBase = Currency.unwrap(key.currency0) == received.token;
        SwapParams memory preview = SwapParams(sellBase, -int256(1 ether),
            sellBase ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint24 fastRate = IHookFeeRatePreviewFork(received.hook).feeRate(preview);
        assertGt(fastRate, 2_000, "observed upward movement raises fees above baseline");
        vm.warp(block.timestamp + 120);
        uint24 idleRate = IHookFeeRatePreviewFork(received.hook).feeRate(preview);
        assertLt(idleRate, fastRate, "without new movement the historical rise must fade");
        assertGe(idleRate, 2_000);
        emit log_named_uint("fast upward oracle rate", fastRate);
        emit log_named_uint("idle oracle rate", idleRate);

        // Sell enough base to move the real spot below the lagged truncated tick, but stay
        // inside the funded range. The next swap observes that fall, not its own price impact.
        _sellBelowOracle(key, received.poolId, sellBase);
        for (uint256 i; i < 5; ++i) _trade(key, sellBase, -int256(1e12));
        assertEq(IHookFeeRatePreviewFork(received.hook).feeRate(preview), 2_000,
            "falling then flat observed prices use baseline");
        emit log_named_uint("falling and flat oracle rate", 2_000);
    }

    function _sellBelowOracle(PoolKey memory key, bytes32 id, bool sellBase) private {
        (,,, int24 normalizedTick,,,,) = ILaunchHookOracleV1(address(key.hooks)).oracleState(id);
        assertGt(normalizedTick, 1);
        int24 targetTick = sellBase ? normalizedTick / 2 : -(normalizedTick / 2);
        (uint160 currentPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint160 targetPrice = TickMath.getSqrtPriceAtTick(targetTick);
        uint128 liquidity = StateLibrary.getLiquidity(manager, key.toId());
        uint256 netInput = sellBase
            ? SqrtPriceMath.getAmount0Delta(targetPrice, currentPrice, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(currentPrice, targetPrice, liquidity, true);
        // Every _trade advances twelve seconds before taking its frozen rate snapshot.
        vm.warp(block.timestamp + 12);
        SwapParams memory preview = SwapParams(sellBase, -int256(netInput),
            sellBase ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint24 rate = IHookFeeRatePreviewFork(address(key.hooks)).feeRate(preview);
        vm.warp(block.timestamp - 12);
        uint256 grossInput = netInput;
        if (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1 != 0) {
            grossInput = FullMath.mulDivRoundingUp(netInput, 1_000_000, 1_000_000 - rate);
        }
        _trade(key, sellBase, -int256(grossInput));
        (, int24 actualTick,,) = StateLibrary.getSlot0(manager, key.toId());
        assertLt(sellBase ? actualTick : -actualTick, normalizedTick);
    }

    function testOptionalOracleComposition() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        Receipts memory received = _scenarioWithFees(mode, 700_001, 10_000);
        ILaunchHookV1 hook = ILaunchHookV1(received.hook);
        vm.expectRevert();
        hook.oracleInitializedAt(bytes32(uint256(received.poolId) ^ 1));
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) {
            assertEq(hook.oracleInitializedAt(received.poolId), 0, "no oracle means no readiness");
            (bool success,) = received.hook.staticcall(
                abi.encodeCall(ILaunchHookOracleV1.observeTruncated, (received.poolId, new uint32[](1)))
            );
            assertFalse(success, "core-only hook must not expose historical queries");
            return;
        }
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(received.hook);
        _sameBlockTradeLeavesOracleUnchanged(received);
        _assertOracleElapsedHistory(received);
        (, uint16 cardinality, uint16 next,,,,, uint16 cap) = oracle.oracleState(received.poolId);
        assertEq(cardinality, next);
        oracle.increaseObservationCardinalityNext(received.poolId, type(uint16).max);
        (,, next,,,,,) = oracle.oracleState(received.poolId);
        assertEq(next, cap, "growth must respect the frozen registry cap");
        uint32[] memory tooOld = new uint32[](1);
        tooOld[0] = uint32(block.timestamp - hook.oracleInitializedAt(received.poolId) + 1);
        vm.expectRevert(TruncatedOracle.ObservationTooOld.selector);
        oracle.observeTruncated(received.poolId, tooOld);
    }

    function testNoOracleHistoryBeforePoolInitialization() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        LaunchPlanV1 memory plan = _planWithFees(mode, 800_001, developerBps, 10_000);
        PoolBoundLaunchHookBaseV2 hook = _predeployPlannedHook(plan);
        bytes32 id = hook.boundPoolId();
        assertFalse(hook.initialized(id));
        assertEq(hook.oracleInitializedAt(id), 0);
        assertEq(vm.getNonce(address(hook)), 1);
        if (vm.envOr("HOOK_HAS_ORACLE", false)) {
            ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(hook));
            vm.expectRevert(TruncatedOracle.InvalidObservationState.selector);
            oracle.observeTruncated(id, new uint32[](1));
            vm.expectRevert(TruncatedOracle.InvalidObservationState.selector);
            oracle.increaseObservationCardinalityNext(id, 2);
        }
    }

    function _predeployPlannedHook(LaunchPlanV1 memory plan) private returns (PoolBoundLaunchHookBaseV2) {
        (PoolBoundHookParametersV1 memory parameters, bytes32 salt) =
            adapter.collectorFactory().poolBoundHookParameters(address(adapter), core.predictToken(plan), plan.markets[0]);
        return deployer.deploy(parameters, salt);
    }

    function testRegistrationAcceptsStructuredGetterLayouts() public {
        for (uint256 scenario; scenario < 4; ++scenario) _probeCollectorGetter(scenario);
    }

    function testRegistrationRejectsMalformedStructuredGetters() public {
        for (uint256 scenario = 4; scenario < 23; ++scenario) _probeCollectorGetter(scenario);
    }

    function testRegistrationBubblesStructuredGetterReverts() public {
        _probeCollectorGetter(23);
        _probeCollectorGetter(24);
    }

    function _probeCollectorGetter(uint256 scenario) private {
        uint256 snapshot = vm.snapshotState();
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        LaunchPlanV1 memory plan = _planWithFees(mode, 1_300_001 + scenario, developerBps, 10_000);
        PoolBoundLaunchHookBaseV2 hook = _predeployPlannedHook(plan);
        PoolKey memory key = hook.poolKey(hook.boundPoolId());
        vm.prank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        address creatorContract = _address("collectorDeployer");
        address collector = vm.computeCreateAddress(creatorContract, vm.getNonce(creatorContract));
        (bytes4 selector, bytes memory response) = _collectorGetterResponse(key, scenario);
        if (scenario >= 23) vm.mockCallRevert(collector, abi.encodePacked(selector), response);
        else vm.mockCall(collector, abi.encodePacked(selector), response);
        // mockCall installs code on empty targets. Remove that stub so the real canonical
        // deployer still CREATEs the collector; only its selected return envelope is mocked.
        vm.etch(collector, "");
        vm.prank(creator);
        if (scenario >= 23) vm.expectRevert(response);
        else if (scenario >= 4) vm.expectRevert();
        core.prepareMarkets(plan, 0, 1);
        assertEq(hook.registered(hook.boundPoolId()), scenario < 4);
        assertEq(core.readLaunchProgress(launchId).preparedMarkets, scenario < 4 ? 1 : 0);
        if (scenario < 4) assertGt(collector.code.length, 0, "actual collector must be deployed");
        vm.clearMockedCalls();
        require(vm.revertToStateAndDelete(snapshot), "restore isolated structured ABI scenario");
    }

    function _collectorGetterResponse(PoolKey memory key, uint256 scenario)
        private pure returns (bytes4 selector, bytes memory response)
    {
        selector = bytes4(keccak256("assets()"));
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        if (scenario == 0 || (scenario >= 13 && scenario <= 19) || scenario == 23) {
            selector = bytes4(keccak256("poolKey()"));
            response = abi.encode(key);
            if (scenario == 0) return (selector, bytes.concat(response, abi.encode(uint256(123))));
            if (scenario == 13) return (selector, new bytes(0));
            if (scenario == 14) return (selector, new bytes(159));
            if (scenario == 15) response[0] = 0x01;
            if (scenario == 16) response[64] = 0x01;
            if (scenario == 17) response[96] = 0x01;
            if (scenario == 18) response[128] = 0x01;
            if (scenario == 19) response[159] ^= 0x01;
            if (scenario == 23) response = abi.encodeWithSignature("GetterRejected(uint256)", scenario);
            return (selector, response);
        }
        if (scenario == 24) return (selector, abi.encodeWithSignature("GetterRejected(uint256)", scenario));
        if (scenario == 4) return (selector, new bytes(0));
        if (scenario == 5) return (selector, new bytes(31));
        if (scenario == 6) return (selector, bytes.concat(abi.encode(uint256(32)), new bytes(31)));
        uint256 offset = scenario == 2 ? 33 : scenario == 3 ? 96 : 32;
        uint256 count = scenario == 11 ? 3 : scenario == 20 ? 0 : scenario == 21 ? 1 : 2;
        response = new bytes(offset + 32 + count * 32 + (scenario == 3 ? 32 : 0));
        assembly ("memory-safe") {
            let data := add(response, 32)
            mstore(data, offset)
            mstore(add(data, offset), count)
            if count { mstore(add(add(data, offset), 32), asset0) }
            if gt(count, 1) { mstore(add(add(data, offset), 64), asset1) }
            if gt(count, 2) { mstore(add(add(data, offset), 96), asset0) }
        }
        if (scenario == 7) assembly ("memory-safe") { mstore(response, 127) }
        if (scenario == 8) assembly ("memory-safe") { mstore(add(response, 32), 160) }
        if (scenario == 9) assembly ("memory-safe") { mstore(add(response, 32), shl(64, 1)) }
        if (scenario == 10) assembly ("memory-safe") { mstore(add(response, 64), shl(64, 1)) }
        if (scenario == 12) response[64] = 0x01;
        if (scenario == 22) response[127] ^= 0x01;
    }

    function testRegistrationRejectsMalformedGetterWords() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            LaunchPlanV1 memory plan = _planWithFees(mode, 900_001 + i, developerBps, 10_000);
            PoolBoundLaunchHookBaseV2 hook = _predeployPlannedHook(plan);
            vm.prank(creator);
            bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
            if (i == 3) {
                vm.mockCall(address(locker), abi.encodeCall(V4FeeLiquidityLockerV2.isSealed, (hook.boundPoolId())),
                    abi.encode(uint256(2)));
            } else {
                bytes memory response = i == 0 ? new bytes(0) : i == 1 ? new bytes(31)
                    : abi.encode(uint256(uint160(address(adapter))) | (uint256(1) << 160));
                vm.mockCall(address(locker), abi.encodeCall(V4FeeLiquidityLockerV2.launcher, ()), response);
            }
            vm.prank(creator);
            vm.expectRevert();
            core.prepareMarkets(plan, 0, 1);
            assertFalse(hook.registered(hook.boundPoolId()));
            assertEq(core.readLaunchProgress(launchId).preparedMarkets, 0);
            vm.clearMockedCalls();
            require(vm.revertToStateAndDelete(snapshot), "restore isolated ABI scenario");
        }
    }

    function testRegistrationBubblesGetterRevert() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        LaunchPlanV1 memory plan = _planWithFees(mode, 1_000_001, developerBps, 10_000);
        PoolBoundLaunchHookBaseV2 hook = _predeployPlannedHook(plan);
        vm.prank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        bytes memory reason = abi.encodeWithSignature("GetterRejected(uint256)", uint256(7));
        vm.mockCallRevert(address(locker), abi.encodeCall(V4FeeLiquidityLockerV2.launcher, ()), reason);
        vm.prank(creator);
        vm.expectRevert(reason);
        core.prepareMarkets(plan, 0, 1);
        assertFalse(hook.registered(hook.boundPoolId()));
        assertEq(core.readLaunchProgress(launchId).preparedMarkets, 0);
    }

    function testRegistrationAcceptsCleanGetterWithTrailingData() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        _predeployPlannedHook(_planWithFees(mode, 1_100_001, developerBps, 10_000));
        vm.mockCall(address(locker), abi.encodeCall(V4FeeLiquidityLockerV2.launcher, ()),
            abi.encode(address(adapter), bytes32(uint256(123))));
        Receipts memory received = _scenario(mode, 1_100_001);
        assertEq(received.authorPaid, received.expectedAuthorPaid);
        assertEq(received.ownerPaid, received.expectedOwnerPaid);
        assertGt(received.hookFeesCollected, 0);
        assertEq(received.lpFeesCollected, 0);
    }

    function _admitCandidate() private {
        bytes memory creation = vm.getCode(vm.envString("HOOK_ARTIFACT"));
        deployer = new PoolHookDeployerV1(creation);
        envelope = registry.profileEnvelope(vm.parseJsonBytes32(manifest, ".referenceProfileId"));
        envelope.artifactDigest = keccak256(creation);
        envelope.reviewManifestDigest = keccak256("local hook acceptance fixture");
        envelope.termsDigest = keccak256("local royalty acceptance fixture");
        envelope.beneficiary = author;
        envelope.maximumDeveloperFeeBps = developerBps;
        envelope.bounds = LaunchBoundsV2(
            int24(int256(vm.envUint("HOOK_MIN_TICK_SPACING"))),
            int24(int256(vm.envUint("HOOK_MAX_TICK_SPACING"))),
            uint16(vm.envUint("HOOK_MAX_POSITIONS")),
            uint16(vm.envUint("HOOK_MAX_ORACLE_CARDINALITY")),
            uint8(vm.envUint("HOOK_FEE_MODE_FLAGS"))
        );
        envelope.configBoundsDigest = keccak256(abi.encode(envelope.bounds));
        profileId = registry.profileId(envelope);
        address predictedAdapter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        locker = V4FeeLiquidityLockerV2(_deployPublic("locker", abi.encode(manager, predictedAdapter)));
        adapter = PoolMarketAdapterV1(_deployPublic("pool-adapter", abi.encode(core, manager, _address("oracleFactory"), locker, deployer, _address("collectorFactory"), registry, profileId)));
        assertEq(address(adapter), predictedAdapter);
        envelope.graph.locker = address(locker);
        envelope.graph.lockerCodeHash = address(locker).codehash;
        envelope.graph.hookDeployer = address(deployer);
        envelope.graph.hookDeployerCodeHash = address(deployer).codehash;
        envelope.graph.hookCreationCodeHash = deployer.creationCodeHash();
        envelope.graph.codeChunk0 = deployer.codeChunk0();
        envelope.graph.codeChunk0Hash = deployer.codeChunk0().codehash;
        envelope.graph.codeChunk1 = deployer.codeChunk1();
        envelope.graph.codeChunk1Hash = deployer.codeChunk1() == address(0) ? bytes32(0) : deployer.codeChunk1().codehash;
        adapterId = keccak256(abi.encode("local submitted hook", profileId));
        ProfileRegistrationV1 memory registration = ProfileRegistrationV1(adapterId, adapter.CONFIG_SCHEMA(), adapter.dependencyDigest(), address(manager), address(0), address(0), envelope.capabilities, true);
        uint256 nonce = registry.beneficiaryNonces(author);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.authorizationDigest(profileId, registration, envelope, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTHOR_KEY, digest);
        vm.startPrank(registry.admin());
        registry.registerAdapter(adapterId, address(adapter), envelope.capabilities, 5);
        registry.registerProfile(profileId, registration, envelope, nonce, deadline, abi.encodePacked(r, s, v));
        if (!registry.fundingInputAllowed(address(weth))) registry.setFundingInputAllowed(address(weth), true);
        vm.stopPrank();
        uint16 cardinality = envelope.bounds.maximumOracleCardinality;
        oracleId = keccak256(abi.encode(uint24(17), cardinality));
        (uint24 movement,) = IAbyssLaunchFactory(_address("oracleFactory")).oracleConfigs(oracleId);
        if (movement == 0) {
            IOracleAdminFork oracle = IOracleAdminFork(_address("oracleFactory"));
            vm.prank(oracle.owner());
            assertEq(oracle.registerOracleConfig(IOracleAdminFork.OracleConfig(17, cardinality)), oracleId);
        }
    }

    function _scenario(uint8 mode, uint256 nonce) private returns (Receipts memory received) {
        return _scenarioWithFees(mode, nonce, 10_000);
    }

    function _scenarioWithFees(uint8 mode, uint256 nonce, uint24 hookPips)
        private returns (Receipts memory received)
    {
        LaunchPlanV1 memory plan = _planWithFees(mode, nonce, developerBps, hookPips);
        vm.startPrank(creator);
        core.beginLaunch(plan, LaunchModeV1.Staged);
        core.prepareMarkets(plan, 0, 1);
        LaunchReceiptV1 memory receipt = core.activateLaunch(plan);
        vm.stopPrank();
        assertTrue(core.isLaunchActive(receipt.launchId));
        assertEq(uint256(core.readLaunchProgress(receipt.launchId).phase), uint256(LaunchPhaseV1.Active));
        assertEq(receipt.marketCount, 1);
        assertEq(receipt.positionCount, 1);
        (, PreparedMarketV1 memory prepared) = core.directory().market(receipt.launchId, 0);
        PoolKey memory key = PoolKey(Currency.wrap(prepared.identity.currency0), Currency.wrap(prepared.identity.currency1), prepared.identity.fee, prepared.identity.tickSpacing, IHooks(prepared.identity.hook));
        assertEq(deployer.deployedCodeHash(prepared.identity.hook), prepared.identity.hook.codehash);
        assertEq(keccak256(vm.getCode(vm.envString("HOOK_ARTIFACT"))), deployer.creationCodeHash());
        assertGt(ILaunchHookV1(prepared.identity.hook).openingCompletedAt(prepared.identity.poolId), 0);
        assertEq(vm.getNonce(prepared.identity.hook), 1, "hook must not create another contract");
        _assertOracleGenesis(prepared.identity.hook, prepared.identity.poolId);
        ILaunchHookAuthorTerms terms = ILaunchHookAuthorTerms(prepared.identity.hook);
        assertEq(terms.authorFeeBps(), developerBps);
        assertEq(uint256(terms.swapFeeModel()), vm.envUint("HOOK_SWAP_FEE_MODEL"));
        assertEq(ILaunchFeeHubV3(receipt.feeHub).sourceTerms(prepared.feeSource).beneficiary, author);
        assertEq(ILaunchFeeHubV3(receipt.feeHub).sourceTerms(prepared.feeSource).developerFeeBps, developerBps);
        assertEq(key.fee, 0, "pool LP fee must be zero");
        (,, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, 0);
        assertEq(ILaunchHookV1(prepared.identity.hook).poolConfig(prepared.identity.poolId).hookFeePips, hookPips);
        _assertHookFeeBacking(manager, key);
        vm.prank(creator);
        assertTrue(IERC20Fork(receipt.token).approve(address(trader), type(uint256).max));
        _trade(key, prepared.identity.currency0 == address(weth), -int256(10 ether));
        _trade(key, prepared.identity.currency0 == receipt.token, -int256(5 ether));
        _trade(key, prepared.identity.currency0 == address(weth), int256(1 ether));
        _trade(key, prepared.identity.currency0 == receipt.token, int256(1 ether));
        vm.prank(creator);
        assertTrue(weth.transfer(prepared.identity.hook, 17));
        _assertHookFeeBacking(manager, key);
        received = _harvestAndClaim(receipt, prepared, key);
        assertEq(weth.balanceOf(prepared.identity.hook), 17, "donations must not become fees");
        received.tradeCount = 4;
    }

    function _planWithFees(uint8 mode, uint256 nonce, uint16 selectedAuthorBps, uint24 hookPips)
        private view returns (LaunchPlanV1 memory plan)
    {
        return _planWithPoolFee(mode, nonce, selectedAuthorBps, hookPips, 0);
    }

    function _planWithPoolFee(uint8 mode, uint256 nonce, uint16 selectedAuthorBps, uint24 hookPips, uint24 lpPips)
        private view returns (LaunchPlanV1 memory plan)
    {
        plan.chainId = block.chainid;
        plan.orchestrator = address(core);
        plan.creator = creator;
        plan.nonce = nonce;
        plan.deadline = block.timestamp + 1 days;
        plan.executorFeeBps = EXECUTOR_BPS;
        plan.token = TokenConfigV1(TokenKindV1.ERC20, RewardModeV1.None, "Hook acceptance token", "HOOK", 3_100 ether, 0, "", bytes32(nonce), creator, false);
        address token = core.predictToken(plan);
        V4MarketConfigV5 memory config;
        config.version = 5;
        config.lpFeePips = lpPips;
        config.tickSpacing = envelope.bounds.minimumTickSpacing;
        config.sqrtPriceX96 = uint160(1 << 96);
        config.hookFeePips = hookPips;
        config.feeMode = mode;
        config.protocolFeeDenominator = envelope.protocolFeeDenominator;
        config.treasury = envelope.protocolTreasury;
        config.externalLiquidityDisabled = true;
        config.oracleConfigId = oracleId;
        config.profileId = profileId;
        config.termsDigest = envelope.termsDigest;
        config.developerBeneficiary = author;
        config.developerFeeBps = selectedAuthorBps;
        config.positions = new V4PositionConfigV1[](1);
        int24 edge = (TickMath.MAX_TICK / config.tickSpacing) * config.tickSpacing;
        config.positions[0] = V4PositionConfigV1(token < address(weth) ? int24(0) : -edge, token < address(weth) ? edge : int24(0), 1_000 ether, bytes32(uint256(1)), 1_000 ether);
        plan.markets = new MarketConfigV1[](1);
        plan.markets[0] = MarketConfigV1(adapterId, profileId, address(weth), 1_100 ether, 5, abi.encode(config));
        PoolBoundHookParametersV1 memory parameters;
        (parameters,) = adapter.collectorFactory().poolBoundHookParameters(address(adapter), token, plan.markets[0]);
        config.hookSalt = _mine(address(deployer), deployer.initCodeHash(parameters));
        plan.markets[0].config = abi.encode(config);
        assertEq(core.predictToken(plan), token);
        plan.funding = new AssetFundingV1[](1);
        plan.funding[0] = AssetFundingV1(address(weth), 497 ether, FundingKindV1.ERC20, address(weth), 497 ether, address(0), "");
        plan.buys = new InitialBuyV1[](1);
        plan.buys[0] = InitialBuyV1(0, 200 ether, 1, creator, address(weth) < token ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        plan.feeAssets = new FeeAssetPolicyV2[](2);
        plan.feeAssets[0] = FeeAssetPolicyV2(token < address(weth) ? token : address(weth), 10_000, 0, 0);
        plan.feeAssets[1] = FeeAssetPolicyV2(token < address(weth) ? address(weth) : token, 10_000, 0, 0);
    }

    function _trade(PoolKey memory key, bool zeroForOne, int256 amount) private {
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        SwapBalances memory beforeBalances = _snapshotSwapBalances(key, creator);
        SwapParams memory params = SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        TradeFee memory fee = _tradeFeeBefore(key, params);
        OracleBefore memory oracleBefore = _oracleBeforeSwap(key);
        emit log_named_uint("hook rate pips", fee.rate);
        vm.prank(creator);
        BalanceDelta delta = trader.trade(key, params);
        _assertSwapAccounting(manager, key, address(trader), creator, beforeBalances, delta);
        _assertTradeFee(key, params, delta, fee);
        _assertOracleAfterSwap(key, oracleBefore);
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        assertLt(input, 0);
        assertGt(output, 0);
        if (amount < 0) assertEq(int256(input), amount);
        else assertEq(int256(output), amount);
    }

    struct OracleBefore {
        uint16 index;
        int24 tick;
        int24 spotTick;
        int24 maximumMove;
        uint32 timestamp;
        int56 tickCumulative;
        uint160 liquidityCumulative;
        uint128 liquidity;
    }

    function _assertOracleGenesis(address hook, bytes32 id) private {
        uint256 genesis = ILaunchHookV1(hook).oracleInitializedAt(id);
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) {
            assertEq(genesis, 0);
            return;
        }
        assertEq(genesis, block.timestamp, "oracle history starts at actual initialization");
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(hook);
        (uint16 index, uint16 cardinality, uint16 next,,,,, uint16 cap) = oracle.oracleState(id);
        assertEq(index, 0);
        assertEq(cardinality, 1, "initialization must not fabricate history");
        (uint32 timestamp, int56 ticks, uint160 liquidity, bool initialized) = oracle.observations(id, 0);
        assertEq(timestamp, uint32(genesis));
        assertEq(ticks, 0);
        assertEq(liquidity, 0);
        assertTrue(initialized);
        if (!vm.envOr("HOOK_ORACLE_VELOCITY_EXAMPLE", false)) {
            oracle.increaseObservationCardinalityNext(id, 3);
            (, cardinality, next,,,,,) = oracle.oracleState(id);
            assertEq(cardinality, 1, "prepared capacity is not populated history");
            assertEq(next, cap < 3 ? cap : 3);
        }
    }

    function _oracleBeforeSwap(PoolKey memory key) private view returns (OracleBefore memory snapshot) {
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) return snapshot;
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        (snapshot.index,,, snapshot.tick,,, snapshot.maximumMove,) = oracle.oracleState(id);
        (snapshot.timestamp, snapshot.tickCumulative, snapshot.liquidityCumulative,) =
            oracle.observations(id, snapshot.index);
        (, snapshot.spotTick,,) = StateLibrary.getSlot0(manager, key.toId());
        snapshot.liquidity = StateLibrary.getLiquidity(manager, key.toId());
    }

    function _expectedOracleTick(OracleBefore memory previous, bool quoteIs0) private pure returns (int256) {
        int256 spot = quoteIs0 ? -int256(previous.spotTick) : int256(previous.spotTick);
        int256 lower = int256(previous.tick) - previous.maximumMove;
        int256 upper = int256(previous.tick) + previous.maximumMove;
        return spot < lower ? lower : spot > upper ? upper : spot;
    }

    function _assertOracleAfterSwap(PoolKey memory key, OracleBefore memory beforeOracle) private view {
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) return;
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        (uint16 index, uint16 cardinality,, int24 tick, uint64 lastBlock,,,) = oracle.oracleState(id);
        assertEq(lastBlock, block.number);
        assertEq(index, (beforeOracle.index + 1) % cardinality);
        assertEq(tick, _expectedOracleTick(beforeOracle, Currency.unwrap(key.currency0) == address(weth)));
        (uint32 timestamp, int56 ticks, uint160 liquidity, bool initialized) = oracle.observations(id, index);
        assertEq(timestamp, uint32(block.timestamp));
        assertTrue(initialized);
        unchecked {
            uint32 elapsed = timestamp - beforeOracle.timestamp;
            assertEq(ticks, beforeOracle.tickCumulative + int56(beforeOracle.tick) * int56(uint56(elapsed)));
            assertEq(liquidity, beforeOracle.liquidityCumulative
                + ((uint160(elapsed) << 128) / (beforeOracle.liquidity > 0 ? beforeOracle.liquidity : 1)));
        }
        // Reading exactly at the latest checkpoint returns its stored accumulators.
        uint32[] memory nowOnly = new uint32[](1);
        (int56[] memory observedTicks, uint160[] memory observedLiquidity) =
            oracle.observeTruncated(id, nowOnly);
        assertEq(observedTicks[0], ticks);
        assertEq(observedLiquidity[0], liquidity);
    }

    function _sameBlockTradeLeavesOracleUnchanged(Receipts memory received) private {
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        OracleBefore memory beforeOracle = _oracleBeforeSwap(key);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(weth);
        SwapParams memory params = SwapParams(zeroForOne, -int256(1 ether),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        TradeFee memory beforeFee = _tradeFeeBefore(key, params);
        SwapBalances memory balances = _snapshotSwapBalances(key, creator);
        vm.prank(creator);
        BalanceDelta delta = trader.trade(key, params);
        _assertSwapAccounting(manager, key, address(trader), creator, balances, delta);
        _assertTradeFee(key, params, delta, beforeFee);
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(received.hook);
        (uint16 index,,, int24 tick,,,,) = oracle.oracleState(received.poolId);
        assertEq(index, beforeOracle.index, "same-block swap must not advance the ring");
        assertEq(tick, beforeOracle.tick, "same-block swap must not reclamp the tick");
        (uint32 timestamp, int56 ticks, uint160 liquidity,) = oracle.observations(received.poolId, index);
        assertEq(timestamp, beforeOracle.timestamp);
        assertEq(ticks, beforeOracle.tickCumulative);
        assertEq(liquidity, beforeOracle.liquidityCumulative);
        _assertHookFeeBacking(manager, key);
    }

    function _assertOracleElapsedHistory(Receipts memory received) private {
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        OracleBefore memory previous = _oracleBeforeSwap(key);
        vm.warp(block.timestamp + 6);
        vm.roll(block.number + 1);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[1] = 6;
        (int56[] memory ticks, uint160[] memory liquidity) =
            ILaunchHookOracleV1(received.hook).observeTruncated(received.poolId, secondsAgos);
        assertEq(ticks[1], previous.tickCumulative);
        assertEq(liquidity[1], previous.liquidityCumulative);
        unchecked {
            assertEq(ticks[0], previous.tickCumulative + int56(previous.tick) * 6);
            assertEq(liquidity[0], previous.liquidityCumulative
                + ((uint160(6) << 128) / (previous.liquidity > 0 ? previous.liquidity : 1)));
        }
    }

    struct TradeFee {
        address asset;
        uint256 pending;
        uint24 rate;
        bool inputCurrency;
    }

    function _tradeFeeBefore(PoolKey memory key, SwapParams memory params)
        private view returns (TradeFee memory fee)
    {
        ILaunchHookV1 hook = ILaunchHookV1(address(key.hooks));
        ILaunchHookV1.PoolConfig memory config = hook.poolConfig(PoolId.unwrap(key.toId()));
        address input = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        fee.inputCurrency = config.feeMode == ILaunchHookV1.FeeMode.InputToken
            || input == Currency.unwrap(config.quoteCurrency);
        fee.asset = config.feeMode == ILaunchHookV1.FeeMode.InputToken
            ? input : Currency.unwrap(config.quoteCurrency);
        fee.pending = hook.pendingFees(PoolId.unwrap(key.toId()), fee.asset);
        fee.rate = IHookFeeRatePreviewFork(address(key.hooks)).feeRate(params);
        assertLe(fee.rate, config.hookFeePips);
        if (ILaunchHookAuthorTerms(address(key.hooks)).swapFeeModel() == ILaunchHookAuthorTerms.SwapFeeModel.Static) {
            assertEq(fee.rate, config.hookFeePips);
        }
    }

    function _assertTradeFee(PoolKey memory key, SwapParams memory params, BalanceDelta delta, TradeFee memory beforeFee)
        private view
    {
        uint256 charged = ILaunchHookV1(address(key.hooks)).pendingFees(PoolId.unwrap(key.toId()), beforeFee.asset)
            - beforeFee.pending;
        bool specifiedCurrency = (params.amountSpecified < 0) == beforeFee.inputCurrency;
        uint256 basis;
        if (specifiedCurrency) {
            basis = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
        } else if (beforeFee.inputCurrency) {
            int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
            basis = uint256(-int256(input)) - charged;
        } else {
            int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
            basis = uint256(uint128(output)) + charged;
        }
        assertEq(charged, FullMath.mulDiv(basis, beforeFee.rate, 1_000_000), "swap must charge the previewed frozen hook rate");
    }

    struct FeePreview {
        address asset;
        uint256 amount;
        uint256 treasuryBefore;
        uint256 executorBefore;
    }

    function _preview(PreparedMarketV1 memory prepared, address hub) private returns (FeePreview[] memory fees) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(hub);
        uint256[] memory amounts = V4FeeCollectorV2(prepared.feeSource).collect();
        address[] memory assets = V4FeeCollectorV2(prepared.feeSource).assets();
        assertTrue(vm.revertToState(snapshot));
        assertEq(assets.length, 2);
        assertEq(amounts.length, assets.length);
        fees = new FeePreview[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            fees[i] = FeePreview(assets[i], amounts[i], IERC20Fork(assets[i]).balanceOf(envelope.protocolTreasury), IERC20Fork(assets[i]).balanceOf(executor));
        }
    }

    function _claimAsset(ILaunchFeeHubV3 hub, FeePreview memory fee) private returns (uint256 ownerPaid, uint256 authorPaid) {
        uint256 bounty = FullMath.mulDiv(fee.amount, EXECUTOR_BPS, 10_000);
        uint256 expectedAuthor = FullMath.mulDiv(fee.amount - bounty, developerBps, 10_000);
        uint256 expectedOwner = fee.amount - bounty - expectedAuthor;
        IERC20Fork asset = IERC20Fork(fee.asset);
        assertEq(asset.balanceOf(executor) - fee.executorBefore, bounty);
        assertEq(hub.claimableDeveloperFees(author, fee.asset), expectedAuthor);
        assertEq(hub.claimableOwnerFees(creator, fee.asset), expectedOwner);
        uint256 ownerBefore = asset.balanceOf(creator);
        address payout = registry.authorPayout(author);
        uint256 authorBefore = asset.balanceOf(payout);
        vm.prank(executor);
        assertEq(hub.claimDeveloperFees(author, fee.asset), expectedAuthor);
        vm.prank(creator);
        if (expectedOwner == 0) {
            vm.expectRevert(bytes4(keccak256("NothingToClaim()")));
            hub.claimOwnerFees(fee.asset, creator);
        } else {
            assertEq(hub.claimOwnerFees(fee.asset, creator), expectedOwner);
        }
        authorPaid = asset.balanceOf(payout) - authorBefore;
        ownerPaid = asset.balanceOf(creator) - ownerBefore;
        assertEq(authorPaid, expectedAuthor);
        assertEq(ownerPaid, expectedOwner);
        assertEq(hub.reservedDeveloperFees(fee.asset), 0);
        assertEq(hub.reservedOwnerFees(fee.asset), 0);
        assertEq(hub.claimDeveloperFees(author, fee.asset), 0);
    }

    function _liquidity(PoolKey memory key, address token) private view returns (uint128) {
        int24 edge = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;
        bytes32 positionKey = Position.calculatePositionKey(address(locker), token < address(weth) ? int24(0) : -edge, token < address(weth) ? edge : int24(0), bytes32(uint256(1)));
        return StateLibrary.getPositionLiquidity(manager, key.toId(), positionKey);
    }

    function _harvestAndClaim(LaunchReceiptV1 memory receipt, PreparedMarketV1 memory prepared, PoolKey memory key) private returns (Receipts memory received) {
        ILaunchFeeHubV3 hub = ILaunchFeeHubV3(receipt.feeHub);
        ILaunchHookV1 hook = ILaunchHookV1(prepared.identity.hook);
        uint128 principal = _liquidity(key, receipt.token);
        assertGt(principal, 0);
        uint256 grossHook = hook.pendingFees(prepared.identity.poolId, address(weth));
        uint256 treasuryDue = hook.pendingTreasurySweeps(prepared.identity.poolId, address(weth));
        FeePreview[] memory fees = _preview(prepared, address(hub));
        for (uint256 i; i < fees.length; ++i) {
            assertEq(
                fees[i].amount + hook.pendingTreasurySweeps(prepared.identity.poolId, fees[i].asset),
                hook.pendingFees(prepared.identity.poolId, fees[i].asset),
                "canonical proceeds must contain hook fees only"
            );
        }
        vm.prank(executor);
        hub.claimAndSplit();
        received.token = receipt.token;
        received.hook = prepared.identity.hook;
        received.poolId = prepared.identity.poolId;
        for (uint256 i; i < fees.length; ++i) {
            (uint256 ownerPaid, uint256 authorPaid) = _claimAsset(hub, fees[i]);
            if (fees[i].asset == address(weth)) {
                received.treasuryPaid = IERC20Fork(fees[i].asset).balanceOf(envelope.protocolTreasury) - fees[i].treasuryBefore;
                assertEq(received.treasuryPaid, treasuryDue);
                received.ownerPaid = ownerPaid;
                received.authorPaid = authorPaid;
                uint256 bounty = FullMath.mulDiv(fees[i].amount, EXECUTOR_BPS, 10_000);
                received.expectedAuthorPaid = FullMath.mulDiv(fees[i].amount - bounty, developerBps, 10_000);
                received.expectedOwnerPaid = fees[i].amount - bounty - received.expectedAuthorPaid;
                received.hookFeesCollected = grossHook;
                assertEq(fees[i].amount + treasuryDue, grossHook);
                received.lpFeesCollected = fees[i].amount + treasuryDue - grossHook;
            }
            assertEq(hook.pendingFees(prepared.identity.poolId, fees[i].asset), 0);
        }
        assertTrue(locker.isSealed(prepared.identity.poolId));
        assertEq(_liquidity(key, receipt.token), principal);
        _assertHookFeeBacking(manager, key);
    }

    function _deployPublic(string memory name, bytes memory arguments) private returns (address target) {
        string memory path = vm.parseJsonString(manifest, string.concat(".creationCode.", name, ".path"));
        bytes memory creation = vm.parseBytes(vm.readLine(string.concat("contracts/config/", path)));
        assertEq(keccak256(creation), vm.parseJsonBytes32(manifest, string.concat(".creationCode.", name, ".creationCodeHash")));
        bytes memory initcode = bytes.concat(creation, arguments);
        assertLe(initcode.length, 49_152);
        assembly ("memory-safe") { target := create(0, add(initcode, 32), mload(initcode)) }
        assertGt(target.code.length, 0);
        assertLe(target.code.length, 24_576);
    }

    function _mine(address holder, bytes32 initCodeHash) private pure returns (bytes32) {
        bytes memory preimage = abi.encodePacked(bytes1(0xff), holder, bytes32(0), initCodeHash);
        for (uint256 i; i < 1_000_000; ++i) {
            uint160 flags;
            assembly ("memory-safe") {
                mstore(add(preimage, 0x35), i)
                flags := and(keccak256(add(preimage, 0x20), 85), 0x3fff)
            }
            if (flags == 0x1afc) return bytes32(i);
        }
        revert("salt search exhausted");
    }

    function _address(string memory name) private view returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".addresses.", name));
    }

    function _writeReceipts(Receipts memory received) private {
        string memory object = "launch";
        vm.serializeString(object, "schema", "abyss-hooks.launch-receipts.v1");
        vm.serializeAddress(object, "token", received.token);
        vm.serializeAddress(object, "hook", received.hook);
        vm.serializeBytes32(object, "poolId", received.poolId);
        vm.serializeAddress(object, "quoteAsset", address(weth));
        vm.serializeUint(object, "treasuryPaid", received.treasuryPaid);
        vm.serializeUint(object, "ownerPaid", received.ownerPaid);
        vm.serializeUint(object, "authorPaid", received.authorPaid);
        vm.serializeUint(object, "expectedOwnerPaid", received.expectedOwnerPaid);
        vm.serializeUint(object, "expectedAuthorPaid", received.expectedAuthorPaid);
        vm.serializeUint(object, "hookFeesCollected", received.hookFeesCollected);
        vm.serializeUint(object, "lpFeesCollected", received.lpFeesCollected);
        vm.serializeUint(object, "developerFeeBps", developerBps);
        ILaunchHookAuthorTerms terms = ILaunchHookAuthorTerms(received.hook);
        vm.serializeUint(object, "authorFeeBps", terms.authorFeeBps());
        vm.serializeUint(object, "swapFeeModel", uint256(terms.swapFeeModel()));
        string memory json = vm.serializeUint(object, "tradeCount", received.tradeCount);
        vm.writeJson(json, vm.envString("HOOK_RECEIPT_EVIDENCE"));
    }
}
