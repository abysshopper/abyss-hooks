// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { V4MarketConfigV6 } from "./V4MarketConfigV6.sol";
import { V4MarketConfigLibV2 } from "../v1/V4MarketConfigLibV2.sol";

library V4MarketConfigLibV6 {
    error InvalidConfiguration();
    bytes32 internal constant CONFIG_SCHEMA = keccak256(
        "(uint16,uint24,int24,uint160,uint24,uint24,uint32,uint8,uint8,address,bool,bytes32,bytes32,bytes32,bytes32,address,uint16,(int24,int24,uint128,bytes32,uint256)[])"
    );

    function validate(V4MarketConfigV6 memory config, address token, address quote, uint256 budget)
        internal pure
    {
        if (config.version != 6 || token == address(0) || quote == address(0) || token == quote || budget == 0
            || config.profileId == bytes32(0) || config.termsDigest == bytes32(0)
            || config.developerBeneficiary == address(0)) revert InvalidConfiguration();
        if (config.minimumHookFeePips > config.hookFeePips || config.hookFeePips > 1_000_000) {
            revert InvalidConfiguration();
        }
        // V6's inclusive hook-fee ceiling is checked above; V2's legacy ceiling is exclusive.
        V4MarketConfigLibV2.validateFields(config.lpFeePips, config.tickSpacing, config.sqrtPriceX96,
            0, config.feeMode, config.protocolFeeDenominator, config.treasury);
        V4MarketConfigLibV2.validatePositions(config.positions, config.tickSpacing,
            config.sqrtPriceX96, token < quote, budget);
    }
}
