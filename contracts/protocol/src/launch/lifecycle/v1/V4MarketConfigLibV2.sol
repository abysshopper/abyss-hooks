// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { V4MarketConfigV2, V4PositionConfigV1 } from "./V4MarketConfigV2.sol";

/// @notice Shared, exact bounds check for the frozen V4 lifecycle market configuration tuple.
/// @dev Also usable by the launch plan validator so admission and execution cannot diverge.
library V4MarketConfigLibV2 {
    error InvalidConfiguration();
    error QuoteDebtForbidden();

    uint24 internal constant MAX_HOOK_FEE_PIPS = 1_000_000;
    uint256 internal constant MAX_POSITIONS = 32;
    /// @dev v3: the profile's trust graph now includes the registrar-only pool-opening
    ///      completion boundary (root beforeDonate mask + V2 locker); the wire tuple is
    ///      unchanged, but committed plans must bind the new dependency digest.
    bytes32 internal constant PROFILE_ID = keccak256("black-market.v4-lifecycle-market.v3");
    bytes32 internal constant CONFIG_SCHEMA = keccak256(
        "(uint16,uint24,int24,uint160,uint24,uint8,uint8,address,bool,bytes32,(int24,int24,uint128,bytes32,uint256)[])"
    );

    /// @dev `tokenBudget` is the market's committed launch-token budget; the sum of per-position
    ///      maximum spends may not exceed it. Every range must be token-only at the opening price
    ///      in either orientation, i.e. minting there can require zero quote.
    function validate(
        V4MarketConfigV2 memory config,
        address token,
        address quote,
        uint256 tokenBudget
    ) internal pure {
        if (token == address(0) || quote == address(0) || token == quote || tokenBudget == 0) {
            revert InvalidConfiguration();
        }
        if (config.version != 2) revert InvalidConfiguration();
        validateFields(
            config.lpFeePips,
            config.tickSpacing,
            config.sqrtPriceX96,
            config.hookFeePips,
            config.feeMode,
            config.protocolFeeDenominator,
            config.treasury
        );
        validatePositions(
            config.positions, config.tickSpacing, config.sqrtPriceX96, token < quote, tokenBudget
        );
    }

    /// @dev Common V2/V3 economic bounds; each wire version validates its own tuple/version.
    function validateFields(
        uint24 lpFeePips,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint24 hookFeePips,
        uint8 feeMode,
        uint8 protocolFeeDenominator,
        address treasury
    ) internal pure {
        if (
            lpFeePips >= LPFeeLibrary.MAX_LP_FEE || tickSpacing < TickMath.MIN_TICK_SPACING
                || tickSpacing > TickMath.MAX_TICK_SPACING || sqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE || hookFeePips >= MAX_HOOK_FEE_PIPS
                || feeMode > 1
                || (protocolFeeDenominator != 0
                    && (protocolFeeDenominator < 4 || protocolFeeDenominator > 10))
                || (protocolFeeDenominator != 0 && treasury == address(0))
        ) revert InvalidConfiguration();
    }

    /// @dev Shares exact rounded token debt, duplicate membership and gross-per-tick math.
    function validatePositions(
        V4PositionConfigV1[] memory positions,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        bool tokenIs0,
        uint256 tokenBudget
    ) internal pure {
        if (positions.length == 0 || positions.length > MAX_POSITIONS) {
            revert InvalidConfiguration();
        }
        uint256 maximumBudget;
        for (uint256 i; i < positions.length; ++i) {
            _validatePosition(positions[i], tickSpacing, sqrtPriceX96, tokenIs0);
            maximumBudget += positions[i].maxTokenAmount;
            for (uint256 j; j < i; ++j) {
                if (
                    positions[j].tickLower == positions[i].tickLower
                        && positions[j].tickUpper == positions[i].tickUpper
                        && positions[j].salt == positions[i].salt
                ) revert InvalidConfiguration();
            }
        }
        if (maximumBudget > tokenBudget) revert InvalidConfiguration();
        _validateCanonicalLiquidityBounds(positions, tickSpacing);
    }

    function _validatePosition(
        V4PositionConfigV1 memory p,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        bool tokenIs0
    ) private pure {
        if (
            p.tickLower >= p.tickUpper || p.tickLower < TickMath.MIN_TICK
                || p.tickUpper > TickMath.MAX_TICK || p.tickLower % tickSpacing != 0
                || p.tickUpper % tickSpacing != 0 || p.liquidity == 0 || p.maxTokenAmount == 0
        ) revert InvalidConfiguration();
        if (p.liquidity > uint128(type(int128).max)) revert InvalidConfiguration();
        // Token-only at opening: the range must lie entirely on the launch-token side of the price.
        // price < range => only token0 required; price > range => only token1 required.
        uint160 lower = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(p.tickUpper);
        if (tokenIs0 ? sqrtPriceX96 > lower : sqrtPriceX96 < upper) revert QuoteDebtForbidden();
        uint256 debt = tokenIs0
            ? SqrtPriceMath.getAmount0Delta(lower, upper, p.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(lower, upper, p.liquidity, true);
        // The locker repays principal in one positive settle(), which also casts to
        // int128. Negative principal -2^127 fits, but its positive repayment does not.
        if (debt > uint256(uint128(type(int128).max)) || debt > p.maxTokenAmount) {
            revert InvalidConfiguration();
        }
    }

    /// @dev Canonical mint-domain admission: PoolManager casts each positive liquidity
    ///      delta to signed int128 and the resulting per-currency settlement deltas are
    ///      signed int128 too. Admission bounds actual rounded-up canonical token debt,
    ///      not a permissive spending maximum; oversized maxima do not change mint debt.
    ///      Pool rejects any tick whose gross liquidity exceeds `tickSpacingToMaxLiquidityPerTick`;
    ///      gross is per-TICK, summed over every position touching the tick in EITHER
    ///      endpoint role (a lower of one position may coincide with the upper of another).
    ///      Foreign out-of-range liquidity cannot pre-load ticks before completion
    ///      (registrar-only opening boundary), so the plan's own positions are the complete
    ///      pre-mint gross set.
    function _validateCanonicalLiquidityBounds(
        V4PositionConfigV1[] memory positions,
        int24 tickSpacing
    ) private pure {
        uint128 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing);
        for (uint256 i; i < positions.length; ++i) {
            uint256 lowerGross;
            uint256 upperGross;
            for (uint256 j; j < positions.length; ++j) {
                if (
                    positions[j].tickLower == positions[i].tickLower
                        || positions[j].tickUpper == positions[i].tickLower
                ) lowerGross += positions[j].liquidity;
                if (
                    positions[j].tickUpper == positions[i].tickUpper
                        || positions[j].tickLower == positions[i].tickUpper
                ) upperGross += positions[j].liquidity;
            }
            if (lowerGross > maxPerTick || upperGross > maxPerTick) revert InvalidConfiguration();
        }
    }
}
