// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PreparedMarketV1, PositionIdentityV1 } from "./LaunchTypesV1.sol";
import { ILaunchDirectoryV1 } from "./ILaunchLifecycleV1.sol";

/// @notice Append-only canonical identities. Readiness is always read from core/venue, not cached.
contract LaunchDirectoryV1 is ILaunchDirectoryV1 {
    error Unauthorized();
    error InvalidRecord();
    error DuplicateIdentity();
    error InvalidPage();

    struct LaunchEntry {
        address token;
        address creator;
        address hub;
        uint32 markets;
    }
    struct MarketEntry {
        address adapter;
        PreparedMarketV1 prepared;
        PositionIdentityV1[] positions;
    }

    address public immutable override core;
    mapping(address => bytes32) public override launchOfToken;
    mapping(bytes32 => LaunchEntry) public launch;
    mapping(bytes32 => mapping(uint32 => MarketEntry)) private _markets;
    mapping(bytes32 => bytes32) public launchOfMarket;
    mapping(bytes32 => bytes32) public launchOfPosition;
    bytes32[] private _launches;

    constructor(address core_) {
        if (core_ == address(0)) revert InvalidRecord();
        core = core_;
    }

    modifier onlyCore() {
        if (msg.sender != core) revert Unauthorized();
        _;
    }

    function recordLaunch(bytes32 launchId, address token, address creator, address hub) external override onlyCore {
        if (launchId == bytes32(0) || token.code.length == 0 || creator == address(0) || hub.code.length == 0) revert InvalidRecord();
        if (launch[launchId].token != address(0) || launchOfToken[token] != bytes32(0)) revert DuplicateIdentity();
        launch[launchId] = LaunchEntry(token, creator, hub, 0);
        launchOfToken[token] = launchId;
        _launches.push(launchId);
    }

    function recordMarket(bytes32 launchId, uint32 marketIndex, address adapter, PreparedMarketV1 calldata prepared) external override onlyCore {
        LaunchEntry storage entry = launch[launchId];
        bytes32 marketId = prepared.identity.canonicalId;
        if (
            entry.token == address(0) || marketIndex != entry.markets || marketIndex >= 16
                || adapter.code.length == 0 || marketId == bytes32(0) || prepared.positionCount == 0
                || prepared.positionCount > 32 || prepared.exclusions.length > 16
                || prepared.feeSource.code.length == 0 || prepared.custody.code.length == 0
        ) revert InvalidRecord();
        if (launchOfMarket[marketId] != bytes32(0)) revert DuplicateIdentity();
        MarketEntry storage marketEntry = _markets[launchId][marketIndex];
        marketEntry.adapter = adapter;
        marketEntry.prepared = prepared;
        launchOfMarket[marketId] = launchId;
        ++entry.markets;
    }

    function recordPositions(bytes32 launchId, uint32 marketIndex, PositionIdentityV1[] calldata positions_) external override onlyCore {
        MarketEntry storage entry = _markets[launchId][marketIndex];
        if (entry.adapter == address(0) || entry.positions.length != 0 || positions_.length != entry.prepared.positionCount) revert InvalidRecord();
        for (uint256 i; i < positions_.length; ++i) {
            PositionIdentityV1 calldata position = positions_[i];
            bytes32 expected = keccak256(abi.encode(
                block.chainid, position.marketId, position.manager, position.custody,
                position.tokenId, position.tickLower, position.tickUpper, position.salt
            ));
            if (
                position.canonicalId != expected || position.marketId != entry.prepared.identity.canonicalId
                    || position.manager.code.length == 0 || position.custody != entry.prepared.custody
                    || position.liquidity == 0 || position.tickLower >= position.tickUpper
            ) revert InvalidRecord();
            if (launchOfPosition[expected] != bytes32(0)) revert DuplicateIdentity();
            launchOfPosition[expected] = launchId;
            entry.positions.push(position);
        }
    }

    function market(bytes32 launchId, uint32 marketIndex) external view override returns (address adapter, PreparedMarketV1 memory prepared) {
        MarketEntry storage entry = _markets[launchId][marketIndex];
        return (entry.adapter, entry.prepared);
    }

    function marketCount(bytes32 launchId) external view override returns (uint256) { return launch[launchId].markets; }
    function positionCount(bytes32 launchId, uint32 marketIndex) external view override returns (uint256) { return _markets[launchId][marketIndex].positions.length; }
    function launchCount() external view returns (uint256) { return _launches.length; }

    function positions(bytes32 launchId, uint32 marketIndex, uint256 offset, uint256 limit)
        external view override returns (PositionIdentityV1[] memory values)
    {
        if (limit > 100) revert InvalidPage();
        PositionIdentityV1[] storage stored = _markets[launchId][marketIndex].positions;
        uint256 count = offset < stored.length ? stored.length - offset : 0;
        if (count > limit) count = limit;
        values = new PositionIdentityV1[](count);
        for (uint256 i; i < count; ++i) values[i] = stored[offset + i];
    }

    function launches(uint256 offset, uint256 limit) external view override returns (bytes32[] memory values) {
        if (limit > 100) revert InvalidPage();
        uint256 count = offset < _launches.length ? _launches.length - offset : 0;
        if (count > limit) count = limit;
        values = new bytes32[](count);
        for (uint256 i; i < count; ++i) values[i] = _launches[offset + i];
    }

    function marketIds(bytes32 launchId, uint256 offset, uint256 limit) external view returns (bytes32[] memory values) {
        if (limit > 100) revert InvalidPage();
        uint256 length = launch[launchId].markets;
        uint256 count = offset < length ? length - offset : 0;
        if (count > limit) count = limit;
        values = new bytes32[](count);
        for (uint256 i; i < count; ++i) values[i] = _markets[launchId][uint32(offset + i)].prepared.identity.canonicalId;
    }
}
