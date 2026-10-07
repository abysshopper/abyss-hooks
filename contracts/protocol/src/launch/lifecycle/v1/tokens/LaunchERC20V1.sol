// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { TokenKindV1, TokenConfigV1 } from "../LaunchTypesV1.sol";
import { LaunchTokenContextV1 } from "./LaunchTokenContextV1.sol";

/// @notice Fixed-supply ERC20 with irreversible lifecycle gating and optional holder dividends.
contract LaunchERC20V1 is ERC20, LaunchTokenContextV1 {
    string private _name;
    string private _symbol;

    constructor(address authority_, address factory_, bytes32 launchId_, TokenConfigV1 memory config)
        LaunchTokenContextV1(authority_, factory_, launchId_, config)
    {
        if (config.kind != TokenKindV1.ERC20) revert InvalidTokenConfiguration();
        _name = config.name;
        _symbol = config.symbol;
        _mint(authority_, config.supply);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        _beforeLifecycleTransfer(msg.sender, from, to, amount, false);
    }

    function _tokenBalance(address account) internal view override returns (uint256) {
        return ERC20.balanceOf(account);
    }

    function _tokenSupply() internal view override returns (uint256) {
        return ERC20.totalSupply();
    }

    function _burnInventory(uint256 amount) internal override {
        _burn(authority, amount);
    }
}
