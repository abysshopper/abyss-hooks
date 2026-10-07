// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum PoolProfile {
    STANDARD,
    STANDARD_ORACLE,
    QUOTE,
    QUOTE_ORACLE
}

/// @notice Complete identity of an Abyss pool. Tokens must be address-sorted.
struct PoolKey {
    address token0;
    address token1;
    PoolProfile profile;
    uint24 fee;
    bool quoteIsToken0;
    bytes32 oracleConfigId;
}

/// @notice Basis-point disposition for one fee asset.
/// @dev A policy is inactive when every field is zero; otherwise its fields must total 10,000.
struct Disposition {
    uint16 ownerBps;
    uint16 rewardsBps;
    uint16 burnBps;
}

/// @notice Custody terms encoded as ERC-721 safe-transfer data for the position locker.
struct Lock {
    address owner;
    address claimAuthority;
    address feeRecipient;
    uint64 unlockTime;
    bool permissionlessClaim;
}

/// @notice Complete input for atomically creating or validating a pool and permanently locking
///         its initial liquidity position.
struct AbyssLaunchParams {
    address launchedToken;
    address feeRecipient;
    address creator;
    PoolKey key;
    uint160 sqrtPriceX96;
    uint160 existingPriceMinimumX96;
    uint160 existingPriceMaximumX96;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 amount0Maximum;
    uint256 amount1Maximum;
    uint256 deadline;
}

/// @notice Final immutable record of a completed launch.
struct AbyssLaunchResult {
    address creator;
    address feeRecipient;
    address pool;
    address positionAccount;
    uint256 tokenId;
    uint256 amount0;
    uint256 amount1;
    bool created;
}

interface IAbyssLaunchFactory {
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function oracleConfigs(bytes32 id)
        external
        view
        returns (uint24 maxAbsTickMove, uint16 cardinality);
    function getPool(bytes32 poolId) external view returns (address);
    function isPool(address pool) external view returns (bool);
    function computePoolId(PoolKey calldata key) external view returns (bytes32);
    function computePoolAddress(PoolKey calldata key) external view returns (address predicted);
    function poolDeployer() external view returns (IAbyssLaunchPoolDeployer);
    function feeVault() external view returns (address);
}

/// @notice Canonical factory-bound pool deployer: pinned per-profile creation-code commitments.
interface IAbyssLaunchPoolDeployer {
    function expectedInitCodeHash(PoolProfile profile) external pure returns (bytes32);
}

interface IAbyssLaunchTokenFactory {
    function launchAuthority(address token) external view returns (address authority);
}

interface IAbyssLaunchPositionManager {
    function factory() external view returns (IAbyssLaunchFactory);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address owner);

    function positions(uint256 tokenId)
        external
        view
        returns (address account, address pool, int24 tickLower, int24 tickUpper, uint128 liquidity);

    function accountFor(uint256 tokenId, address pool) external view returns (address account);

    function createAndInitializePoolIfNecessary(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint160 existingPriceMinimumX96,
        uint160 existingPriceMaximumX96
    ) external returns (address pool, bool created);

    function mint(
        address pool,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Maximum,
        uint256 amount1Maximum,
        uint256 deadline
    ) external returns (uint256 tokenId, uint256 amount0, uint256 amount1);

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface IERC721SafeTransfer {
    function safeTransferFrom(address from, address to, uint256 id) external payable;
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data)
        external
        payable;
}

interface IAbyssLaunchPositionLocker {
    function positionManager() external view returns (IAbyssLaunchPositionManager);

    function locks(uint256 tokenId)
        external
        view
        returns (
            address owner,
            address claimAuthority,
            address feeRecipient,
            uint64 unlockTime,
            bool permissionlessClaim
        );

    function claim(uint256 tokenId) external returns (uint128 amount0, uint128 amount1);
}

interface IAbyssLaunchCoordinator {
    function factory() external view returns (IAbyssLaunchFactory);
    function positionManager() external view returns (IAbyssLaunchPositionManager);
    function positionLocker() external view returns (IAbyssLaunchPositionLocker);
    function tokenFactory() external view returns (IAbyssLaunchTokenFactory);
    function launches(address launchedToken) external view returns (AbyssLaunchResult memory result);
    function launch(AbyssLaunchParams calldata params)
        external
        returns (AbyssLaunchResult memory result);
}

interface IAbyssLaunchPool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function quoteIsToken0() external view returns (bool);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observeTruncated(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );

    function liquidity() external view returns (uint128);

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        );

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IAbyssLaunchRouter {
    function factory() external view returns (IAbyssLaunchFactory);

    function exactInputSingle(
        PoolKey calldata key,
        address recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

interface IAbyssLaunchFixedSupplyToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IAbyssLaunchBurnableToken is IAbyssLaunchFixedSupplyToken {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface IAbyssLaunchTokenBurnSink {
    function token() external view returns (IAbyssLaunchBurnableToken);
    function burn() external returns (uint256 amount);
}
