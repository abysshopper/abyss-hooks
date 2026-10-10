// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

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
        return abi.decode(manager.unlock(abi.encode(key, params, msg.sender, bytes(""))), (BalanceDelta));
    }

    /// @notice Same trade, forwarding caller-supplied hookData to the swap.
    function trade(PoolKey memory key, SwapParams memory params, bytes memory hookData) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, params, msg.sender, hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, SwapParams memory params, address payer, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, address, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
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

/// @notice Fork-only ERC-1271 account that accepts exactly the ECDSA signatures of one test key.
///         The harness etches its runtime code (immutable included) at a hook's declared pass
///         authority, so every admitted pass must be genuinely signed over the digest the hook
///         itself presents. Never deployed on chain; no production key is involved.
contract TestKeySignatureAuthorityFork {
    address public immutable testSigner;

    constructor(address testSigner_) {
        require(testSigner_ != address(0), "test signer required");
        testSigner = testSigner_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.tryRecoverCalldata(digest, signature) == testSigner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice Fork-only ERC20 used only as a quote distinct from a hook's declared required quote,
///         for example when that declared quote is wrapped native itself.
contract AlternateQuoteTokenFork {
    string public constant name = "Alternate quote";
    string public constant symbol = "ALTQ";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    constructor(uint256 supply) {
        totalSupply = supply;
        balanceOf[msg.sender] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
