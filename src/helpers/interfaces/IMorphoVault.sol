// Based on: Kiln DeFi Integration Vault (ERC-4626 Vault)
//
// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IMorphoVault
 * @notice Self-contained interface for a Morpho-style ERC-4626 vault.
 * @dev This intentionally avoids importing external Kiln-specific types (e.g. IFeeDispatcher),
 *      so it can compile within this repository as a helper interface, similar to `IAavePool.sol`.
 */
interface IMorphoVault {
    /* -------------------------------------------------------------------------- */
    /*                                    TYPES                                   */
    /* -------------------------------------------------------------------------- */

    enum AdditionalRewardsStrategy {
        None,
        Claim,
        Reinvest
    }

    /* -------------------------------------------------------------------------- */
    /*                                    EVENTS                                  */
    /* -------------------------------------------------------------------------- */

    event AdditionalRewardsStrategyUpdated(AdditionalRewardsStrategy newAdditionalRewardsStrategy);
    event DepositFeeUpdated(uint256 newDepositFee);
    event RewardFeeUpdated(uint256 newRewardFee);
    event ConnectorRegistryUpdated(address newConnectorRegistry);
    event ConnectorNameUpdated(bytes32 newConnectorName);
    event TransferableUpdated(bool newTransferableFlag);
    event NameInitialized(string name);
    event SymbolInitialized(string symbol);
    event AssetInitialized(address asset);
    event OffsetInitialized(uint8 offset);
    event FeeDispatcherInitialized(address feeDispatcher);
    event MinTotalSupplyInitialized(uint256 newMinTotalSupply);
    event BlockListUpdated(address newBlockList);
    event RewardsClaimed(address indexed rewardsAsset, uint256 amount);

    // ERC-4626 events (EIP-4626)
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    /* -------------------------------------------------------------------------- */
    /*                                  ERC20 API                                 */
    /* -------------------------------------------------------------------------- */

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    /* -------------------------------------------------------------------------- */
    /*                                  ERC4626 API                                */
    /* -------------------------------------------------------------------------- */

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    function maxDeposit(address receiver) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);

    function maxMint(address receiver) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);

    /* -------------------------------------------------------------------------- */
    /*                               VAULT EXTENSIONS                              */
    /* -------------------------------------------------------------------------- */

    function dispatchFees() external;
    function collectRewardFees() external;

    function claimAdditionalRewards(address rewardsAsset, bytes calldata payload) external;
    function setAdditionalRewardsStrategy(AdditionalRewardsStrategy strategy) external;

    function setBlockList(address newBlockList) external;
    function forceWithdraw(address blockedUser) external returns (uint256);

    function pauseDeposit() external;
    function unpauseDeposit() external;

    function setDepositFee(uint256 newDepositFee) external;
    function setRewardFee(uint256 newRewardFee) external;

    /* -------------------------------------------------------------------------- */
    /*                                   GETTERS                                  */
    /* -------------------------------------------------------------------------- */

    function transferable() external view returns (bool);
    function connectorRegistry() external view returns (address);
    function connectorName() external view returns (bytes32);
    function depositFee() external view returns (uint256);
    function rewardFee() external view returns (uint256);
    function additionalRewardsStrategy() external view returns (AdditionalRewardsStrategy);
    function collectableRewardFees() external view returns (uint256);
    function blockList() external view returns (address);
    function pendingDepositFee() external view returns (uint256);
    function pendingRewardFee() external view returns (uint256);
}

