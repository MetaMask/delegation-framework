// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IAavePool
 * @notice Simplified Aave Pool interface for supply and withdraw
 * @dev In production, use the official Aave IPool interface
 */
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveAToken(address asset) external view returns (address);
}

/**
 * @title IAaveDataProvider
 * @notice Aave Data Provider interface to get aToken address
 * @dev In production, use the official Aave IProtocolDataProvider interface
 */
interface IAaveDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (address aTokenAddress, address, address);
}

/**
 * @title IStaticATokenFactory
 * @notice StaticATokenFactory interface to get wrapper addresses
 * @dev Factory deployed by Aave DAO to manage stataToken instances
 */
interface IStaticATokenFactory {
    function getStataToken(address underlying) external view returns (address);
}

/**
 * @title IERC4626
 * @notice ERC-4626 vault interface for StaticAToken wrapper
 * @dev Wraps rebasing aTokens into fixed-supply tokens
 */
interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

