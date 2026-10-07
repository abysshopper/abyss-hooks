// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { LibBytes } from "solady/utils/LibBytes.sol";
import { TokenKindV1, TokenConfigV1 } from "../LaunchTypesV1.sol";
import { LaunchTokenParametersV1 } from "./LaunchTokenParametersV1.sol";
import { LaunchERC20V1 } from "./LaunchERC20V1.sol";
import { LaunchERC404V1 } from "./LaunchERC404V1.sol";
import { MultiAssetStakingV1 } from "../modules/MultiAssetStakingV1.sol";

/// @dev Creation code is typed at construction and stored in immutable, inert bytecode chunks.
///      Factory/deployer runtime never embeds DN404, its mirror, and the reward implementations.
abstract contract LifecycleCreationCodeV1 {
    error Unauthorized();
    error InvalidBinding();
    error InitCodeTooLarge();
    error DeploymentFailed();

    uint256 internal constant MAX_CHUNK_SIZE = 24_575;
    uint256 internal constant MAX_INIT_CODE_SIZE = 49_152;
    bytes32 internal constant TOKEN_SALT_DOMAIN = keccak256("BLACK_MARKET_LIFECYCLE_TOKEN_V1");

    address public immutable factory;
    address public immutable core;
    address public immutable codeChunk0;
    address public immutable codeChunk1;
    bytes32 public immutable creationCodeHash;

    constructor(address factory_, address core_, bytes memory creationCode) {
        if (factory_ == address(0) || core_ == address(0)) revert InvalidBinding();
        if (creationCode.length > MAX_CHUNK_SIZE * 2) revert InitCodeTooLarge();
        factory = factory_;
        core = core_;
        creationCodeHash = keccak256(creationCode);
        if (creationCode.length > MAX_CHUNK_SIZE) {
            codeChunk0 = SSTORE2.write(LibBytes.slice(creationCode, 0, MAX_CHUNK_SIZE));
            codeChunk1 = SSTORE2.write(LibBytes.slice(creationCode, MAX_CHUNK_SIZE));
        } else {
            codeChunk0 = SSTORE2.write(creationCode);
            codeChunk1 = address(0);
        }
    }

    function _initCode(bytes memory args) internal view returns (bytes memory initCode) {
        address chunk0 = codeChunk0;
        address chunk1 = codeChunk1;
        uint256 length0 = chunk0.code.length - 1;
        uint256 length1 = chunk1 == address(0) ? 0 : chunk1.code.length - 1;
        uint256 codeLength = length0 + length1;
        uint256 totalLength = codeLength + args.length;
        if (totalLength > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge();
        initCode = new bytes(totalLength);
        assembly ("memory-safe") {
            let output := add(initCode, 0x20)
            extcodecopy(chunk0, output, 1, length0)
            if length1 { extcodecopy(chunk1, add(output, length0), 1, length1) }
            mcopy(add(output, codeLength), add(args, 0x20), mload(args))
        }
    }

    function _salt(bytes32 launchId, bytes32 configSalt) internal view returns (bytes32) {
        if (launchId == bytes32(0)) revert InvalidBinding();
        return keccak256(abi.encode(TOKEN_SALT_DOMAIN, block.chainid, core, launchId, configSalt));
    }

    function _predict(bytes32 salt, bytes memory initCode) internal view returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode))
        ))));
    }

    function _deploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        if (msg.sender != factory) revert Unauthorized();
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if and(iszero(deployed), returndatasize()) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }
}

contract LaunchERC20DeployerV1 is LifecycleCreationCodeV1 {
    constructor(address factory_, address core_)
        LifecycleCreationCodeV1(factory_, core_, type(LaunchERC20V1).creationCode)
    { }

    function tokenKind() external pure returns (TokenKindV1) {
        return TokenKindV1.ERC20;
    }

    function predictToken(bytes32 launchId, TokenConfigV1 calldata config)
        external view returns (address)
    {
        return _predict(_salt(launchId, config.salt), _tokenInitCode(launchId, config));
    }

    function deployToken(bytes32 launchId, TokenConfigV1 calldata config)
        external returns (address)
    {
        return _deploy(_salt(launchId, config.salt), _tokenInitCode(launchId, config));
    }

    function _tokenInitCode(bytes32 launchId, TokenConfigV1 calldata config)
        private view returns (bytes memory)
    {
        LaunchTokenParametersV1.validate(config);
        if (config.kind != TokenKindV1.ERC20) revert InvalidBinding();
        return _initCode(abi.encode(core, factory, launchId, config));
    }
}

contract LaunchERC404DeployerV1 is LifecycleCreationCodeV1 {
    constructor(address factory_, address core_)
        LifecycleCreationCodeV1(factory_, core_, type(LaunchERC404V1).creationCode)
    { }

    function tokenKind() external pure returns (TokenKindV1) {
        return TokenKindV1.ERC404;
    }

    function predictToken(bytes32 launchId, TokenConfigV1 calldata config)
        external view returns (address)
    {
        return _predict(_salt(launchId, config.salt), _tokenInitCode(launchId, config));
    }

    function deployToken(bytes32 launchId, TokenConfigV1 calldata config)
        external returns (address)
    {
        return _deploy(_salt(launchId, config.salt), _tokenInitCode(launchId, config));
    }

    function _tokenInitCode(bytes32 launchId, TokenConfigV1 calldata config)
        private view returns (bytes memory)
    {
        LaunchTokenParametersV1.validate(config);
        if (config.kind != TokenKindV1.ERC404) revert InvalidBinding();
        return _initCode(abi.encode(core, factory, launchId, config));
    }
}

contract LaunchStakingDeployerV1 is LifecycleCreationCodeV1 {
    bytes32 private constant STAKING_SALT_DOMAIN = keccak256("BLACK_MARKET_LIFECYCLE_STAKING_V1");

    constructor(address factory_, address core_)
        LifecycleCreationCodeV1(factory_, core_, type(MultiAssetStakingV1).creationCode)
    { }

    function deployStaking(bytes32 launchId, address token, address hub, address[] calldata assets)
        external returns (address)
    {
        bytes32 salt = keccak256(abi.encode(STAKING_SALT_DOMAIN, block.chainid, core, launchId));
        return _deploy(salt, _initCode(abi.encode(token, hub, assets)));
    }
}
