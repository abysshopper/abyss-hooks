// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { V4MarketConfigV3 } from "./V4MarketConfigV3.sol";
import { V4MarketConfigLibV2 } from "./V4MarketConfigLibV2.sol";

/// @notice Exact V3 admission with the shared lifecycle economic and token-only mint bounds.
library V4MarketConfigLibV3 {
    error InvalidConfiguration();

    bytes32 internal constant PROFILE_ID =
        keccak256("black-market.v4-pool-bound-lifecycle-market.v1");
    bytes32 internal constant CONFIG_SCHEMA = keccak256(
        "(uint16,uint24,int24,uint160,uint24,uint8,uint8,address,bool,bytes32,bytes32,(int24,int24,uint128,bytes32,uint256)[])"
    );

    function validate(
        V4MarketConfigV3 memory config,
        address token,
        address quote,
        uint256 tokenBudget
    ) internal pure {
        if (token == address(0) || quote == address(0) || token == quote || tokenBudget == 0) {
            revert InvalidConfiguration();
        }
        if (config.version != 3) revert InvalidConfiguration();
        V4MarketConfigLibV2.validateFields(
            config.lpFeePips,
            config.tickSpacing,
            config.sqrtPriceX96,
            config.hookFeePips,
            config.feeMode,
            config.protocolFeeDenominator,
            config.treasury
        );
        V4MarketConfigLibV2.validatePositions(
            config.positions, config.tickSpacing, config.sqrtPriceX96, token < quote, tokenBudget
        );
    }
}
