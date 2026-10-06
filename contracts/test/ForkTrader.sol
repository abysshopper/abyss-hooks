// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IERC20Fork {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWETHFork is IERC20Fork {
    function deposit() external payable;
}

contract ForkTrader is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) { manager = manager_; }

    function trade(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, params, msg.sender)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, SwapParams memory params, address payer) = abi.decode(data, (PoolKey, SwapParams, address));
        BalanceDelta delta = manager.swap(key, params, "");
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            manager.sync(currency);
            require(IERC20Fork(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(amount))), "payment failed");
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
        }
    }
}
