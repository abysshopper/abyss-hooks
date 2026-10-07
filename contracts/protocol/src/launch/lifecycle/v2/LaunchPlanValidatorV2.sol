// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FeeAssetPolicyV2 } from "../../fees/v2/ILaunchFeeHubV2.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ILaunchFeeSourceV1 } from "../../fees/v1/ILaunchFeeHubV1.sol";
import { LaunchPlanV1, AssetFundingV1, FundingKindV1, MarketConfigV1, MarketIdentityV1,
    InitialBuyV1, TokenKindV1, RewardModeV1, LaunchVenueV1, LaunchCapabilitiesV1,
    ProfileRegistrationV1, ProfileTopologyV1, LaunchHookTopologyV1, PreparedMarketV1,
    PositionIdentityV1 } from "../v1/LaunchTypesV1.sol";
import { V4MarketConfigV2 } from "../v1/V4MarketConfigV2.sol";
import { V4MarketConfigLibV2 } from "../v1/V4MarketConfigLibV2.sol";
import { V4MarketConfigV3 } from "../v1/V4MarketConfigV3.sol";
import { V4MarketConfigLibV3 } from "../v1/V4MarketConfigLibV3.sol";
import { V4MarketConfigV4 } from "./V4MarketConfigV4.sol";
import { V4MarketConfigLibV4 } from "./V4MarketConfigLibV4.sol";
import { V4MarketConfigV6 } from "./V4MarketConfigV6.sol";
import { V4MarketConfigLibV6 } from "./V4MarketConfigLibV6.sol";
import { ILaunchRegistryV2, LaunchEnvelopeV2 } from "./ILaunchRegistryV2.sol";
import { V4HookFlags } from "../../../hooks/v4/V4HookFlags.sol";
import { AbyssMarketConfigV1 } from "../v1/AbyssMarketConfigV1.sol";
import { ILaunchTokenFactoryV1, ILaunchMarketAdapterV1, ILaunchDirectoryV1 } from "../v1/ILaunchLifecycleV1.sol";

/// @notice Opt-in successor with the exact V1 validator ABI/rules and explicit admitted-profile
///         config decoding. The immutable V1 artifact only understands its old schemas.
/// @dev No old source or default deployment is changed. The core's ordinary-call ABI is
///      unchanged; a fresh core supplies this address through its existing validator slot.
contract LaunchPlanValidatorV2 {
    error InvalidPositions();
    error InvalidPlan();
    error InvalidFunding();
    error InvalidFeePolicy();
    error InvalidMarket();
    error InvalidBuy();
    error DuplicateMarket();

    ILaunchRegistryV2 public immutable registry;
    ILaunchTokenFactoryV1 public immutable tokenFactory;
    address public immutable fundingEscrow;
    uint32 public constant MAX_MARKETS = 16;
    uint32 public constant MAX_BUYS = 64;
    uint32 public constant MAX_POSITIONS = 32;

    constructor(ILaunchRegistryV2 registry_, ILaunchTokenFactoryV1 tokenFactory_, address fundingEscrow_) {
        if (address(registry_).code.length == 0 || address(tokenFactory_).code.length == 0
            || registry_.core() != tokenFactory_.core() || fundingEscrow_ == address(0)) revert InvalidPlan();
        registry = registry_;
        tokenFactory = tokenFactory_;
        fundingEscrow = fundingEscrow_;
    }

    function validatePlan(LaunchPlanV1 calldata plan) external view returns (address token) {
        if (plan.chainId != block.chainid || plan.orchestrator != registry.core() || plan.creator == address(0)
            || plan.markets.length == 0 || plan.markets.length > MAX_MARKETS || plan.buys.length > MAX_BUYS
            || plan.funding.length > 8 || plan.feeAssets.length == 0 || plan.feeAssets.length > 8
            || plan.executorFeeBps > 1_000 || plan.token.supply == 0 || plan.token.inventoryRecipient == address(0)
            || plan.token.inventoryRecipient == plan.orchestrator || bytes(plan.token.name).length == 0
            || bytes(plan.token.name).length > 128 || bytes(plan.token.symbol).length == 0
            || bytes(plan.token.symbol).length > 32 || bytes(plan.token.metadataURI).length > 2048) revert InvalidPlan();
        bytes32 launchId = keccak256(abi.encode(plan.chainId, plan.orchestrator, plan.creator, plan.nonce));
        token = tokenFactory.predictToken(launchId, plan.token);
        if (token == address(0)) revert InvalidPlan();
        _validateFees(plan, token);
        _validateFunding(plan, token);
        _validateMarkets(plan, launchId, token);
        _validateBuys(plan);
    }

    function _validateFees(LaunchPlanV1 calldata plan, address token) private view {
        address previous;
        bool hasRewards;
        for (uint256 i; i < plan.feeAssets.length; ++i) {
            address asset = plan.feeAssets[i].asset;
            if (asset <= previous || (asset != token && asset.code.length == 0)
                || uint256(plan.feeAssets[i].ownerBps) + plan.feeAssets[i].rewardsBps + plan.feeAssets[i].burnBps != 10_000
                || (plan.feeAssets[i].burnBps != 0 && asset != token)) revert InvalidFeePolicy();
            if (plan.feeAssets[i].rewardsBps != 0) hasRewards = true;
            previous = asset;
        }
        if (hasRewards != (plan.token.rewardMode != RewardModeV1.None)) revert InvalidFeePolicy();
    }

    function _validateFunding(LaunchPlanV1 calldata plan, address token) private view {
        address previous;
        for (uint256 i; i < plan.funding.length; ++i) {
            AssetFundingV1 calldata funding = plan.funding[i];
            if (funding.asset <= previous || funding.asset == token || funding.asset.code.length == 0
                || funding.amount == 0 || funding.inputAmount == 0) revert InvalidFunding();
            if (funding.kind == FundingKindV1.Swap) {
                (address spender, bytes32 codeHash, bool enabled) = registry.fundingTarget(funding.target);
                if (!enabled || spender == address(0) || funding.target.codehash != codeHash
                    || funding.inputAsset == funding.asset || funding.inputAsset == token
                    || (funding.inputAsset != address(0) && !registry.fundingInputAllowed(funding.inputAsset))
                    || funding.data.length == 0 || funding.data.length > 16_384) revert InvalidFunding();
            } else if (funding.inputAsset != funding.asset || funding.inputAmount != funding.amount
                || funding.target != address(0) || funding.data.length != 0) revert InvalidFunding();
            previous = funding.asset;
        }
    }

    function _validateMarkets(LaunchPlanV1 calldata plan, bytes32 launchId, address token) private view {
        uint256 allocated;
        uint256 positions;
        bytes32[] memory identities = new bytes32[](plan.markets.length);
        uint256 v4Markets;
        uint64 capabilities = LaunchCapabilitiesV1.REQUIRED;
        if (plan.token.kind == TokenKindV1.ERC404) capabilities |= LaunchCapabilitiesV1.ERC404;
        for (uint256 i; i < plan.markets.length; ++i) {
            MarketConfigV1 calldata market = plan.markets[i];
            if (market.quoteAsset == token || market.quoteAsset.code.length == 0 || market.tokenBudget == 0
                || market.config.length == 0 || market.config.length > 16_384
                || !_feeAsset(plan, token) || !_feeAsset(plan, market.quoteAsset)) revert InvalidMarket();
            allocated += market.tokenBudget;
            address implementation = registry.requireEligible(market.adapterId, market.profileId, market.configVersion, capabilities);
            MarketIdentityV1 memory identity = ILaunchMarketAdapterV1(implementation).resolve(launchId, token, market);
            validateIdentity(identity, token, market.quoteAsset, market.profileId);
            for (uint256 j; j < i; ++j) {
                if (identities[j] == identity.canonicalId
                    || (identity.venue == LaunchVenueV1.UniswapV4 && (v4Markets & (1 << j)) != 0
                        && plan.markets[j].quoteAsset == market.quoteAsset)) revert DuplicateMarket();
            }
            identities[i] = identity.canonicalId;
            if (identity.venue == LaunchVenueV1.UniswapV4) v4Markets |= 1 << i;
            uint256 marketPositions = _committedPositions(market);
            if (marketPositions == 0 || positions + marketPositions > MAX_POSITIONS) revert InvalidMarket();
            positions += marketPositions;
            if (marketPositions > 1) registry.requireEligible(market.adapterId, market.profileId,
                market.configVersion, capabilities | LaunchCapabilitiesV1.MULTI_POSITION);
        }
        if (allocated > plan.token.supply) revert InvalidMarket();
    }

    function _committedPositions(MarketConfigV1 calldata market) private view returns (uint256) {
        ProfileRegistrationV1 memory profile = registry.profile(market.profileId);
        if (!profile.enabled || profile.adapterId != market.adapterId) revert InvalidMarket();
        if (profile.configSchema == V4MarketConfigLibV2.CONFIG_SCHEMA) {
            return abi.decode(market.config, (V4MarketConfigV2)).positions.length;
        } else if (profile.configSchema == V4MarketConfigLibV3.CONFIG_SCHEMA) {
            return abi.decode(market.config, (V4MarketConfigV3)).positions.length;
        } else if (profile.configSchema == V4MarketConfigLibV4.CONFIG_SCHEMA) {
            return abi.decode(market.config, (V4MarketConfigV4)).positions.length;
        } else if (profile.configSchema == V4MarketConfigLibV6.CONFIG_SCHEMA) {
            return abi.decode(market.config, (V4MarketConfigV6)).positions.length;
        } else if (profile.configSchema == keccak256("(uint8,uint24,bytes32,uint160,(int24,int24,uint128,uint256)[])")) {
            return abi.decode(market.config, (AbyssMarketConfigV1)).positions.length;
        }
        revert InvalidMarket();
    }

    function validateRewardTreasuries(LaunchPlanV1 calldata plan, address rewards) external view {
        if (rewards == address(0)) return;
        for (uint256 i; i < plan.markets.length; ++i) {
            MarketConfigV1 calldata market = plan.markets[i];
            bytes32 schema = registry.profile(market.profileId).configSchema;
            if (schema == V4MarketConfigLibV2.CONFIG_SCHEMA) {
                V4MarketConfigV2 memory config = abi.decode(market.config, (V4MarketConfigV2));
                if (config.treasury == rewards && config.hookFeePips != 0 && config.protocolFeeDenominator != 0) revert InvalidFeePolicy();
            } else if (schema == V4MarketConfigLibV3.CONFIG_SCHEMA) {
                V4MarketConfigV3 memory config = abi.decode(market.config, (V4MarketConfigV3));
                if (config.treasury == rewards && config.hookFeePips != 0 && config.protocolFeeDenominator != 0) revert InvalidFeePolicy();
            } else if (schema == V4MarketConfigLibV4.CONFIG_SCHEMA) {
                V4MarketConfigV4 memory config = abi.decode(market.config, (V4MarketConfigV4));
                if (config.treasury == rewards && config.hookFeePips != 0 && config.protocolFeeDenominator != 0) revert InvalidFeePolicy();
            } else if (schema == V4MarketConfigLibV6.CONFIG_SCHEMA) {
                V4MarketConfigV6 memory config = abi.decode(market.config, (V4MarketConfigV6));
                if (config.treasury == rewards && config.hookFeePips != 0 && config.protocolFeeDenominator != 0) revert InvalidFeePolicy();
            }
        }
    }

    function validateAssets(LaunchPlanV1 calldata plan, address token) external view {
        for (uint256 i; i < plan.feeAssets.length; ++i) {
            if (plan.feeAssets[i].asset != token && plan.feeAssets[i].asset.code.length == 0) revert InvalidMarket();
        }
        for (uint256 i; i < plan.markets.length; ++i) if (plan.markets[i].quoteAsset.code.length == 0) revert InvalidMarket();
        for (uint256 i; i < plan.funding.length; ++i) {
            AssetFundingV1 calldata funding = plan.funding[i];
            if (funding.asset.code.length == 0) revert InvalidMarket();
            if (funding.kind == FundingKindV1.Swap && funding.inputAsset != address(0)
                && !registry.fundingInputAllowed(funding.inputAsset)) revert InvalidMarket();
        }
    }

    function rewardAssets(LaunchPlanV1 calldata plan) external pure returns (address[] memory assets) {
        uint256 count;
        for (uint256 i; i < plan.feeAssets.length; ++i) if (plan.feeAssets[i].rewardsBps != 0) ++count;
        assets = new address[](count);
        count = 0;
        for (uint256 i; i < plan.feeAssets.length; ++i) if (plan.feeAssets[i].rewardsBps != 0) assets[count++] = plan.feeAssets[i].asset;
    }

    function validatePreparedMarket(PreparedMarketV1 memory prepared, MarketIdentityV1 memory expected, address hub,
        uint32 positionCountSoFar) external view
    {
        if (keccak256(abi.encode(prepared.identity)) != keccak256(abi.encode(expected))
            || prepared.positionCount == 0 || prepared.positionCount > MAX_POSITIONS
            || positionCountSoFar + prepared.positionCount > MAX_POSITIONS || prepared.exclusions.length > 16
            || prepared.feeSource.code.length == 0 || prepared.custody.code.length == 0
            || prepared.mintExecutor.code.length == 0 || prepared.buyExecutor.code.length == 0
            || ILaunchFeeSourceV1(prepared.feeSource).hub() != hub) revert InvalidMarket();
    }

    function verifyMintedMarket(address adapter, address token, PreparedMarketV1 memory prepared,
        PositionIdentityV1[] memory positions, MarketConfigV1 calldata marketConfig, uint256 spent,
        uint256 quoteBefore, uint256 coreBefore, uint256 adapterBefore) external view
    {
        address holder = registry.core();
        if (spent == 0 || spent > marketConfig.tokenBudget || positions.length != prepared.positionCount
            || SafeTransferLib.balanceOf(token, holder) + spent != coreBefore
            || SafeTransferLib.balanceOf(token, adapter) != adapterBefore
            || SafeTransferLib.balanceOf(marketConfig.quoteAsset, adapter) != quoteBefore) revert InvalidPositions();
        for (uint256 i; i < positions.length; ++i) {
            (uint128 liquidity, address owner) = ILaunchMarketAdapterV1(adapter).readPosition(positions[i]);
            if (liquidity != positions[i].liquidity || owner != prepared.custody) revert InvalidPositions();
        }
    }

    function validateIdentity(MarketIdentityV1 memory identity, address token, address quote, bytes32 profileId) public view {
        address currency0 = token < quote ? token : quote;
        address currency1 = token < quote ? quote : token;
        bytes32 canonicalId = keccak256(abi.encode(block.chainid, identity.venue, identity.manager,
            identity.factory, identity.pool, identity.poolId, identity.profileId));
        ProfileRegistrationV1 memory profile = registry.profile(profileId);
        ProfileTopologyV1 memory topology = registry.profileTopology(profileId);
        if (identity.currency0 != currency0 || identity.currency1 != currency1 || identity.profileId != profileId
            || identity.canonicalId != canonicalId || identity.poolId == bytes32(0) || identity.manager.code.length == 0
            || identity.openingSqrtPriceX96 == 0 || identity.tickSpacing <= 0 || identity.factory != profile.factory) revert InvalidMarket();
        if (identity.venue == LaunchVenueV1.UniswapV4) {
            if (identity.pool != address(0) || identity.factory != address(0) || identity.manager != profile.venue
                || identity.poolId != keccak256(abi.encode(currency0, currency1, identity.fee, identity.tickSpacing, identity.hook)))
                revert InvalidMarket();
            if (topology.configVersion == 4 || topology.configVersion == 6) {
                _validateAdmittedIdentity(identity, profile, topology);
            } else if (topology.hookTopology == LaunchHookTopologyV1.SharedV4) {
                if (topology.configVersion != 2 || profileId != V4MarketConfigLibV2.PROFILE_ID
                    || profile.configSchema != V4MarketConfigLibV2.CONFIG_SCHEMA || identity.hook != profile.hook
                    || identity.hook.code.length == 0) revert InvalidMarket();
            } else if (topology.hookTopology == LaunchHookTopologyV1.PoolBoundV4) {
                if (topology.configVersion != 3 || profileId != V4MarketConfigLibV3.PROFILE_ID
                    || profile.configSchema != V4MarketConfigLibV3.CONFIG_SCHEMA || profile.hook != address(0)
                    || topology.hookDeployer == address(0) || topology.hookCreationCodeHash == bytes32(0)
                    || identity.hook == address(0) || !V4HookFlags.hasSharedLaunchV2Permissions(identity.hook)) revert InvalidMarket();
            } else revert InvalidMarket();
        } else if (topology.hookTopology != LaunchHookTopologyV1.None || identity.hook != profile.hook
            || identity.pool == address(0) || identity.factory != profile.venue) revert InvalidMarket();
    }

    function _validateAdmittedIdentity(MarketIdentityV1 memory identity, ProfileRegistrationV1 memory profile,
        ProfileTopologyV1 memory topology) private view
    {
        LaunchEnvelopeV2 memory e = registry.profileEnvelope(identity.profileId);
        if (e.economicVersion != 3 || e.configVersion != topology.configVersion || e.topology != topology.hookTopology
            || e.graph.manager != identity.manager || topology.hookDeployer != e.graph.hookDeployer
            || topology.hookCreationCodeHash != e.graph.hookCreationCodeHash || topology.hookDeployer == address(0)
            || topology.hookCreationCodeHash == bytes32(0) || e.callbackFlags != 0x1afc || e.callbackMask != 0x3fff
            || identity.hook == address(0) || !V4HookFlags.hasSharedLaunchV2Permissions(identity.hook)) revert InvalidMarket();
        if (topology.hookTopology == LaunchHookTopologyV1.SharedV4) {
            if (topology.configVersion != 4 || profile.configSchema != V4MarketConfigLibV4.CONFIG_SCHEMA
                || identity.hook != profile.hook || identity.hook != e.graph.hookRoot || identity.hook.code.length == 0)
                revert InvalidMarket();
        } else if (topology.hookTopology == LaunchHookTopologyV1.PoolBoundV4) {
            if (topology.configVersion != 6 || profile.configSchema != V4MarketConfigLibV6.CONFIG_SCHEMA
                || profile.hook != address(0) || e.graph.hookRoot != address(0)) revert InvalidMarket();
        } else revert InvalidMarket();
    }

    function _validateBuys(LaunchPlanV1 calldata plan) private pure {
        for (uint256 i; i < plan.buys.length; ++i) {
            InitialBuyV1 calldata buy = plan.buys[i];
            if (buy.marketIndex >= plan.markets.length || buy.quoteAmountIn == 0 || buy.minTokenOut == 0
                || buy.recipient == address(0) || buy.recipient == plan.orchestrator) revert InvalidBuy();
            address quote = plan.markets[buy.marketIndex].quoteAsset;
            bool funded;
            for (uint256 j; j < plan.funding.length; ++j) if (plan.funding[j].asset == quote) funded = true;
            if (!funded) revert InvalidFunding();
        }
        for (uint256 i; i < plan.funding.length; ++i) {
            uint256 required;
            for (uint256 j; j < plan.buys.length; ++j) {
                if (plan.markets[plan.buys[j].marketIndex].quoteAsset == plan.funding[i].asset) required += plan.buys[j].quoteAmountIn;
            }
            if (plan.funding[i].amount < required) revert InvalidFunding();
        }
    }
    function _feeAsset(LaunchPlanV1 calldata plan, address asset) private pure returns (bool) {
        for (uint256 i; i < plan.feeAssets.length; ++i) if (plan.feeAssets[i].asset == asset) return true;
        return false;
    }

    function validatePreparedSource(FeeAssetPolicyV2[] calldata policies, ILaunchDirectoryV1 directory,
        bytes32 launchId, address source, uint32 marketIndex) external view
    {
        address[] memory assets = ILaunchFeeSourceV1(source).assets();
        if (assets.length == 0 || assets.length > 8) revert InvalidMarket();
        address previous;
        for (uint256 i; i < assets.length; ++i) {
            bool committed;
            for (uint256 j; j < policies.length; ++j) if (policies[j].asset == assets[i]) committed = true;
            if (!committed || assets[i] <= previous) revert InvalidMarket();
            previous = assets[i];
        }
        for (uint32 i; i < marketIndex; ++i) {
            (, PreparedMarketV1 memory prepared) = directory.market(launchId, i);
            if (prepared.feeSource == source) revert DuplicateMarket();
        }
    }

    function collectExclusions(ILaunchDirectoryV1 directory, bytes32 launchId, address token, address hub, address rewards)
        external view returns (address[] memory exclusions)
    {
        uint256 markets = directory.marketCount(launchId);
        if (markets > MAX_MARKETS) revert InvalidMarket();
        exclusions = new address[](5 + markets * 23);
        uint256 count;
        count = _exclude(exclusions, count, registry.core());
        count = _exclude(exclusions, count, fundingEscrow);
        count = _exclude(exclusions, count, token);
        count = _exclude(exclusions, count, hub);
        count = _exclude(exclusions, count, rewards);
        for (uint32 i; i < markets; ++i) {
            (address adapter, PreparedMarketV1 memory prepared) = directory.market(launchId, i);
            count = _exclude(exclusions, count, adapter);
            count = _exclude(exclusions, count, prepared.identity.manager);
            count = _exclude(exclusions, count, prepared.identity.pool);
            count = _exclude(exclusions, count, prepared.feeSource);
            count = _exclude(exclusions, count, prepared.custody);
            count = _exclude(exclusions, count, prepared.mintExecutor);
            count = _exclude(exclusions, count, prepared.buyExecutor);
            if (prepared.exclusions.length > 16) revert InvalidMarket();
            for (uint256 j; j < prepared.exclusions.length; ++j) count = _exclude(exclusions, count, prepared.exclusions[j]);
        }
        assembly ("memory-safe") { mstore(exclusions, count) }
    }
    function _exclude(address[] memory exclusions, uint256 count, address account) private pure returns (uint256) {
        if (account == address(0)) return count;
        for (uint256 i; i < count; ++i) if (exclusions[i] == account) return count;
        exclusions[count] = account;
        return count + 1;
    }
}
