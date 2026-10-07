// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { LibBytes } from "solady/utils/LibBytes.sol";
import { PoolBoundHookParametersV2 } from "../PoolBoundHookParametersV2.sol";
import { V4HookFlags } from "../V4HookFlags.sol";
import { PoolBoundLaunchHookBaseV2 } from "./PoolBoundLaunchHookBaseV2.sol";

/// @notice Typed explicit-salt CREATE2 holder for one exact pool-bound creation artifact.
/// @dev Immutable STOP-prefixed chunks preserve the supplied creationCodeHash forever, with the
///      exact PoolBoundHookParametersV2 constructor tuple. No owner, replacement, arbitrary deploy
///      bytes, delegatecall or onchain salt mining exists. Permissionless deployment grants no
///      binding, initialization or payout authority. Review and pin the holder, chunks, concrete
///      artifact and dependencies; this deployer's ABI/provenance records do not prove hook safety.
contract PoolHookDeployerV1 {
    error InvalidHookAddress();
    error InvalidCreationCode();
    error InitCodeTooLarge();
    error DeploymentFailed();

    uint256 private constant MAX_CHUNK_SIZE = 24_575;
    uint256 private constant MAX_INIT_CODE_SIZE = 49_152;
    uint256 private constant CONSTRUCTOR_ARGUMENT_SIZE = 18 * 32;

    address public immutable codeChunk0;
    address public immutable codeChunk1;
    bytes32 public immutable creationCodeHash;
    mapping(address hook => bytes32 codeHash) public deployedCodeHash;

    event HookDeployed(
        address indexed hook,
        bytes32 indexed salt,
        address indexed poolManager,
        address registrar,
        address oracleFactory
    );

    constructor(bytes memory creationCode) {
        if (creationCode.length == 0) revert InvalidCreationCode();
        if (
            creationCode.length > MAX_CHUNK_SIZE * 2
                || creationCode.length + CONSTRUCTOR_ARGUMENT_SIZE > MAX_INIT_CODE_SIZE
        ) revert InitCodeTooLarge();
        creationCodeHash = keccak256(creationCode);
        if (creationCode.length > MAX_CHUNK_SIZE) {
            codeChunk0 = SSTORE2.write(LibBytes.slice(creationCode, 0, MAX_CHUNK_SIZE));
            codeChunk1 = SSTORE2.write(LibBytes.slice(creationCode, MAX_CHUNK_SIZE));
        } else {
            codeChunk0 = SSTORE2.write(creationCode);
            codeChunk1 = address(0);
        }
    }

    function initCodeHash(PoolBoundHookParametersV2 calldata parameters)
        public
        view
        returns (bytes32)
    {
        return keccak256(_initCode(parameters));
    }

    function predict(PoolBoundHookParametersV2 calldata parameters, bytes32 salt)
        public
        view
        returns (address)
    {
        return _predict(salt, initCodeHash(parameters));
    }

    function validHookAddress(address hook) public pure returns (bool) {
        return V4HookFlags.hasSharedLaunchV2Permissions(hook);
    }

    /// @dev Existing-address acceptance is the adapter's exact provenance check, not a fallback.
    function deploy(PoolBoundHookParametersV2 calldata parameters, bytes32 salt)
        external
        returns (PoolBoundLaunchHookBaseV2 hook)
    {
        bytes memory initCode = _initCode(parameters);
        if (!validHookAddress(_predict(salt, keccak256(initCode)))) revert InvalidHookAddress();
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(deployed) {
                if returndatasize() {
                    let output := mload(0x40)
                    returndatacopy(output, 0, returndatasize())
                    revert(output, returndatasize())
                }
            }
        }
        if (deployed.code.length == 0 || deployed.code.length > MAX_CHUNK_SIZE + 1) {
            revert DeploymentFailed();
        }
        deployedCodeHash[deployed] = deployed.codehash;
        hook = PoolBoundLaunchHookBaseV2(deployed);
        emit HookDeployed(
            deployed, salt, parameters.poolManager, parameters.registrar, parameters.oracleFactory
        );
    }

    function _initCode(PoolBoundHookParametersV2 calldata parameters)
        private
        view
        returns (bytes memory initCode)
    {
        bytes memory args = abi.encode(parameters);
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

    function _predict(bytes32 salt, bytes32 initHash) private view returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, initHash)
        ))));
    }
}
