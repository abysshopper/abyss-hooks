// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DN404 } from "../../../../../lib/dn404/src/DN404.sol";
import { LibString } from "solady/utils/LibString.sol";
import { TokenKindV1, TokenConfigV1 } from "../LaunchTypesV1.sol";
import { LaunchTokenContextV1 } from "./LaunchTokenContextV1.sol";
import { LaunchDN404MirrorV1 } from "./LaunchDN404MirrorV1.sol";

/// @notice Fixed-supply ERC7631 token using the pinned DN404 implementation and real mirror.
/// @dev ERC20 transfers, burns and direct mirror transfers all checkpoint the same balances.
///      Automatic NFTs materialize only with authorized fungible transfers until Active.
contract LaunchERC404V1 is DN404, LaunchTokenContextV1 {
    uint256 public constant MAX_NFTS = 10_000;
    string private _name;
    string private _symbol;
    string private _metadataURI;
    uint256 private immutable _nftUnit;

    constructor(address authority_, address factory_, bytes32 launchId_, TokenConfigV1 memory config)
        LaunchTokenContextV1(authority_, factory_, launchId_, config)
    {
        if (config.kind != TokenKindV1.ERC404) revert InvalidTokenConfiguration();
        _name = config.name;
        _symbol = config.symbol;
        _metadataURI = config.metadataURI;
        _nftUnit = config.nftUnit;
        _initializeDN404(config.supply, authority_, address(new LaunchDN404MirrorV1(msg.sender)));
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function unit() external view returns (uint256) {
        return _nftUnit;
    }

    function maxNFTSupply() external view returns (uint256) {
        return initialSupply / _nftUnit;
    }

    function baseURI() external view returns (string memory) {
        return _metadataURI;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        uint256 allowed = allowance(account, msg.sender);
        if (allowed != type(uint256).max) {
            if (amount > allowed) revert InsufficientAllowance();
            _ref(_getDN404Storage().allowance, account, msg.sender).value = allowed - amount;
        }
        _burn(account, amount);
    }

    function _unit() internal view override returns (uint256) {
        return _nftUnit;
    }

    function _tokenURI(uint256 id) internal view override returns (string memory) {
        if (bytes(_metadataURI).length == 0) return "";
        return string.concat(_metadataURI, LibString.toString(id));
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        _beforeLifecycleTransfer(msg.sender, from, to, amount, false);
        super._transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal override {
        _beforeLifecycleTransfer(msg.sender, from, address(0), amount, false);
        super._burn(from, amount);
    }

    function _transferFromNFT(address from, address to, uint256 id, address operator)
        internal
        override
    {
        // DN404 routes mirror transferFrom and both safeTransferFrom overloads here, with the
        // original operator. Checking msg.sender (the trusted mirror) would be a bypass.
        _beforeLifecycleTransfer(operator, from, to, _nftUnit, true);
        super._transferFromNFT(from, to, id, operator);
    }

    function _tokenBalance(address account) internal view override returns (uint256) {
        return DN404.balanceOf(account);
    }

    function _tokenSupply() internal view override returns (uint256) {
        return DN404.totalSupply();
    }

    function _burnInventory(uint256 amount) internal override {
        _burn(authority, amount);
    }
}
