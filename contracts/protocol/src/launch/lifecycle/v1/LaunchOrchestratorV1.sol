// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ILaunchFeeSourceV1 } from "../../fees/v1/ILaunchFeeHubV1.sol";
import {
    LaunchPlanV1,
    LaunchModeV1,
    LaunchPhaseV1,
    LaunchOperationV1,
    TokenKindV1,
    RewardModeV1,
    MarketConfigV1,
    InitialBuyV1,
    MarketIdentityV1,
    PreparedMarketV1,
    PositionIdentityV1,
    LaunchExecutionContextV1,
    LaunchProgressV1,
    LaunchReceiptV1,
    LaunchCapabilitiesV1
} from "./LaunchTypesV1.sol";
import {
    ILaunchLifecycleV1,
    ILaunchLifecycleTokenV1,
    ILaunchTokenFactoryV1,
    ILaunchMarketAdapterV1,
    ILaunchImplementationRegistryV1,
    ILaunchDirectoryV1,
    ILaunchLifecycleFeeFactoryV1,
    ILaunchLifecycleFeeHubV1
} from "./ILaunchLifecycleV1.sol";
import { LaunchFundingEscrowV1 } from "./LaunchFundingEscrowV1.sol";
import { LaunchPlanValidatorV1 } from "./LaunchPlanValidatorV1.sol";

/// @notice One committed token/economic plan, ordinary-call markets, isolated funding and one
///         irreversible all-mints/all-buys public activation boundary.
contract LaunchOrchestratorV1 is ILaunchLifecycleV1, ReentrancyGuard {
    error Unauthorized();
    error WrongDomain();
    error PlanMismatch();
    error LaunchAlreadyExists();
    error InvalidMode();
    error InvalidPhase();
    error InvalidPreparationOrder();
    error DeadlineExpired();
    error InvalidBinding();
    error InvalidMarket();
    error InexactTransfer();
    error InsufficientEscrow();

    bytes32 public constant PLAN_DOMAIN = keccak256("BLACK_MARKET_LAUNCH_PLAN_V1");
    uint32 public constant MAX_MARKETS = 16;
    uint32 public constant MAX_BUYS = 64;
    uint32 public constant MAX_POSITIONS = 32;

    ILaunchImplementationRegistryV1 public immutable registry;
    ILaunchTokenFactoryV1 public immutable tokenFactory;
    ILaunchLifecycleFeeFactoryV1 public immutable feeFactory;
    ILaunchDirectoryV1 public immutable directory;
    LaunchFundingEscrowV1 public immutable fundingEscrow;
    LaunchPlanValidatorV1 public immutable validator;
    mapping(bytes32 => LaunchProgressV1) private _launches;
    mapping(address => bytes32) private _tokenLaunch;
    LaunchExecutionContextV1 private _context;

    constructor(
        ILaunchImplementationRegistryV1 registry_,
        ILaunchTokenFactoryV1 tokenFactory_,
        ILaunchLifecycleFeeFactoryV1 feeFactory_,
        ILaunchDirectoryV1 directory_,
        LaunchFundingEscrowV1 fundingEscrow_,
        LaunchPlanValidatorV1 validator_
    ) {
        if (
            address(registry_).code.length == 0 || registry_.core() != address(this)
                || address(tokenFactory_).code.length == 0 || tokenFactory_.core() != address(this)
                || address(feeFactory_).code.length == 0
                || feeFactory_.deploymentAuthority() != address(this)
                || address(directory_).code.length == 0 || directory_.core() != address(this)
                || address(fundingEscrow_).code.length == 0
                || fundingEscrow_.core() != address(this)
                || address(fundingEscrow_.registry()) != address(registry_)
                || address(validator_.fundingEscrow()) != address(fundingEscrow_)
        ) revert InvalidBinding();
        registry = registry_;
        tokenFactory = tokenFactory_;
        feeFactory = feeFactory_;
        directory = directory_;
        fundingEscrow = fundingEscrow_;
        validator = validator_;
    }

    function hashPlan(LaunchPlanV1 calldata plan) public pure override returns (bytes32) {
        return keccak256(abi.encode(PLAN_DOMAIN, plan));
    }

    function launchIdOf(LaunchPlanV1 calldata plan) public pure override returns (bytes32) {
        return keccak256(abi.encode(plan.chainId, plan.orchestrator, plan.creator, plan.nonce));
    }

    function predictToken(LaunchPlanV1 calldata plan) external view override returns (address) {
        return tokenFactory.predictToken(launchIdOf(plan), plan.token);
    }

    function launchAtomic(LaunchPlanV1 calldata plan)
        external
        payable
        override
        nonReentrant
        returns (LaunchReceiptV1 memory receipt)
    {
        bytes32 launchId = _begin(plan, LaunchModeV1.Atomic);
        _prepare(plan, launchId, 0, uint32(plan.markets.length));
        receipt = _activate(plan, launchId);
    }

    function beginLaunch(LaunchPlanV1 calldata plan, LaunchModeV1 mode)
        external
        payable
        override
        nonReentrant
        returns (LaunchProgressV1 memory)
    {
        if (mode != LaunchModeV1.Staged) revert InvalidMode();
        return _launches[_begin(plan, mode)];
    }

    function prepareMarkets(LaunchPlanV1 calldata plan, uint32 firstMarket, uint32 count)
        external
        override
        nonReentrant
    {
        bytes32 launchId = _command(plan, true);
        _prepare(plan, launchId, firstMarket, count);
    }

    function activateLaunch(LaunchPlanV1 calldata plan)
        external
        override
        nonReentrant
        returns (LaunchReceiptV1 memory)
    {
        return _activate(plan, _command(plan, true));
    }

    function cancelLaunch(LaunchPlanV1 calldata plan) external override nonReentrant {
        bytes32 launchId = _command(plan, false);
        LaunchProgressV1 storage progress = _launches[launchId];
        if (progress.phase != LaunchPhaseV1.Preparing && progress.phase != LaunchPhaseV1.Ready) {
            revert InvalidPhase();
        }
        progress.phase = LaunchPhaseV1.Cancelled;
        ILaunchLifecycleTokenV1(progress.token).cancel(plan.token.burnOnCancel);
        _refund(launchId, progress.creator);
        emit LaunchCancelled(launchId, progress.creator, plan.token.burnOnCancel);
    }

    function readLaunchProgress(bytes32 launchId)
        external
        view
        override
        returns (LaunchProgressV1 memory)
    {
        return _launches[launchId];
    }

    function executionContext() external view override returns (LaunchExecutionContextV1 memory) {
        return _context;
    }

    function isLaunchActive(bytes32 launchId) external view override returns (bool) {
        return _launches[launchId].phase == LaunchPhaseV1.Active;
    }

    function escrowBalance(bytes32 launchId, address asset)
        external
        view
        override
        returns (uint256)
    {
        return fundingEscrow.balanceOf(launchId, asset);
    }

    function authorizeTokenTransfer(
        address token,
        address caller,
        address from,
        address to,
        uint256 amount,
        bool nft
    ) external view override returns (bool) {
        bytes32 launchId = _tokenLaunch[token];
        LaunchProgressV1 storage progress = _launches[launchId];
        if (token == address(0) || progress.token != token) return false;
        if (progress.phase == LaunchPhaseV1.Active) return true;
        if (nft) return false;
        LaunchExecutionContextV1 memory context = _context;
        if (
            progress.phase != LaunchPhaseV1.Activating || context.launchId != launchId
                || context.token != token
        ) return false;
        if (context.operation == LaunchOperationV1.Inventory) {
            return caller == address(this) && from == address(this) && to == context.recipient
                && amount == context.amount;
        }
        if (
            context.operation != LaunchOperationV1.Mint
                && context.operation != LaunchOperationV1.Buy
        ) return false;
        if (
            context.operation == LaunchOperationV1.Mint
                && (caller == address(this)
                    && from == address(this)
                    && to == context.adapter
                    && amount == context.amount
                    || caller == context.adapter
                    && from == context.adapter
                    && to == address(this)
                    && amount <= context.amount)
        ) return true;
        return ILaunchMarketAdapterV1(context.adapter)
            .authorizeTokenTransfer(
                launchId, context.marketIndex, context.operation, caller, from, to, amount, nft
            );
    }

    function _begin(LaunchPlanV1 calldata plan, LaunchModeV1 mode)
        private
        returns (bytes32 launchId)
    {
        _authority(plan);
        if (block.timestamp > plan.deadline) revert DeadlineExpired();
        launchId = launchIdOf(plan);
        if (_launches[launchId].phase != LaunchPhaseV1.None) revert LaunchAlreadyExists();
        address predicted = validator.validatePlan(plan);
        LaunchProgressV1 storage progress = _launches[launchId];
        progress.launchId = launchId;
        progress.planHash = hashPlan(plan);
        progress.creator = plan.creator;
        progress.nonce = plan.nonce;
        progress.mode = mode;
        progress.phase = LaunchPhaseV1.Preparing;
        progress.marketCount = uint32(plan.markets.length);
        progress.buyCount = uint32(plan.buys.length);
        progress.deadline = plan.deadline;
        address token = tokenFactory.deployToken(launchId, plan.token);
        if (
            token != predicted
                || SafeTransferLib.balanceOf(token, address(this)) != plan.token.supply
        ) revert InvalidBinding();
        progress.token = token;
        _tokenLaunch[token] = launchId;
        address hub = feeFactory.createHub(
            token, plan.creator, plan.feeAssets, plan.executorFeeBps, address(this)
        );
        if (hub.code.length == 0) revert InvalidBinding();
        progress.feeHub = hub;
        address[] memory rewardAssets = validator.rewardAssets(plan);
        address rewards = tokenFactory.createRewards(token, hub, rewardAssets);
        if (plan.token.rewardMode == RewardModeV1.None) {
            if (rewards != address(0)) revert InvalidBinding();
        } else if (rewards.code.length == 0) {
            revert InvalidBinding();
        }
        progress.rewards = rewards;
        validator.validateRewardTreasuries(plan, rewards);
        fundingEscrow.fund{ value: msg.value }(launchId, plan.creator, plan.funding);
        directory.recordLaunch(launchId, token, plan.creator, hub);
        emit LaunchBegun(
            launchId, progress.planHash, plan.creator, token, hub, progress.rewards, mode
        );
    }

    function _prepare(
        LaunchPlanV1 calldata plan,
        bytes32 launchId,
        uint32 firstMarket,
        uint32 count
    ) private {
        LaunchProgressV1 storage progress = _launches[launchId];
        if (progress.phase != LaunchPhaseV1.Preparing) revert InvalidPhase();
        if (
            count == 0 || firstMarket != progress.preparedMarkets
                || uint256(firstMarket) + count > progress.marketCount
        ) revert InvalidPreparationOrder();
        validator.validateAssets(plan, progress.token);
        for (uint32 i = firstMarket; i < firstMarket + count; ++i) {
            _prepareMarket(plan, launchId, i, progress);
        }
        if (progress.preparedMarkets == progress.marketCount) {
            address[] memory exclusions = validator.collectExclusions(
                directory, launchId, progress.token, progress.feeHub, progress.rewards
            );
            ILaunchLifecycleTokenV1(progress.token).finalizeExclusions(exclusions);
            progress.phase = LaunchPhaseV1.Ready;
            emit LaunchReady(launchId);
        }
    }

    function _prepareMarket(
        LaunchPlanV1 calldata plan,
        bytes32 launchId,
        uint32 i,
        LaunchProgressV1 storage progress
    ) private {
        MarketConfigV1 calldata marketConfig = plan.markets[i];
        address adapter = _eligible(plan, marketConfig, false);
        MarketIdentityV1 memory expected =
            ILaunchMarketAdapterV1(adapter).resolve(launchId, progress.token, marketConfig);
        validator.validateIdentity(
            expected, progress.token, marketConfig.quoteAsset, marketConfig.profileId
        );
        _context = LaunchExecutionContextV1(
            launchId,
            i,
            LaunchOperationV1.Prepare,
            adapter,
            adapter,
            progress.token,
            marketConfig.quoteAsset,
            expected.manager,
            address(0),
            address(0),
            0
        );
        PreparedMarketV1 memory prepared = ILaunchMarketAdapterV1(adapter)
            .prepareMarket(launchId, i, progress.token, progress.feeHub, marketConfig);
        delete _context;
        validator.validatePreparedMarket(
            prepared, expected, progress.feeHub, progress.positionCount
        );
        if (prepared.positionCount > 1) _eligible(plan, marketConfig, true);
        validator.validatePreparedSource(plan.feeAssets, directory, launchId, prepared.feeSource, i);
        ILaunchMarketAdapterV1(adapter)
            .validatePrepared(launchId, i, progress.token, marketConfig, prepared.identity);
        directory.recordMarket(launchId, i, adapter, prepared);
        progress.positionCount += prepared.positionCount;
        ++progress.preparedMarkets;
        emit MarketPrepared(
            launchId,
            i,
            prepared.identity.canonicalId,
            adapter,
            prepared.feeSource,
            prepared.positionCount
        );
    }

    function _activate(LaunchPlanV1 calldata plan, bytes32 launchId)
        private
        returns (LaunchReceiptV1 memory receipt)
    {
        LaunchProgressV1 storage progress = _launches[launchId];
        if (progress.phase != LaunchPhaseV1.Ready) revert InvalidPhase();
        if (block.timestamp > progress.deadline) revert DeadlineExpired();
        if (validator.validatePlan(plan) != progress.token) revert InvalidBinding();
        address[] memory sources = _validateReadyMarkets(plan, launchId, progress);
        for (uint256 i; i < plan.funding.length; ++i) {
            if (fundingEscrow.balanceOf(launchId, plan.funding[i].asset) < plan.funding[i].amount) {
                revert InsufficientEscrow();
            }
        }
        progress.phase = LaunchPhaseV1.Activating;
        uint256 tokenSpent;
        for (uint32 i; i < progress.marketCount; ++i) {
            tokenSpent += _mint(plan, launchId, i, progress.token);
        }
        receipt = LaunchReceiptV1(
            launchId,
            progress.planHash,
            progress.token,
            progress.feeHub,
            progress.rewards,
            progress.marketCount,
            progress.positionCount,
            new uint256[](plan.buys.length),
            new uint256[](plan.buys.length)
        );
        for (uint32 i; i < plan.buys.length; ++i) {
            (receipt.quoteSpent[i], receipt.tokenOut[i]) = _buy(plan, launchId, i, progress.token);
        }
        delete _context;
        ILaunchLifecycleFeeHubV1(progress.feeHub).configureSources(sources, progress.rewards);
        if (!ILaunchLifecycleFeeHubV1(progress.feeHub).finalized()) revert InvalidBinding();
        // Every externally callable step (refund transfers of admitted callback-capable
        // quote assets, inventory delivery) runs BEFORE the terminal opening boundary, so
        // a callback-driven venue mutation during those steps cannot land after any
        // market's final continuity validation. The terminal open revalidates every
        // market's committed canonical state and is the last venue interaction before
        // the token activates and the launch becomes Active.
        _refund(launchId, progress.creator);
        uint256 inventory = plan.token.supply - tokenSpent;
        if (SafeTransferLib.balanceOf(progress.token, address(this)) != inventory) {
            revert InexactTransfer();
        }
        if (inventory != 0) {
            _context = LaunchExecutionContextV1(
                launchId,
                0,
                LaunchOperationV1.Inventory,
                address(0),
                address(this),
                progress.token,
                address(0),
                address(0),
                address(0),
                plan.token.inventoryRecipient,
                inventory
            );
            _sendExact(progress.token, plan.token.inventoryRecipient, inventory);
            delete _context;
        }
        _openMarkets(plan, launchId, progress.marketCount);
        delete _context;
        ILaunchLifecycleTokenV1(progress.token).activate();
        progress.phase = LaunchPhaseV1.Active;
        emit LaunchActivated(
            launchId,
            progress.planHash,
            progress.token,
            progress.marketCount,
            progress.positionCount
        );
    }

    function _validateReadyMarkets(
        LaunchPlanV1 calldata plan,
        bytes32 launchId,
        LaunchProgressV1 storage progress
    ) private view returns (address[] memory sources) {
        sources = new address[](progress.marketCount);
        for (uint32 i; i < progress.marketCount; ++i) {
            (address adapter, PreparedMarketV1 memory prepared) = directory.market(launchId, i);
            if (_eligible(plan, plan.markets[i], prepared.positionCount > 1) != adapter) {
                revert InvalidBinding();
            }
            ILaunchMarketAdapterV1(adapter)
                .validatePrepared(launchId, i, progress.token, plan.markets[i], prepared.identity);
            sources[i] = prepared.feeSource;
        }
    }

    function _openMarkets(LaunchPlanV1 calldata plan, bytes32 launchId, uint32 marketCount)
        private
    {
        for (uint32 i; i < marketCount; ++i) {
            (address adapter, PreparedMarketV1 memory prepared) = directory.market(launchId, i);
            _setContext(
                launchId,
                i,
                LaunchOperationV1.Open,
                adapter,
                prepared,
                plan.markets[i].quoteAsset,
                address(0),
                0
            );
            ILaunchMarketAdapterV1(adapter).activateMarket(launchId, i);
        }
    }

    function _mint(LaunchPlanV1 calldata plan, bytes32 launchId, uint32 index, address token)
        private
        returns (uint256 spent)
    {
        MarketConfigV1 calldata marketConfig = plan.markets[index];
        (address adapter, PreparedMarketV1 memory prepared) = directory.market(launchId, index);
        uint256 coreBefore = SafeTransferLib.balanceOf(token, address(this));
        uint256 adapterBefore = SafeTransferLib.balanceOf(token, adapter);
        uint256 quoteBefore = SafeTransferLib.balanceOf(marketConfig.quoteAsset, adapter);
        _setContext(
            launchId,
            index,
            LaunchOperationV1.Mint,
            adapter,
            prepared,
            marketConfig.quoteAsset,
            address(0),
            marketConfig.tokenBudget
        );
        _sendExact(token, adapter, marketConfig.tokenBudget);
        PositionIdentityV1[] memory positions;
        (positions, spent) =
            ILaunchMarketAdapterV1(adapter).mintAndLock(launchId, index, token, marketConfig);
        validator.verifyMintedMarket(
            adapter,
            token,
            prepared,
            positions,
            marketConfig,
            spent,
            quoteBefore,
            coreBefore,
            adapterBefore
        );
        directory.recordPositions(launchId, index, positions);
        delete _context;
    }

    function _buy(LaunchPlanV1 calldata plan, bytes32 launchId, uint32 buyIndex, address token)
        private
        returns (uint256 spent, uint256 output)
    {
        InitialBuyV1 calldata buy = plan.buys[buyIndex];
        MarketConfigV1 calldata marketConfig = plan.markets[buy.marketIndex];
        (address adapter, PreparedMarketV1 memory prepared) =
            directory.market(launchId, buy.marketIndex);
        BuyWitness memory witness;
        witness.coreBefore = SafeTransferLib.balanceOf(marketConfig.quoteAsset, address(this));
        witness.adapterBefore = SafeTransferLib.balanceOf(marketConfig.quoteAsset, adapter);
        witness.adapterTokenBefore = SafeTransferLib.balanceOf(token, adapter);
        witness.recipientBefore = SafeTransferLib.balanceOf(token, buy.recipient);
        _setContext(
            launchId,
            buy.marketIndex,
            LaunchOperationV1.Buy,
            adapter,
            prepared,
            marketConfig.quoteAsset,
            buy.recipient,
            buy.quoteAmountIn
        );
        fundingEscrow.pay(launchId, marketConfig.quoteAsset, adapter, buy.quoteAmountIn);
        (spent, output) = ILaunchMarketAdapterV1(adapter)
            .executeBuy(launchId, buy.marketIndex, token, marketConfig, buy);
        _verifyBuy(buy, marketConfig.quoteAsset, token, adapter, witness, spent, output);
        uint256 refund =
            SafeTransferLib.balanceOf(marketConfig.quoteAsset, address(this)) - witness.coreBefore;
        if (refund != 0) {
            _sendExact(marketConfig.quoteAsset, address(fundingEscrow), refund);
            fundingEscrow.creditRefund(launchId, marketConfig.quoteAsset, refund);
        }
        delete _context;
        emit InitialBuyExecuted(
            launchId,
            buyIndex,
            buy.marketIndex,
            marketConfig.quoteAsset,
            spent,
            output,
            buy.recipient
        );
    }

    struct BuyWitness {
        uint256 coreBefore;
        uint256 adapterBefore;
        uint256 adapterTokenBefore;
        uint256 recipientBefore;
    }

    function _verifyBuy(
        InitialBuyV1 calldata buy,
        address quote,
        address token,
        address adapter,
        BuyWitness memory witness,
        uint256 spent,
        uint256 output
    ) private view {
        uint256 coreAfter = SafeTransferLib.balanceOf(quote, address(this));
        if (
            coreAfter < witness.coreBefore || coreAfter - witness.coreBefore > buy.quoteAmountIn
                || spent == 0 || spent != buy.quoteAmountIn - (coreAfter - witness.coreBefore)
                || output < buy.minTokenOut
                || SafeTransferLib.balanceOf(token, buy.recipient)
                    != witness.recipientBefore + output
                || SafeTransferLib.balanceOf(quote, adapter) != witness.adapterBefore
                || SafeTransferLib.balanceOf(token, adapter) != witness.adapterTokenBefore
        ) revert InexactTransfer();
    }

    function _setContext(
        bytes32 launchId,
        uint32 index,
        LaunchOperationV1 operation,
        address adapter,
        PreparedMarketV1 memory prepared,
        address quote,
        address recipient,
        uint256 amount
    ) private {
        address executor = operation == LaunchOperationV1.Mint
            ? prepared.mintExecutor
            : prepared.buyExecutor;
        _context = LaunchExecutionContextV1(
            launchId,
            index,
            operation,
            adapter,
            executor,
            _launches[launchId].token,
            quote,
            prepared.identity.manager,
            prepared.custody,
            recipient,
            amount
        );
    }

    function _command(LaunchPlanV1 calldata plan, bool checkDeadline)
        private
        view
        returns (bytes32 launchId)
    {
        _authority(plan);
        launchId = launchIdOf(plan);
        LaunchProgressV1 storage progress = _launches[launchId];
        if (progress.phase == LaunchPhaseV1.None) revert InvalidPhase();
        if (progress.planHash != hashPlan(plan)) revert PlanMismatch();
        if (checkDeadline && block.timestamp > progress.deadline) revert DeadlineExpired();
    }

    function _authority(LaunchPlanV1 calldata plan) private view {
        if (plan.chainId != block.chainid || plan.orchestrator != address(this)) {
            revert WrongDomain();
        }
        if (plan.creator != msg.sender) revert Unauthorized();
    }

    function _eligible(
        LaunchPlanV1 calldata plan,
        MarketConfigV1 calldata marketConfig,
        bool multiple
    ) private view returns (address) {
        uint64 capabilities = LaunchCapabilitiesV1.REQUIRED;
        if (plan.token.kind == TokenKindV1.ERC404) capabilities |= LaunchCapabilitiesV1.ERC404;
        if (multiple) capabilities |= LaunchCapabilitiesV1.MULTI_POSITION;
        return registry.requireEligible(
            marketConfig.adapterId, marketConfig.profileId, marketConfig.configVersion, capabilities
        );
    }

    function _refund(bytes32 launchId, address creator) private {
        (address[] memory assets, uint256[] memory amounts) = fundingEscrow.refund(launchId);
        for (uint256 i; i < assets.length; ++i) {
            if (amounts[i] != 0) emit AssetRefunded(launchId, assets[i], creator, amounts[i]);
        }
    }

    function _sendExact(address asset, address recipient, uint256 amount) private {
        uint256 beforeBalance = SafeTransferLib.balanceOf(asset, address(this));
        uint256 recipientBefore = SafeTransferLib.balanceOf(asset, recipient);
        SafeTransferLib.safeTransfer(asset, recipient, amount);
        if (
            SafeTransferLib.balanceOf(asset, address(this)) + amount != beforeBalance
                || SafeTransferLib.balanceOf(asset, recipient) != recipientBefore + amount
        ) revert InexactTransfer();
    }
}
