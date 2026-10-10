// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookOracleAssertions } from "./HookOracleAssertions.sol";
import { NativeLaunchGraphFixture } from "./NativeLaunchGraphFixture.sol";
import { Vm } from "forge-std/Vm.sol";
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
import { PoolBoundHookParametersV2 } from "../src/hooks/v4/PoolBoundHookParametersV2.sol";
import { V4FeeLiquidityLockerV2 } from "../src/launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import { FeeAssetPolicyV2 } from "../src/launch/fees/v2/ILaunchFeeHubV2.sol";
import { ILaunchFeeHubV3 } from "../src/launch/fees/v3/ILaunchFeeHubV3.sol";
import { LaunchEnvelopeV2, LaunchBoundsV2 } from "../src/launch/lifecycle/v2/ILaunchRegistryV2.sol";
import { V4MarketConfigV6 } from "../src/launch/lifecycle/v2/V4MarketConfigV6.sol";
import { V4PositionConfigV1 } from "../src/launch/lifecycle/v1/V4MarketConfigV2.sol";
import { LaunchPlanV1, TokenConfigV1, TokenKindV1, RewardModeV1, AssetFundingV1, FundingKindV1, MarketConfigV1, InitialBuyV1, LaunchModeV1, LaunchPhaseV1, LaunchOperationV1, LaunchExecutionContextV1, LaunchProgressV1, LaunchReceiptV1, PreparedMarketV1, ProfileRegistrationV1 } from "../src/launch/lifecycle/v1/LaunchTypesV1.sol";
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

interface ILaunchSupplyFork {
    function totalSupply() external view returns (uint256);
}

interface ISourceCustodyFork {
    function custodyRecipients() external view returns (address[5] memory);
}

/// @notice Test-only whole-launch call boundary, distinct from core callback operations.
enum LaunchRefusalStage { Prepare, Activate }

/// @notice Test-side raw units and creator-selected policy, not a production hook ABI.
struct LaunchScenario {
    address quoteAsset;
    uint256 quoteFunding;
    uint256 launchFunding;
    uint256 tokenSupply;
    uint128 liquidity;
    uint160 sqrtPriceX96;
    int24 tickSpacing;
    int24 lowerTick;
    int24 upperTick;
    uint24 minimumHookFeePips;
    uint24 maximumHookFeePips;
    uint32 feeSensitivityPipsSecondsPerTick;
    uint24 oracleMaximumTickMove;
    uint16 oracleCardinality;
    uint16 preparedOracleCardinality;
    uint256 openingBuyQuote;
    uint256 buyExactInputQuote;
    uint256 sellExactInputBase;
    uint256 buyExactOutputBase;
    uint256 sellExactOutputQuote;
    uint32 swapTimeStep;
    uint256 quoteDonation;
}

/// @notice Real native launch, exact typed CREATE2 candidate and reusable accounting assertions.
abstract contract HookLaunchFixture is HookOracleAssertions, NativeLaunchGraphFixture {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    uint256 private constant AUTHOR_KEY = 0xa110ce;
    uint16 internal constant EXECUTOR_BPS = 275;
    uint256 private rejectionTraceEpoch;
    mapping(bytes32 slotKey => uint256 epoch) private rejectionTraceSeen;
    string public hookArtifactDescriptor;
    string internal manifest;
    LaunchOrchestratorV1 internal core;
    LaunchImplementationRegistryV2 internal registry;
    IPoolManager internal manager;
    PoolMarketAdapterV1 internal adapter;
    PoolHookDeployerV1 internal deployer;
    V4FeeLiquidityLockerV2 internal locker;
    LaunchEnvelopeV2 internal envelope;
    LaunchScenario internal launchScenario;
    bytes32 internal profileId;
    bytes32 internal adapterId;
    bytes32 internal oracleId;
    address internal author;
    address internal creator;
    address internal executor;
    IWETHFork internal wrappedNative;
    IERC20Fork internal quote;
    ForkTrader internal trader;
    uint16 internal developerBps;
    address internal collectorFactory;
    address internal collectorDeployer;

    struct SwapCase {
        bool buy;
        bool exactInput;
        bool rejected;
        int256 amountSpecified;
        bytes expectedRevert;
        uint256 inputAmount;
        uint256 outputAmount;
        address feeAsset;
        uint256 feePaid;
        uint24 ratePips;
    }

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
        uint8 feeMode;
        uint128 principalBefore;
        uint128 principalAfter;
        SwapCase[] cases;
    }

    constructor(string memory artifactDescriptor) {
        require(bytes(artifactDescriptor).length != 0, "hook artifact descriptor required");
        hookArtifactDescriptor = artifactDescriptor;
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
        envelope = LaunchImplementationRegistryV2(_address("registry"))
            .profileEnvelope(vm.parseJsonBytes32(manifest, ".referenceProfileId"));
        manager = IPoolManager(_address("manager"));
        wrappedNative = IWETHFork(_address("wrappedNative"));
        developerBps = uint16(vm.envUint("HOOK_MAX_DEVELOPER_BPS"));
        author = vm.addr(AUTHOR_KEY);
        creator = makeAddr("hook launch creator");
        executor = makeAddr("hook fee executor");
        _setUpPrerequisites();
        launchScenario = _configureScenario();
        quote = IERC20Fork(launchScenario.quoteAsset);
        _assertScenarioBounds();
        oracleId = keccak256(abi.encode(launchScenario.oracleMaximumTickMove, launchScenario.oracleCardinality));
        (uint24 movement,) = IAbyssLaunchFactory(_address("oracleFactory")).oracleConfigs(oracleId);
        if (movement == 0) {
            IOracleAdminFork oracle = IOracleAdminFork(_address("oracleFactory"));
            vm.prank(oracle.owner());
            assertEq(oracle.registerOracleConfig(IOracleAdminFork.OracleConfig(
                launchScenario.oracleMaximumTickMove, launchScenario.oracleCardinality)), oracleId);
        }
        NativeLaunchGraph memory graph = _deployNativeLaunchGraph(
            manager, IAbyssLaunchFactory(_address("oracleFactory")), address(wrappedNative), oracleId, developerBps
        );
        core = LaunchOrchestratorV1(graph.core);
        registry = LaunchImplementationRegistryV2(graph.registry);
        collectorFactory = graph.collectorFactory;
        collectorDeployer = graph.collectorDeployer;
        assertEq(address(core.registry()), address(registry));
        assertEq(address(registry.core()), address(core));
        require(developerBps <= registry.protocolMaximumDeveloperFeeBps(), "developer ceiling exceeds deployed protocol maximum");
        _admitCandidate();
        trader = new ForkTrader(manager);
        _fundQuote(creator, launchScenario.quoteFunding);
        vm.startPrank(creator);
        assertTrue(quote.approve(core.fundingEscrow(), type(uint256).max));
        assertTrue(quote.approve(address(trader), type(uint256).max));
        vm.stopPrank();
    }

    function _setUpPrerequisites() internal virtual { }

    function _configureScenario() internal virtual returns (LaunchScenario memory) {
        return _defaultScenario();
    }

    function _defaultScenario() internal view returns (LaunchScenario memory selected) {
        selected.quoteAsset = address(wrappedNative);
        selected.quoteFunding = 2_000 ether;
        selected.launchFunding = 497 ether;
        selected.tokenSupply = 3_100 ether;
        selected.liquidity = 1_000 ether;
        selected.sqrtPriceX96 = uint160(1 << 96);
        selected.tickSpacing = int24(int256(vm.envUint("HOOK_MIN_TICK_SPACING")));
        selected.upperTick = (TickMath.MAX_TICK / selected.tickSpacing) * selected.tickSpacing;
        selected.minimumHookFeePips = 750;
        selected.maximumHookFeePips = 10_000;
        selected.feeSensitivityPipsSecondsPerTick = 15_000;
        selected.oracleMaximumTickMove = 17;
        selected.oracleCardinality = uint16(vm.envUint("HOOK_MAX_ORACLE_CARDINALITY"));
        selected.preparedOracleCardinality = selected.oracleCardinality < 3 ? selected.oracleCardinality : 3;
        selected.openingBuyQuote = 200 ether;
        selected.buyExactInputQuote = 10 ether;
        selected.sellExactInputBase = 5 ether;
        selected.buyExactOutputBase = 1 ether;
        selected.sellExactOutputQuote = 1 ether;
        selected.swapTimeStep = 12;
        selected.quoteDonation = 17;
    }

    function _assertScenarioBounds() private view {
        require(launchScenario.quoteAsset.code.length != 0, "quote requires actual token code");
        require(launchScenario.tickSpacing >= int256(vm.envUint("HOOK_MIN_TICK_SPACING"))
            && launchScenario.tickSpacing <= int256(vm.envUint("HOOK_MAX_TICK_SPACING")), "scenario tick spacing exceeds declaration");
        require(vm.envUint("HOOK_MAX_POSITIONS") >= 1, "scenario requires one declared position");
        require(launchScenario.minimumHookFeePips <= launchScenario.maximumHookFeePips
            && launchScenario.maximumHookFeePips <= 1_000_000, "invalid scenario fee bounds");
        require(launchScenario.oracleCardinality >= 2
            && launchScenario.oracleCardinality <= vm.envUint("HOOK_MAX_ORACLE_CARDINALITY"), "scenario oracle exceeds declaration");
        require(launchScenario.preparedOracleCardinality <= launchScenario.oracleCardinality,
            "prepared oracle capacity exceeds configured cap");
        require(launchScenario.oracleMaximumTickMove != 0
            && launchScenario.oracleMaximumTickMove <= uint24(uint256(int256(TickMath.MAX_TICK))), "invalid oracle movement");
        require((vm.envUint("HOOK_FEE_MODE_FLAGS") & 3) != 0
            && vm.envUint("HOOK_FEE_MODE_FLAGS") <= 3, "invalid declared fee modes");
    }

    function _fundQuote(address payer, uint256 rawAmount) internal virtual {
        require(address(quote) == address(wrappedNative), "override quote funding for non-wrapped-native token");
        vm.deal(payer, rawAmount);
        vm.prank(payer);
        wrappedNative.deposit{value: rawAmount}();
    }

    function _swapHookData(PoolKey memory, SwapParams memory, address) internal virtual returns (bytes memory) {
        return "";
    }

    function _expectedSwapRevert(PoolKey memory, SwapParams memory, address)
        internal view virtual returns (bytes memory)
    {
        return "";
    }

    function _expectedZeroFeeLaunchRevert(LaunchPlanV1 memory)
        internal view virtual returns (LaunchRefusalStage stage, bytes memory reason)
    {
        return (LaunchRefusalStage.Prepare, "");
    }

    function _firstFeeMode() internal view returns (uint8) {
        return (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
    }
    function _predeployPlannedHook(LaunchPlanV1 memory plan) internal returns (PoolBoundLaunchHookBaseV2) {
        (PoolBoundHookParametersV2 memory parameters, bytes32 salt) =
            adapter.collectorFactory().poolBoundHookParameters(address(adapter), core.predictToken(plan), plan.markets[0]);
        return deployer.deploy(parameters, salt);
    }
    function _admitCandidate() private {
        bytes memory creation = vm.getCode(vm.envString("HOOK_ARTIFACT"));
        assertEq(keccak256(creation), keccak256(vm.getCode(hookArtifactDescriptor)),
            "selected artifact differs from smoke constructor descriptor");
        deployer = new PoolHookDeployerV1(creation);
        envelope.configVersion = 6;
        envelope.graph.coreCodeHash = address(core).codehash;
        envelope.graph.collectorFactory = collectorFactory;
        envelope.graph.collectorFactoryCodeHash = collectorFactory.codehash;
        envelope.graph.collectorDeployer = collectorDeployer;
        envelope.graph.collectorDeployerCodeHash = collectorDeployer.codehash;
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
        locker = V4FeeLiquidityLockerV2(_deployNativeActor(
            "contracts/protocol/src/launch/fees/v2/V4FeeLiquidityLockerV2.sol:V4FeeLiquidityLockerV2",
            abi.encode(manager, predictedAdapter)
        ));
        adapter = PoolMarketAdapterV1(_deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v2/NativePoolMarketAdapterV1.sol:NativePoolMarketAdapterV1",
            abi.encode(core, manager, _address("oracleFactory"), locker, deployer, collectorFactory, registry, profileId)
        ));
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
        registry.registerAdapter(adapterId, address(adapter), envelope.capabilities, 6);
        registry.registerProfile(profileId, registration, envelope, nonce, deadline, abi.encodePacked(r, s, v));
        if (!registry.fundingInputAllowed(address(quote))) registry.setFundingInputAllowed(address(quote), true);
        vm.stopPrank();
    }

    function _scenario(uint8 mode, uint256 nonce) internal returns (Receipts memory received) {
        return _scenarioWithPolicy(mode, nonce, launchScenario.minimumHookFeePips,
            launchScenario.maximumHookFeePips, launchScenario.feeSensitivityPipsSecondsPerTick);
    }

    function _scenarioWithFees(uint8 mode, uint256 nonce, uint24 hookPips)
        internal returns (Receipts memory received)
    {
        uint24 minimum = launchScenario.minimumHookFeePips < hookPips ? launchScenario.minimumHookFeePips : hookPips;
        return _runScenarioWithPolicy(mode, nonce, minimum, hookPips,
            launchScenario.feeSensitivityPipsSecondsPerTick, hookPips != 0);
    }

    function _scenarioWithPolicy(uint8 mode, uint256 nonce, uint24 minimum, uint24 hookPips, uint32 sensitivity)
        internal returns (Receipts memory received)
    {
        return _runScenarioWithPolicy(mode, nonce, minimum, hookPips, sensitivity, true);
    }

    function _runScenarioWithPolicy(uint8 mode, uint256 nonce, uint24 minimum, uint24 hookPips, uint32 sensitivity,
        bool requireSuccess) private returns (Receipts memory received)
    {
        (LaunchReceiptV1 memory receipt, PreparedMarketV1 memory prepared, PoolKey memory key) =
            _launchWithPolicy(mode, nonce, minimum, hookPips, sensitivity, true);
        SwapCase[] memory cases = new SwapCase[](4);
        cases[0] = _evaluateSwap(key, true, -_signedAmount(launchScenario.buyExactInputQuote));
        cases[1] = _evaluateSwap(key, false, -_signedAmount(launchScenario.sellExactInputBase));
        cases[2] = _evaluateSwap(key, true, _signedAmount(launchScenario.buyExactOutputBase));
        cases[3] = _evaluateSwap(key, false, _signedAmount(launchScenario.sellExactOutputQuote));
        vm.prank(creator);
        assertTrue(quote.transfer(prepared.identity.hook, launchScenario.quoteDonation));
        _assertHookFeeBacking(manager, key);
        received = _harvestAndClaim(receipt, prepared, key);
        assertEq(quote.balanceOf(prepared.identity.hook), launchScenario.quoteDonation, "donations must not become fees");
        received.feeMode = mode;
        received.cases = cases;
        uint256 buys;
        uint256 sells;
        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].rejected) continue;
            ++received.tradeCount;
            if (cases[i].buy) ++buys;
            else ++sells;
        }
        if (requireSuccess) assertGt(received.tradeCount, 0, "each declared fee mode must execute an actual supported trade");
        emit log_named_uint("fee mode", mode);
        emit log_named_uint("successful buy branches", buys);
        emit log_named_uint("successful sell branches", sells);
        emit log_named_uint("rejected branches", cases.length - received.tradeCount);
    }

    function _signedAmount(uint256 amount) private pure returns (int256) {
        require(amount != 0 && amount <= uint256(type(int256).max), "positive representable raw trade amount required");
        return int256(amount);
    }

    function _swapParams(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _evaluateSwap(PoolKey memory key, bool buy, int256 amount) private returns (SwapCase memory result) {
        vm.warp(block.timestamp + launchScenario.swapTimeStep);
        vm.roll(block.number + 1);
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(quote);
        SwapParams memory params = _swapParams(buy ? buyZeroForOne : !buyZeroForOne, amount);
        bytes memory expected = _expectedSwapRevert(key, params, creator);
        if (expected.length == 0) result = _successfulSwap(key, params, creator);
        else {
            result.expectedRevert = _assertRejectedSwap(key, params, creator,
                _swapHookData(key, params, creator), expected);
            result.rejected = true;
        }
        result.buy = buy;
        result.exactInput = amount < 0;
        result.amountSpecified = amount;
        emit log_string(buy ? "buy coverage" : "sell coverage");
        emit log_string(amount < 0 ? "exact-input" : "exact-output");
        emit log_string(result.rejected ? "rejected" : "success");
    }

    function _assertRejectedSwap(PoolKey memory key, SwapParams memory params, address payer,
        bytes memory hookData, bytes memory expected) internal returns (bytes memory reason)
    {
        assertGt(expected.length, 0, "policy refusal requires exact expected revert bytes");
        SwapBalances memory balances = _snapshotSwapBalances(key, payer);
        bytes32 beforeState = _swapStateHash(key);
        vm.startStateDiffRecording();
        vm.prank(payer);
        bool success;
        (success, reason) = address(trader).call(abi.encodeCall(ForkTrader.trade, (key, params, hookData)));
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _assertRevertedStorage(accesses);
        assertFalse(success, "declared policy refusal must actually revert");
        assertEq(reason, expected, "policy refusal must match the exact declared revert");
        SwapBalances memory afterBalances = _snapshotSwapBalances(key, payer);
        assertEq(afterBalances.amount0, balances.amount0, "refusal must not spend or credit currency0");
        assertEq(afterBalances.amount1, balances.amount1, "refusal must not spend or credit currency1");
        assertEq(_swapStateHash(key), beforeState, "refusal must preserve pool and fee liabilities");
        _assertHookFeeBacking(manager, key);
        emit log_named_bytes("expected policy rejection", reason);
    }

    function _assertRevertedStorage(Vm.AccountAccess[] memory accesses) private {
        uint256 epoch = ++rejectionTraceEpoch;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory accessed = accesses[i].storageAccesses[j];
                bytes32 slotKey = keccak256(abi.encode(accessed.account, accessed.slot));
                if (rejectionTraceSeen[slotKey] == epoch) continue;
                rejectionTraceSeen[slotKey] = epoch;
                assertEq(vm.load(accessed.account, accessed.slot), accessed.previousValue,
                    "refusal must restore every observed storage slot, including the frozen fee context");
            }
        }
    }

    function _swapStateHash(PoolKey memory key) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, StateLibrary.getLiquidity(manager, key.toId()),
            _assetLiabilityHash(key, key.currency0), _assetLiabilityHash(key, key.currency1),
            address(key.hooks).codehash, vm.getNonce(address(key.hooks)), _oracleStateHash(key)));
    }

    function _oracleStateHash(PoolKey memory key) private view returns (bytes32) {
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) return bytes32(0);
        OracleBefore memory observed = _oracleBeforeSwap(manager, key);
        bytes32 id = PoolId.unwrap(key.toId());
        (, uint16 cardinality, uint16 next,,,,, uint16 cap) = ILaunchHookOracleV1(address(key.hooks)).oracleState(id);
        return keccak256(abi.encode(observed, cardinality, next, cap,
            ILaunchHookV1(address(key.hooks)).oracleInitializedAt(id)));
    }

    function _assetLiabilityHash(PoolKey memory key, Currency currency) private view returns (bytes32) {
        ILaunchHookV1 hook = ILaunchHookV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        address asset = Currency.unwrap(currency);
        return keccak256(abi.encode(hook.pendingFees(id, asset), hook.settledFees(id, asset),
            hook.aggregateLiabilities(asset), hook.aggregateManagerClaims(asset), hook.pendingTreasurySweeps(id, asset),
            manager.balanceOf(address(hook), uint160(asset)), IERC20Fork(asset).balanceOf(address(hook))));
    }

    function _launchWithPolicy(uint8 mode, uint256 nonce, uint24 minimum, uint24 hookPips, uint32 sensitivity, bool openingBuy)
        internal returns (LaunchReceiptV1 memory receipt, PreparedMarketV1 memory prepared, PoolKey memory key)
    {
        LaunchPlanV1 memory plan = _planWithFees(mode, nonce, developerBps, hookPips);
        if (!openingBuy) plan.buys = new InitialBuyV1[](0);
        V4MarketConfigV6 memory selected = abi.decode(plan.markets[0].config, (V4MarketConfigV6));
        selected.minimumHookFeePips = minimum;
        selected.feeSensitivityPipsSecondsPerTick = sensitivity;
        plan.markets[0].config = abi.encode(selected);
        (PoolBoundHookParametersV2 memory parameters,) =
            adapter.collectorFactory().poolBoundHookParameters(address(adapter), core.predictToken(plan), plan.markets[0]);
        selected.hookSalt = _mine(address(deployer), deployer.initCodeHash(parameters));
        plan.markets[0].config = abi.encode(selected);
        vm.startPrank(creator);
        core.beginLaunch(plan, LaunchModeV1.Staged);
        core.prepareMarkets(plan, 0, 1);
        assertEq(IERC20Fork(core.predictToken(plan)).balanceOf(address(core)), plan.token.supply);
        receipt = core.activateLaunch(plan);
        vm.stopPrank();
        assertTrue(core.isLaunchActive(receipt.launchId));
        assertEq(uint256(core.readLaunchProgress(receipt.launchId).phase), uint256(LaunchPhaseV1.Active));
        assertEq(receipt.marketCount, 1);
        assertEq(receipt.positionCount, 1);
        _assertInventoryBurn(receipt.token, selected.positions[0]);
        (, prepared) = core.directory().market(receipt.launchId, 0);
        {
            address[5] memory custody = ISourceCustodyFork(prepared.feeSource).custodyRecipients();
            assertEq(custody[0], address(locker));
            assertEq(custody[1], address(manager));
            assertEq(custody[2], prepared.identity.hook);
        }
        key = PoolKey(Currency.wrap(prepared.identity.currency0), Currency.wrap(prepared.identity.currency1), prepared.identity.fee, prepared.identity.tickSpacing, IHooks(prepared.identity.hook));
        assertEq(deployer.deployedCodeHash(prepared.identity.hook), prepared.identity.hook.codehash);
        assertEq(keccak256(vm.getCode(vm.envString("HOOK_ARTIFACT"))), deployer.creationCodeHash());
        assertGt(ILaunchHookV1(prepared.identity.hook).openingCompletedAt(prepared.identity.poolId), 0);
        assertEq(vm.getNonce(prepared.identity.hook), 1, "hook must not create another contract");
        _assertOracleGenesis(prepared.identity.hook, prepared.identity.poolId);
        if (vm.envOr("HOOK_HAS_ORACLE", false) && launchScenario.preparedOracleCardinality != 0) {
            ILaunchHookOracleV1(prepared.identity.hook).increaseObservationCardinalityNext(
                prepared.identity.poolId, launchScenario.preparedOracleCardinality);
        }
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
        assertEq(PoolBoundLaunchHookBaseV2(prepared.identity.hook).minimumHookFeePips(), minimum);
        assertEq(PoolBoundLaunchHookBaseV2(prepared.identity.hook).feeSensitivityPipsSecondsPerTick(), sensitivity);
        _assertHookFeeBacking(manager, key);
        vm.prank(creator);
        assertTrue(IERC20Fork(receipt.token).approve(address(trader), type(uint256).max));
    }

    function _assertInventoryBurn(address token, V4PositionConfigV1 memory position) private {
        assertEq(IERC20Fork(token).balanceOf(address(core)), 0, "unused inventory must be burned");
        uint160 lower = TickMath.getSqrtPriceAtTick(position.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(position.tickUpper);
        uint256 mintedPrincipal = token < address(quote)
            ? SqrtPriceMath.getAmount0Delta(lower, upper, position.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(lower, upper, position.liquidity, true);
        assertEq(ILaunchSupplyFork(token).totalSupply(), mintedPrincipal);
        assertLe(mintedPrincipal, position.maxTokenAmount, "minted principal must stay within the exact market budget");
        emit log_named_uint("burned unused inventory raw amount", position.maxTokenAmount - mintedPrincipal);
    }

    function _planWithFees(uint8 mode, uint256 nonce, uint16 selectedAuthorBps, uint24 hookPips)
        internal view returns (LaunchPlanV1 memory plan)
    {
        return _planWithPoolFee(mode, nonce, selectedAuthorBps, hookPips, 0);
    }

    function _planWithPoolFee(uint8 mode, uint256 nonce, uint16 selectedAuthorBps, uint24 hookPips, uint24 lpPips)
        internal view returns (LaunchPlanV1 memory plan)
    {
        require((uint256(envelope.bounds.feeModeFlags) & (uint256(1) << mode)) != 0, "fee mode not declared");
        plan.chainId = block.chainid;
        plan.orchestrator = address(core);
        plan.creator = creator;
        plan.nonce = nonce;
        plan.deadline = block.timestamp + 1 days;
        plan.executorFeeBps = EXECUTOR_BPS;
        plan.token = TokenConfigV1(TokenKindV1.ERC20, RewardModeV1.None, "Hook acceptance token", "HOOK", launchScenario.tokenSupply, 0, "", bytes32(nonce), creator, false);
        address token = core.predictToken(plan);
        V4MarketConfigV6 memory config;
        config.version = 6;
        config.lpFeePips = lpPips;
        config.tickSpacing = launchScenario.tickSpacing;
        config.sqrtPriceX96 = launchScenario.sqrtPriceX96;
        config.hookFeePips = hookPips;
        config.minimumHookFeePips = launchScenario.minimumHookFeePips < hookPips ? launchScenario.minimumHookFeePips : hookPips;
        config.feeSensitivityPipsSecondsPerTick = launchScenario.feeSensitivityPipsSecondsPerTick;
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
        config.positions[0] = _position(token);
        plan.markets = new MarketConfigV1[](1);
        plan.markets[0] = MarketConfigV1(adapterId, profileId, address(quote), plan.token.supply, 6, abi.encode(config));
        PoolBoundHookParametersV2 memory parameters;
        (parameters,) = adapter.collectorFactory().poolBoundHookParameters(address(adapter), token, plan.markets[0]);
        config.hookSalt = _mine(address(deployer), deployer.initCodeHash(parameters));
        plan.markets[0].config = abi.encode(config);
        assertEq(core.predictToken(plan), token);
        plan.funding = new AssetFundingV1[](1);
        plan.funding[0] = AssetFundingV1(address(quote), launchScenario.launchFunding, FundingKindV1.ERC20,
            address(quote), launchScenario.launchFunding, address(0), "");
        plan.buys = new InitialBuyV1[](launchScenario.openingBuyQuote == 0 ? 0 : 1);
        if (plan.buys.length != 0) {
            plan.buys[0] = InitialBuyV1(0, launchScenario.openingBuyQuote, 1, creator,
                address(quote) < token ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        }
        plan.feeAssets = new FeeAssetPolicyV2[](2);
        plan.feeAssets[0] = FeeAssetPolicyV2(token < address(quote) ? token : address(quote), 10_000, 0, 0);
        plan.feeAssets[1] = FeeAssetPolicyV2(token < address(quote) ? address(quote) : token, 10_000, 0, 0);
    }

    function _trade(PoolKey memory key, bool zeroForOne, int256 amount) internal returns (uint24) {
        return _tradeAfter(key, zeroForOne, amount, launchScenario.swapTimeStep);
    }

    function _tradeAfter(PoolKey memory key, bool zeroForOne, int256 amount, uint32 elapsed)
        internal returns (uint24)
    {
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + 1);
        return _successfulSwap(key, _swapParams(zeroForOne, amount), creator).ratePips;
    }

    function _successfulSwap(PoolKey memory key, SwapParams memory params, address payer)
        internal returns (SwapCase memory result)
    {
        SwapBalances memory beforeBalances = _snapshotSwapBalances(key, payer);
        TradeFee memory fee = _tradeFeeBefore(key, params);
        OracleBefore memory oracleBefore = _oracleBeforeSwap(manager, key);
        bytes memory hookData = _swapHookData(key, params, payer);
        vm.prank(payer);
        BalanceDelta delta = trader.trade(key, params, hookData);
        _assertSwapAccounting(manager, key, address(trader), payer, beforeBalances, delta);
        _assertTradeFee(key, params, delta, fee);
        _assertOracleAfterSwap(key, oracleBefore, Currency.unwrap(key.currency0) == address(quote));
        int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
        assertLt(input, 0);
        assertGt(output, 0);
        if (params.amountSpecified < 0) assertEq(int256(input), params.amountSpecified);
        else assertEq(int256(output), params.amountSpecified);
        result.inputAmount = uint256(-int256(input));
        result.outputAmount = uint256(int256(output));
        result.feeAsset = fee.asset;
        result.feePaid = ILaunchHookV1(address(key.hooks)).pendingFees(PoolId.unwrap(key.toId()), fee.asset) - fee.pending;
        result.ratePips = fee.rate;
        emit log_named_uint("swap input raw amount", result.inputAmount);
        emit log_named_uint("swap output raw amount", result.outputAmount);
        emit log_named_address("swap fee asset", result.feeAsset);
        emit log_named_uint("swap fee raw amount", result.feePaid);
        emit log_named_uint("frozen hook rate pips", result.ratePips);
    }


    function _sameBlockTradeLeavesOracleUnchanged(Receipts memory received) internal returns (uint24 rate) {
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        SwapParams memory params = _supportedSwapParams(received);
        bytes memory expected = _expectedSwapRevert(key, params, creator);
        assertEq(expected.length, 0, "oracle probe must use an actually supported branch");
        OracleBefore memory beforeOracle = _oracleBeforeSwap(manager, key);
        if (beforeOracle.lastBlock != block.number) {
            _successfulSwap(key, params, creator);
            beforeOracle = _oracleBeforeSwap(manager, key);
        }
        rate = _successfulSwap(key, params, creator).ratePips;
        _assertOracleUnchanged(key, beforeOracle);
        _assertHookFeeBacking(manager, key);
    }

    function _supportedSwapParams(Receipts memory received) private view returns (SwapParams memory) {
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        if (received.cases.length == 0) {
            return _swapParams(Currency.unwrap(key.currency0) == address(quote), _signedAmount(launchScenario.buyExactInputQuote) * -1);
        }
        for (uint256 i; i < received.cases.length; ++i) {
            SwapCase memory selected = received.cases[i];
            if (selected.rejected) continue;
            bool buyZeroForOne = Currency.unwrap(key.currency0) == address(quote);
            return _swapParams(selected.buy ? buyZeroForOne : !buyZeroForOne, selected.amountSpecified);
        }
        revert("no successful scenario branch");
    }

    function _assertOracleElapsedHistory(Receipts memory received) internal {
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        _assertOracleElapsedHistory(manager, key);
    }

    struct TradeFee {
        address asset;
        uint256 pending;
        uint24 rate;
        bool inputCurrency;
    }

    function _tradeFeeBefore(PoolKey memory key, SwapParams memory params)
        internal view returns (TradeFee memory fee)
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
        assertGe(fee.rate, PoolBoundLaunchHookBaseV2(address(key.hooks)).minimumHookFeePips());
        if (ILaunchHookAuthorTerms(address(key.hooks)).swapFeeModel() == ILaunchHookAuthorTerms.SwapFeeModel.Static) {
            assertEq(fee.rate, config.hookFeePips);
        }
    }

    function _assertTradeFee(PoolKey memory key, SwapParams memory params, BalanceDelta delta, TradeFee memory beforeFee)
        internal view
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
        assertTrue(vm.revertToStateAndDelete(snapshot));
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
        emit log_named_address("claimed fee asset", fee.asset);
        emit log_named_uint("owner/author fee pool raw amount", fee.amount);
        emit log_named_uint("executor bounty raw amount", bounty);
        emit log_named_uint("owner receipt raw amount", ownerPaid);
        emit log_named_uint("author receipt raw amount", authorPaid);
    }

    function _position(address token) private view returns (V4PositionConfigV1 memory) {
        bool tokenIs0 = token < address(quote);
        return V4PositionConfigV1(tokenIs0 ? launchScenario.lowerTick : -launchScenario.upperTick,
            tokenIs0 ? launchScenario.upperTick : -launchScenario.lowerTick, launchScenario.liquidity,
            bytes32(uint256(1)), launchScenario.tokenSupply);
    }

    function _liquidity(PoolKey memory key, address token) private view returns (uint128) {
        V4PositionConfigV1 memory position = _position(token);
        bytes32 positionKey = Position.calculatePositionKey(address(locker),
            position.tickLower, position.tickUpper, position.salt);
        return StateLibrary.getPositionLiquidity(manager, key.toId(), positionKey);
    }

    function _harvestAndClaim(LaunchReceiptV1 memory receipt, PreparedMarketV1 memory prepared, PoolKey memory key) private returns (Receipts memory received) {
        ILaunchFeeHubV3 hub = ILaunchFeeHubV3(receipt.feeHub);
        ILaunchHookV1 hook = ILaunchHookV1(prepared.identity.hook);
        uint128 principal = _liquidity(key, receipt.token);
        assertGt(principal, 0);
        uint256 grossHook = hook.pendingFees(prepared.identity.poolId, address(quote));
        uint256 treasuryDue = hook.pendingTreasurySweeps(prepared.identity.poolId, address(quote));
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
        received.principalBefore = principal;
        for (uint256 i; i < fees.length; ++i) {
            (uint256 ownerPaid, uint256 authorPaid) = _claimAsset(hub, fees[i]);
            if (fees[i].asset == address(quote)) {
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
        received.principalAfter = _liquidity(key, receipt.token);
        assertEq(received.principalAfter, principal);
        emit log_named_uint("liquidity principal before collection", principal);
        emit log_named_uint("liquidity principal after collection", received.principalAfter);
        emit log_named_uint("quote hook fees collected", received.hookFeesCollected);
        emit log_named_uint("quote treasury paid", received.treasuryPaid);
        emit log_named_uint("quote owner paid", received.ownerPaid);
        emit log_named_uint("quote author paid", received.authorPaid);
        _assertHookFeeBacking(manager, key);
    }


    function _mine(address holder, bytes32 initCodeHash) internal pure returns (bytes32) {
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

    function _address(string memory name) internal view returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".addresses.", name));
    }

    function _writeReceipts(Receipts[] memory received) internal {
        string memory modes = "[";
        uint256 totalTradeCount;
        for (uint256 i; i < received.length; ++i) {
            modes = string.concat(modes, i == 0 ? "" : ",", _receiptJson(received[i]));
            totalTradeCount += received[i].tradeCount;
        }
        modes = string.concat(modes, "]");
        string memory primary = _receiptJson(received[0]);
        string memory json = _appendJsonFields(primary, string.concat(
            ",\"modes\":", modes, ",\"totalTradeCount\":", vm.toString(totalTradeCount)));
        vm.writeJson(json, vm.envString("HOOK_RECEIPT_EVIDENCE"));
    }

    function _receiptJson(Receipts memory received) private returns (string memory) {
        string memory object = string.concat("smoke-mode-", vm.toString(received.feeMode));
        vm.serializeString(object, "schema", "abyss-hooks.launch-receipts.v1");
        vm.serializeAddress(object, "token", received.token);
        vm.serializeAddress(object, "hook", received.hook);
        vm.serializeBytes32(object, "poolId", received.poolId);
        vm.serializeAddress(object, "quoteAsset", address(quote));
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
        vm.serializeUint(object, "feeMode", received.feeMode);
        vm.serializeUint(object, "principalBefore", received.principalBefore);
        vm.serializeUint(object, "principalAfter", received.principalAfter);
        vm.serializeUint(object, "openingBuyQuote", launchScenario.openingBuyQuote);
        string memory json = vm.serializeUint(object, "tradeCount", received.tradeCount);
        string memory cases = "[";
        for (uint256 i; i < received.cases.length; ++i) {
            cases = string.concat(cases, i == 0 ? "" : ",", _caseJson(object, i, received.cases[i]));
        }
        return _appendJsonFields(json, string.concat(",\"cases\":", cases, "]"));
    }

    function _caseJson(string memory modeObject, uint256 index, SwapCase memory selected)
        private returns (string memory)
    {
        string memory object = string.concat(modeObject, "-case-", vm.toString(index));
        vm.serializeString(object, "direction", selected.buy ? "buy" : "sell");
        vm.serializeString(object, "amountMode", selected.exactInput ? "exact-input" : "exact-output");
        vm.serializeString(object, "status", selected.rejected ? "rejected" : "success");
        vm.serializeString(object, "amountSpecified", vm.toString(selected.amountSpecified));
        vm.serializeBytes(object, "expectedRevert", selected.expectedRevert);
        vm.serializeUint(object, "inputAmount", selected.inputAmount);
        vm.serializeUint(object, "outputAmount", selected.outputAmount);
        vm.serializeAddress(object, "feeAsset", selected.feeAsset);
        vm.serializeUint(object, "feePaid", selected.feePaid);
        return vm.serializeUint(object, "ratePips", selected.ratePips);
    }

    function _appendJsonFields(string memory json, string memory fields) private pure returns (string memory) {
        bytes memory prefix = bytes(json);
        require(prefix.length != 0 && prefix[prefix.length - 1] == bytes1("}"), "serialized receipt object required");
        // Remove only the serializer's final delimiter before appending raw nested JSON.
        assembly ("memory-safe") { mstore(prefix, sub(mload(prefix), 1)) }
        return string.concat(string(prefix), fields, "}");
    }
}
