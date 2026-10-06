// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { IAbyssLaunchFactory } from "../src/interfaces/IAbyssLaunch.sol";
import { LaunchOrchestratorV1, LaunchImplementationRegistryV2, PoolMarketAdapterV1, PoolFeeCollectorFactoryV1, V4FeeCollectorV2 } from "../src/interfaces/IForkLaunch.sol";
import { PoolHookDeployerV1 } from "../src/hooks/v4/authoring/PoolHookDeployerV1.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";
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

contract HookLaunchTest is Test {
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
        LaunchPlanV1 memory plan = _plan(mode, nonce);
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
        vm.prank(creator);
        assertTrue(IERC20Fork(receipt.token).approve(address(trader), type(uint256).max));
        _trade(key, prepared.identity.currency0 == address(weth), -int256(10 ether));
        _trade(key, prepared.identity.currency0 == receipt.token, -int256(5 ether));
        _trade(key, prepared.identity.currency0 == address(weth), int256(1 ether));
        _trade(key, prepared.identity.currency0 == receipt.token, int256(1 ether));
        received = _harvestAndClaim(receipt, prepared, key);
        received.tradeCount = 4;
    }

    function _plan(uint8 mode, uint256 nonce) private view returns (LaunchPlanV1 memory plan) {
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
        config.lpFeePips = 3_000;
        config.tickSpacing = envelope.bounds.minimumTickSpacing;
        config.sqrtPriceX96 = uint160(1 << 96);
        config.hookFeePips = 10_000;
        config.feeMode = mode;
        config.protocolFeeDenominator = envelope.protocolFeeDenominator;
        config.treasury = envelope.protocolTreasury;
        config.externalLiquidityDisabled = true;
        config.oracleConfigId = oracleId;
        config.profileId = profileId;
        config.termsDigest = envelope.termsDigest;
        config.developerBeneficiary = author;
        config.developerFeeBps = developerBps;
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
        vm.prank(creator);
        BalanceDelta delta = trader.trade(key, SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        assertLt(input, 0);
        assertGt(output, 0);
        if (amount < 0) assertEq(int256(input), amount);
        else assertEq(int256(output), amount);
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
        uint256 authorBefore = asset.balanceOf(author);
        vm.prank(executor);
        assertEq(hub.claimDeveloperFees(author, fee.asset), expectedAuthor);
        vm.prank(creator);
        assertEq(hub.claimOwnerFees(fee.asset, creator), expectedOwner);
        authorPaid = asset.balanceOf(author) - authorBefore;
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
        vm.prank(executor);
        hub.claimAndSplit();
        received.token = receipt.token;
        received.hook = prepared.identity.hook;
        received.poolId = prepared.identity.poolId;
        for (uint256 i; i < fees.length; ++i) {
            (uint256 ownerPaid, uint256 authorPaid) = _claimAsset(hub, fees[i]);
            if (fees[i].asset == address(weth)) {
                assertGt(fees[i].amount, 0);
                received.treasuryPaid = IERC20Fork(fees[i].asset).balanceOf(envelope.protocolTreasury) - fees[i].treasuryBefore;
                assertEq(received.treasuryPaid, treasuryDue);
                received.ownerPaid = ownerPaid;
                received.authorPaid = authorPaid;
                uint256 bounty = FullMath.mulDiv(fees[i].amount, EXECUTOR_BPS, 10_000);
                received.expectedAuthorPaid = FullMath.mulDiv(fees[i].amount - bounty, developerBps, 10_000);
                received.expectedOwnerPaid = fees[i].amount - bounty - received.expectedAuthorPaid;
                received.hookFeesCollected = grossHook;
                assertGe(fees[i].amount + treasuryDue, grossHook);
                received.lpFeesCollected = fees[i].amount + treasuryDue - grossHook;
            }
            assertEq(hook.pendingFees(prepared.identity.poolId, fees[i].asset), 0);
        }
        assertTrue(locker.isSealed(prepared.identity.poolId));
        assertEq(_liquidity(key, receipt.token), principal);
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
        string memory json = vm.serializeUint(object, "tradeCount", received.tradeCount);
        vm.writeJson(json, vm.envString("HOOK_RECEIPT_EVIDENCE"));
    }
}
