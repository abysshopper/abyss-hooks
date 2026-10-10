// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookLaunchFixture, LaunchRefusalStage, PoolKey, PoolId, PoolIdLibrary, Currency, IHooks, SwapParams, StateLibrary, TickMath, IERC20Fork, IContractOwnerFork, IHookFeeRatePreviewFork, ISourceCustodyFork, PoolBoundLaunchHookBaseV2, ILaunchHookV1, ILaunchHookOracleV1, PoolFeeCollectorFactoryV1, V4FeeLiquidityLockerV2, TruncatedOracle, PoolBoundHookParametersV2, V4MarketConfigV6, LaunchPlanV1, LaunchModeV1, LaunchPhaseV1, LaunchOperationV1, LaunchExecutionContextV1, LaunchProgressV1, PreparedMarketV1 } from "./HookLaunchFixture.sol";

/// @notice Maintainer-owned, nonvirtual mandatory checks inherited by each contributor smoke.
abstract contract HookSmokeTest is HookLaunchFixture {
    using PoolIdLibrary for PoolKey;

    constructor(string memory artifactDescriptor) HookLaunchFixture(artifactDescriptor) { }

    function testSmokeUnauthenticatedCallbacksAndCollectionRejected() public {
        (,, PoolKey memory key) = _launchWithPolicy(_firstFeeMode(), 4_100_001,
            launchScenario.minimumHookFeePips, launchScenario.maximumHookFeePips,
            launchScenario.feeSensitivityPipsSecondsPerTick, false);
        ILaunchHookV1 hook = ILaunchHookV1(address(key.hooks));
        ILaunchHookV1.PoolConfig memory config = hook.poolConfig(PoolId.unwrap(key.toId()));
        SwapParams memory params = _swapParams(Currency.unwrap(key.currency0) == address(quote),
            -int256(launchScenario.buyExactInputQuote));
        vm.expectRevert(PoolBoundLaunchHookBaseV2.Unauthorized.selector);
        hook.beforeSwap(address(trader), key, params, "");
        vm.expectRevert(PoolBoundLaunchHookBaseV2.Unauthorized.selector);
        hook.afterInitialize(address(adapter), key, launchScenario.sqrtPriceX96, 0);
        vm.expectRevert(PoolBoundLaunchHookBaseV2.Unauthorized.selector);
        hook.registerPool(key, config);
        vm.expectRevert(PoolBoundLaunchHookBaseV2.Unauthorized.selector);
        hook.completePoolOpening(key);
        vm.expectRevert(PoolBoundLaunchHookBaseV2.Unauthorized.selector);
        hook.collectFees(key);
        _assertHookFeeBacking(manager, key);
    }

    function testSmokeForeignPoolKeyRejectedByAuthenticatedCaller() public {
        (,, PoolKey memory key) = _launchWithPolicy(_firstFeeMode(), 4_200_001,
            launchScenario.minimumHookFeePips, launchScenario.maximumHookFeePips,
            launchScenario.feeSensitivityPipsSecondsPerTick, false);
        ILaunchHookV1 hook = ILaunchHookV1(address(key.hooks));
        SwapParams memory params = _swapParams(Currency.unwrap(key.currency0) == address(quote),
            -int256(launchScenario.buyExactInputQuote));
        key.fee = 1;
        vm.prank(address(manager));
        vm.expectRevert(PoolBoundLaunchHookBaseV2.InvalidPool.selector);
        hook.beforeSwap(address(trader), key, params, "");
        vm.expectRevert(PoolBoundLaunchHookBaseV2.InvalidPool.selector);
        hook.validateCollector(key, address(0), address(locker));
    }

    function testSmokeLaunchTradesAndExactRoyaltyClaims() public {
        uint256 flags = vm.envUint("HOOK_FEE_MODE_FLAGS");
        uint256 count = ((flags & 1) == 0 ? 0 : 1) + ((flags & 2) == 0 ? 0 : 1);
        Receipts[] memory modes = new Receipts[](count);
        uint256 index;
        for (uint8 mode; mode < 2; ++mode) {
            if ((flags & (uint256(1) << mode)) == 0) continue;
            modes[index++] = _scenario(mode, 100_001 + mode);
        }
        assertEq(index, count);
        assertGt(count, 0);
        _writeReceipts(modes);
    }
    function testSmokeLaunchRejectsPositionMaximumBudgetMismatch() public {
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 250_001, developerBps, launchScenario.maximumHookFeePips);
        V4MarketConfigV6 memory config = abi.decode(plan.markets[0].config, (V4MarketConfigV6));
        uint256 budget = plan.markets[0].tokenBudget;
        PoolFeeCollectorFactoryV1 factory = adapter.collectorFactory();
        for (uint256 i; i < 2; ++i) {
            config.positions[0].maxTokenAmount = i == 0 ? budget - 1 : budget + 1;
            plan.markets[0].config = abi.encode(config);
            address predictedToken = core.predictToken(plan);
            vm.expectRevert(bytes4(keccak256("InvalidConfiguration()")));
            factory.poolBoundHookParameters(address(adapter), predictedToken, plan.markets[0]);
        }
    }

    function testSmokeLaunchRejectsMarketBudgetsDifferentFromSupply() public {
        uint8 mode = _firstFeeMode();
        for (uint256 i; i < 2; ++i) {
            LaunchPlanV1 memory plan = _planWithFees(mode, 260_001 + i, developerBps, launchScenario.maximumHookFeePips);
            uint256 budget = i == 0 ? plan.token.supply - 1 : plan.token.supply + 1;
            V4MarketConfigV6 memory config = abi.decode(plan.markets[0].config, (V4MarketConfigV6));
            config.positions[0].maxTokenAmount = budget;
            plan.markets[0].tokenBudget = budget;
            plan.markets[0].config = abi.encode(config);
            (PoolBoundHookParametersV2 memory parameters,) = adapter.collectorFactory()
                .poolBoundHookParameters(address(adapter), core.predictToken(plan), plan.markets[0]);
            config.hookSalt = _mine(address(deployer), deployer.initCodeHash(parameters));
            plan.markets[0].config = abi.encode(config);
            vm.prank(creator);
            vm.expectRevert(bytes4(keccak256("InvalidMarket()")));
            core.beginLaunch(plan, LaunchModeV1.Staged);
        }
    }

    function testSmokeLaunchRejectsMissingOrMalformedCustodyDescriptor() public {
        uint8 mode = _firstFeeMode();
        for (uint256 i; i < 3; ++i) {
            uint256 snapshot = vm.snapshotState();
            LaunchPlanV1 memory plan = _planWithFees(mode, 270_001 + i, developerBps, launchScenario.maximumHookFeePips);
            vm.startPrank(creator);
            bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
            core.prepareMarkets(plan, 0, 1);
            vm.stopPrank();
            (, PreparedMarketV1 memory prepared) = core.directory().market(launchId, 0);
            bytes memory response = new bytes(i == 0 ? 0 : i == 1 ? 159 : 160);
            if (i == 2) response[0] = 0x01;
            vm.mockCall(prepared.feeSource, abi.encodeCall(ISourceCustodyFork.custodyRecipients, ()), response);
            vm.prank(creator);
            vm.expectRevert();
            core.activateLaunch(plan);
            assertFalse(core.isLaunchActive(launchId));
            assertEq(StateLibrary.getLiquidity(manager, PoolId.wrap(prepared.identity.poolId)), 0);
            vm.clearMockedCalls();
            require(vm.revertToStateAndDelete(snapshot), "restore custody descriptor boundary");
        }
    }

    function testSmokeLaunchRejectsReducedAuthorPayment() public {
        if (developerBps == 0) return;
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 200_001, developerBps - 1, launchScenario.maximumHookFeePips);
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

    function testSmokeRegisteredPayoutReceivesHookRoyalties() public {
        uint8 mode = _firstFeeMode();
        address payout = makeAddr("registered author payout");
        vm.prank(author);
        registry.setAuthorPayout(author, payout);
        Receipts memory received = _scenario(mode, 300_001);
        assertEq(received.lpFeesCollected, 0);
        assertEq(received.authorPaid, received.expectedAuthorPaid);
        assertEq(received.ownerPaid, received.expectedOwnerPaid);
        assertEq(quote.balanceOf(payout), received.authorPaid);
        assertEq(quote.balanceOf(author), 0, "stable identity is not the payout destination");
    }

    function testSmokeConfiguredZeroHookFeeIsFree() public {
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 400_001, developerBps, 0);
        (LaunchRefusalStage stage, bytes memory reason) = _expectedZeroFeeLaunchRevert(plan);
        if (reason.length != 0) {
            _assertZeroFeeLaunchRefusal(plan, stage, reason);
            return;
        }
        Receipts memory received = _scenarioWithFees(mode, 400_001, 0);
        assertEq(received.hookFeesCollected, 0);
        assertEq(received.lpFeesCollected, 0);
        assertEq(received.treasuryPaid, 0);
        assertEq(received.authorPaid, 0);
        assertEq(received.ownerPaid, 0);
    }

    function _assertZeroFeeLaunchRefusal(LaunchPlanV1 memory plan, LaunchRefusalStage stage, bytes memory reason)
        private
    {
        (PoolBoundHookParametersV2 memory parameters, bytes32 salt) = adapter.collectorFactory()
            .poolBoundHookParameters(address(adapter), core.predictToken(plan), plan.markets[0]);
        address hook = deployer.predict(parameters, salt);
        vm.startPrank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        if (stage == LaunchRefusalStage.Activate) core.prepareMarkets(plan, 0, 1);
        vm.stopPrank();
        bytes32 beforeState = _zeroFeeLaunchStateHash(plan, hook);
        vm.prank(creator);
        vm.expectRevert(reason);
        if (stage == LaunchRefusalStage.Prepare) core.prepareMarkets(plan, 0, 1);
        else core.activateLaunch(plan);
        assertEq(_zeroFeeLaunchStateHash(plan, hook), beforeState,
            "configuration refusal must preserve funds, token inventory and candidate code");
        assertFalse(core.isLaunchActive(launchId));
        if (stage == LaunchRefusalStage.Prepare) assertEq(core.readLaunchProgress(launchId).preparedMarkets, 0);
        else {
            (, PreparedMarketV1 memory prepared) = core.directory().market(launchId, 0);
            assertEq(StateLibrary.getLiquidity(manager, PoolId.wrap(prepared.identity.poolId)), 0);
        }
        emit log_named_bytes("expected zero-fee configuration rejection", reason);
    }

    function _zeroFeeLaunchStateHash(LaunchPlanV1 memory plan, address hook) private view returns (bytes32) {
        address token = core.predictToken(plan);
        return keccak256(abi.encode(hook.codehash, vm.getNonce(hook), deployer.deployedCodeHash(hook),
            token.codehash, vm.getNonce(token), address(quote).codehash,
            _launchAssetBalancesHash(token, hook), _launchAssetBalancesHash(address(quote), hook)));
    }

    function _launchAssetBalancesHash(address asset, address hook) private view returns (bytes32) {
        if (asset.code.length == 0) return bytes32(0);
        IERC20Fork token = IERC20Fork(asset);
        return keccak256(abi.encode(token.balanceOf(creator), token.balanceOf(address(core)),
            token.balanceOf(core.fundingEscrow()), token.balanceOf(address(manager)),
            token.balanceOf(address(locker)), token.balanceOf(hook)));
    }

    function testSmokeLaunchRejectsNonzeroPoolLPFee() public {
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithPoolFee(mode, 500_001, developerBps, launchScenario.maximumHookFeePips, 3_000);
        vm.startPrank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        vm.expectRevert();
        core.prepareMarkets(plan, 0, 1);
        vm.stopPrank();
        assertFalse(core.isLaunchActive(launchId));
        assertEq(core.readLaunchProgress(launchId).preparedMarkets, 0);
    }

    function testSmokeTradingRejectsPoolManagerProtocolFee() public {
        uint8 mode = _firstFeeMode();
        Receipts memory received = _scenario(mode, 600_001);
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        vm.prank(IContractOwnerFork(address(manager)).owner());
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 100);
        SwapBalances memory beforeBalances = _snapshotSwapBalances(key, creator);
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(quote);
        SwapParams memory params = _swapParams(buyZeroForOne, -int256(launchScenario.buyExactInputQuote));
        bytes memory hookData = _swapHookData(key, params, creator);
        vm.expectRevert();
        IHookFeeRatePreviewFork(received.hook).feeRate(params);
        vm.prank(creator);
        vm.expectRevert();
        trader.trade(key, params, hookData);
        assertEq(IERC20Fork(Currency.unwrap(key.currency0)).balanceOf(creator), beforeBalances.amount0);
        assertEq(IERC20Fork(Currency.unwrap(key.currency1)).balanceOf(creator), beforeBalances.amount1);
        _assertHookFeeBacking(manager, key);
    }
    function testSmokeOptionalOracleComposition() public {
        uint8 mode = _firstFeeMode();
        Receipts memory received = _scenario(mode, 700_001);
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
        assertLe(cardinality, next, "prepared capacity need not be fully populated");
        oracle.increaseObservationCardinalityNext(received.poolId, type(uint16).max);
        (,, next,,,,,) = oracle.oracleState(received.poolId);
        assertEq(next, cap, "growth must respect the frozen registry cap");
        uint32[] memory tooOld = new uint32[](1);
        tooOld[0] = uint32(block.timestamp - hook.oracleInitializedAt(received.poolId) + 1);
        vm.expectRevert(TruncatedOracle.ObservationTooOld.selector);
        oracle.observeTruncated(received.poolId, tooOld);
    }

    function testSmokeNoOracleHistoryBeforePoolInitialization() public {
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 800_001, developerBps, launchScenario.maximumHookFeePips);
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
    function testSmokeRegistrationAcceptsLifecycleGetterTrailingData() public {
        _probeLifecycleGetter(0);
    }

    function testSmokeRegistrationRejectsDirtyUnusedLifecycleWords() public {
        for (uint256 scenario = 1; scenario <= 5; ++scenario) _probeLifecycleGetter(scenario);
    }

    function _probeLifecycleGetter(uint256 scenario) private {
        uint256 snapshot = vm.snapshotState();
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 1_500_001 + scenario, developerBps, launchScenario.maximumHookFeePips);
        PoolBoundLaunchHookBaseV2 hook = _predeployPlannedHook(plan);
        vm.prank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        LaunchProgressV1 memory progress = core.readLaunchProgress(launchId);
        progress.phase = LaunchPhaseV1.Preparing;
        bytes memory contextReply = abi.encode(LaunchExecutionContextV1(
            launchId, 0, LaunchOperationV1.Prepare, address(adapter), address(adapter),
            progress.token, address(quote), address(manager), address(0), address(0), 0
        ));
        bytes memory progressReply = abi.encode(progress);
        if (scenario == 0) {
            contextReply = bytes.concat(contextReply, abi.encode(uint256(123)));
            progressReply = bytes.concat(progressReply, abi.encode(uint256(123)));
        } else if (scenario <= 2) {
            // Unused context custody/recipient still require canonical address words.
            assembly ("memory-safe") { mstore(add(contextReply, add(0x100, mul(scenario, 0x20))), shl(160, 1)) }
        } else if (scenario == 3) {
            assembly ("memory-safe") { mstore(add(progressReply, 0x60), shl(160, 1)) }
        } else {
            // Unused preparedMarkets/buyCount still require canonical uint32 words.
            uint256 offset = scenario == 4 ? 0x140 : 0x180;
            assembly ("memory-safe") { mstore(add(progressReply, offset), shl(32, 1)) }
        }
        vm.mockCall(address(core), abi.encodeWithSignature("executionContext()"), contextReply);
        vm.mockCall(address(core), abi.encodeWithSignature("readLaunchProgress(bytes32)", launchId), progressReply);
        vm.prank(creator);
        if (scenario != 0) vm.expectRevert();
        core.prepareMarkets(plan, 0, 1);
        assertEq(hook.registered(hook.boundPoolId()), scenario == 0);
        vm.clearMockedCalls();
        require(vm.revertToStateAndDelete(snapshot), "restore isolated lifecycle getter scenario");
    }

    function testSmokeRegistrationAcceptsStructuredGetterLayouts() public {
        for (uint256 scenario; scenario < 4; ++scenario) _probeCollectorGetter(scenario);
    }

    function testSmokeRegistrationRejectsMalformedStructuredGetters() public {
        for (uint256 scenario = 4; scenario < 23; ++scenario) _probeCollectorGetter(scenario);
    }

    function testSmokeRegistrationBubblesStructuredGetterReverts() public {
        _probeCollectorGetter(23);
        _probeCollectorGetter(24);
    }

    function _probeCollectorGetter(uint256 scenario) private {
        uint256 snapshot = vm.snapshotState();
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 1_300_001 + scenario, developerBps, launchScenario.maximumHookFeePips);
        PoolBoundLaunchHookBaseV2 hook = _predeployPlannedHook(plan);
        PoolKey memory key = hook.poolKey(hook.boundPoolId());
        vm.prank(creator);
        bytes32 launchId = core.beginLaunch(plan, LaunchModeV1.Staged).launchId;
        address creatorContract = collectorDeployer;
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

    function testSmokeRegistrationRejectsMalformedGetterWords() public {
        uint8 mode = _firstFeeMode();
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            LaunchPlanV1 memory plan = _planWithFees(mode, 900_001 + i, developerBps, launchScenario.maximumHookFeePips);
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

    function testSmokeRegistrationBubblesGetterRevert() public {
        uint8 mode = _firstFeeMode();
        LaunchPlanV1 memory plan = _planWithFees(mode, 1_000_001, developerBps, launchScenario.maximumHookFeePips);
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

    function testSmokeRegistrationAcceptsCleanGetterWithTrailingData() public {
        uint8 mode = _firstFeeMode();
        _predeployPlannedHook(_planWithFees(mode, 1_100_001, developerBps, launchScenario.maximumHookFeePips));
        vm.mockCall(address(locker), abi.encodeCall(V4FeeLiquidityLockerV2.launcher, ()),
            abi.encode(address(adapter), bytes32(uint256(123))));
        Receipts memory received = _scenario(mode, 1_100_001);
        assertEq(received.authorPaid, received.expectedAuthorPaid);
        assertEq(received.ownerPaid, received.expectedOwnerPaid);
        assertEq(received.lpFeesCollected, 0);
    }
}
