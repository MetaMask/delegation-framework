// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IVaultEthStaking
 * @author StakeWise
 * @notice Defines the interface for the VaultEthStaking contract
 */
interface IVaultEthStaking {
    /**
     * @notice Deposit ETH to the Vault
     * @param receiver The address that will receive Vault's shares
     * @param referrer The address of the referrer. Set to zero address if not used.
     * @return shares The number of shares minted
     */
    function deposit(address receiver, address referrer) external payable returns (uint256 shares);
}

/**
 * @title IVaultEnterExit
 * @author StakeWise
 * @notice Defines the interface for the VaultEnterExit contract
 */
interface IVaultEnterExit {
    /**
     * @notice Locks shares to the exit queue. The shares continue earning rewards until they will be burned by the Vault.
     * @param shares The number of shares to lock
     * @param receiver The address that will receive assets upon withdrawal
     * @return positionTicket The position ticket of the exit queue
     */
    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket);

    /**
     * @notice Get the exit queue index to claim exited assets from
     * @param positionTicket The exit queue position ticket to get the index for
     * @return The exit queue index that should be used to claim exited assets.
     *         Returns -1 in case such index does not exist.
     */
    function getExitQueueIndex(uint256 positionTicket) external view returns (int256);

    /**
     * @notice Calculates the number of shares and assets that can be claimed from the exit queue.
     * @param receiver The address that will receive assets upon withdrawal
     * @param positionTicket The exit queue ticket received after the `enterExitQueue` call
     * @param timestamp The timestamp when the shares entered the exit queue
     * @param exitQueueIndex The exit queue index at which the shares were burned. It can be looked up by calling
     * `getExitQueueIndex`.
     * @return leftShares The number of shares that are still in the queue
     * @return claimedShares The number of claimed shares
     * @return claimedAssets The number of claimed assets
     */
    function calculateExitedAssets(
        address receiver,
        uint256 positionTicket,
        uint256 timestamp,
        uint256 exitQueueIndex
    )
        external
        view
        returns (uint256 leftShares, uint256 claimedShares, uint256 claimedAssets);

    /**
     * @notice Claims assets that were withdrawn by the Vault. It can be called only after the `enterExitQueue` call by the
     * `receiver`.
     * @param positionTicket The exit queue ticket received after the `enterExitQueue` call
     * @param timestamp The timestamp when the shares entered the exit queue
     * @param exitQueueIndex The exit queue index at which the shares were burned. It can be looked up by calling
     * `getExitQueueIndex`.
     * @return newPositionTicket The new exit queue ticket in case not all the shares were burned. Otherwise 0.
     * @return claimedShares The number of shares claimed
     * @return claimedAssets The number of assets claimed
     */
    function claimExitedAssets(
        uint256 positionTicket,
        uint256 timestamp,
        uint256 exitQueueIndex
    )
        external
        returns (uint256 newPositionTicket, uint256 claimedShares, uint256 claimedAssets);

    /**
     * @notice Redeems assets from the Vault by utilising what has not been staked yet. Can only be called when vault is not
     * collateralized.
     * @param shares The number of shares to burn
     * @param receiver The address that will receive assets
     * @return assets The number of assets withdrawn
     */
    function redeem(uint256 shares, address receiver) external returns (uint256 assets);
}

/**
 * @title IKeeperRewards
 * @author StakeWise
 * @notice Defines the interface for the Keeper contract rewards
 */
interface IKeeperRewards {
    /**
     * @notice Event emitted on rewards update
     * @param caller The address of the function caller
     * @param rewardsRoot The new rewards merkle tree root
     * @param avgRewardPerSecond The new average reward per second
     * @param updateTimestamp The update timestamp used for rewards calculation
     * @param nonce The nonce used for verifying signatures
     * @param rewardsIpfsHash The new rewards IPFS hash
     */
    event RewardsUpdated(
        address indexed caller,
        bytes32 indexed rewardsRoot,
        uint256 avgRewardPerSecond,
        uint64 updateTimestamp,
        uint64 nonce,
        string rewardsIpfsHash
    );

    /**
     * @notice Event emitted on Vault harvest
     * @param vault The address of the Vault
     * @param rewardsRoot The rewards merkle tree root
     * @param totalAssetsDelta The Vault total assets delta since last sync. Can be negative in case of penalty/slashing.
     * @param unlockedMevDelta The Vault execution reward that can be withdrawn from shared MEV escrow. Only used by shared MEV
     * Vaults.
     */
    event Harvested(address indexed vault, bytes32 indexed rewardsRoot, int256 totalAssetsDelta, uint256 unlockedMevDelta);

    /**
     * @notice Event emitted on rewards min oracles number update
     * @param oracles The new minimum number of oracles required to update rewards
     */
    event RewardsMinOraclesUpdated(uint256 oracles);

    /**
     * @notice A struct containing the last synced Vault's cumulative reward
     * @param assets The Vault cumulative reward earned since the start. Can be negative in case of penalty/slashing.
     * @param nonce The nonce of the last sync
     */
    struct Reward {
        int192 assets;
        uint64 nonce;
    }

    /**
     * @notice A struct containing the last unlocked Vault's cumulative execution reward that can be withdrawn from shared MEV
     * escrow. Only used by shared MEV Vaults.
     * @param assets The shared MEV Vault's cumulative execution reward that can be withdrawn
     * @param nonce The nonce of the last sync
     */
    struct UnlockedMevReward {
        uint192 assets;
        uint64 nonce;
    }

    /**
     * @notice A struct containing parameters for rewards update
     * @param rewardsRoot The new rewards merkle root
     * @param avgRewardPerSecond The new average reward per second
     * @param updateTimestamp The update timestamp used for rewards calculation
     * @param rewardsIpfsHash The new IPFS hash with all the Vaults' rewards for the new root
     * @param signatures The concatenation of the Oracles' signatures
     */
    struct RewardsUpdateParams {
        bytes32 rewardsRoot;
        uint256 avgRewardPerSecond;
        uint64 updateTimestamp;
        string rewardsIpfsHash;
        bytes signatures;
    }

    /**
     * @notice A struct containing parameters for harvesting rewards. Can only be called by Vault.
     * @param rewardsRoot The rewards merkle root
     * @param reward The Vault cumulative reward earned since the start. Can be negative in case of penalty/slashing.
     * @param unlockedMevReward The Vault cumulative execution reward that can be withdrawn from shared MEV escrow. Only used by
     * shared MEV Vaults.
     * @param proof The proof to verify that Vault's reward is correct
     */
    struct HarvestParams {
        bytes32 rewardsRoot;
        int160 reward;
        uint160 unlockedMevReward;
        bytes32[] proof;
    }

    /**
     * @notice Previous Rewards Root
     * @return The previous merkle tree root of the rewards accumulated by the Vaults
     */
    function prevRewardsRoot() external view returns (bytes32);

    /**
     * @notice Rewards Root
     * @return The latest merkle tree root of the rewards accumulated by the Vaults
     */
    function rewardsRoot() external view returns (bytes32);

    /**
     * @notice Rewards Nonce
     * @return The nonce used for updating rewards merkle tree root
     */
    function rewardsNonce() external view returns (uint64);

    /**
     * @notice The last rewards update
     * @return The timestamp of the last rewards update
     */
    function lastRewardsTimestamp() external view returns (uint64);

    /**
     * @notice The minimum number of oracles required to update rewards
     * @return The minimum number of oracles
     */
    function rewardsMinOracles() external view returns (uint256);

    /**
     * @notice The rewards delay
     * @return The delay in seconds between rewards updates
     */
    function rewardsDelay() external view returns (uint256);

    /**
     * @notice Get last synced Vault cumulative reward
     * @param vault The address of the Vault
     * @return assets The last synced reward assets
     * @return nonce The last synced reward nonce
     */
    function rewards(address vault) external view returns (int192 assets, uint64 nonce);

    /**
     * @notice Get last unlocked shared MEV Vault cumulative reward
     * @param vault The address of the Vault
     * @return assets The last synced reward assets
     * @return nonce The last synced reward nonce
     */
    function unlockedMevRewards(address vault) external view returns (uint192 assets, uint64 nonce);

    /**
     * @notice Checks whether Vault must be harvested
     * @param vault The address of the Vault
     * @return `true` if the Vault requires harvesting, `false` otherwise
     */
    function isHarvestRequired(address vault) external view returns (bool);

    /**
     * @notice Checks whether the Vault can be harvested
     * @param vault The address of the Vault
     * @return `true` if Vault can be harvested, `false` otherwise
     */
    function canHarvest(address vault) external view returns (bool);

    /**
     * @notice Checks whether rewards can be updated
     * @return `true` if rewards can be updated, `false` otherwise
     */
    function canUpdateRewards() external view returns (bool);

    /**
     * @notice Checks whether the Vault has registered validators
     * @param vault The address of the Vault
     * @return `true` if Vault is collateralized, `false` otherwise
     */
    function isCollateralized(address vault) external view returns (bool);

    /**
     * @notice Update rewards data
     * @param params The struct containing rewards update parameters
     */
    function updateRewards(RewardsUpdateParams calldata params) external;

    /**
     * @notice Harvest rewards. Can be called only by Vault.
     * @param params The struct containing rewards harvesting parameters
     * @return totalAssetsDelta The total reward/penalty accumulated by the Vault since the last sync
     * @return unlockedMevDelta The Vault execution reward that can be withdrawn from shared MEV escrow. Only used by shared MEV
     * Vaults.
     * @return harvested `true` when the rewards were harvested, `false` otherwise
     */
    function harvest(HarvestParams calldata params)
        external
        returns (int256 totalAssetsDelta, uint256 unlockedMevDelta, bool harvested);

    /**
     * @notice Set min number of oracles for confirming rewards update. Can only be called by the owner.
     * @param _rewardsMinOracles The new min number of oracles for confirming rewards update
     */
    function setRewardsMinOracles(uint256 _rewardsMinOracles) external;
}

/**
 * @title IVaultState
 * @author StakeWise
 * @notice Defines the interface for the VaultState contract
 */
interface IVaultState {
    /**
     * @notice Event emitted on checkpoint creation
     * @param shares The number of burned shares
     * @param assets The amount of exited assets
     */
    event CheckpointCreated(uint256 shares, uint256 assets);

    /**
     * @notice Event emitted on minting fee recipient shares
     * @param receiver The address of the fee recipient
     * @param shares The number of minted shares
     * @param assets The amount of minted assets
     */
    event FeeSharesMinted(address receiver, uint256 shares, uint256 assets);

    /**
     * @notice Total assets in the Vault
     * @return The total amount of the underlying asset that is "managed" by Vault
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Function for retrieving total shares
     * @return The amount of shares in existence
     */
    function totalShares() external view returns (uint256);

    /**
     * @notice The Vault's capacity
     * @return The amount after which the Vault stops accepting deposits
     */
    function capacity() external view returns (uint256);

    /**
     * @notice Total assets available in the Vault. They can be staked or withdrawn.
     * @return The total amount of withdrawable assets
     */
    function withdrawableAssets() external view returns (uint256);

    /**
     * @notice Queued Shares
     * @return The total number of shares queued for exit
     */
    function queuedShares() external view returns (uint128);

    /**
     * @notice Returns the number of shares held by an account
     * @param account The account for which to look up the number of shares it has, i.e. its balance
     * @return The number of shares held by the account
     */
    function getShares(address account) external view returns (uint256);

    /**
     * @notice Converts shares to assets
     * @param assets The amount of assets to convert to shares
     * @return shares The amount of shares that the Vault would exchange for the amount of assets provided
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Converts assets to shares
     * @param shares The amount of shares to convert to assets
     * @return assets The amount of assets that the Vault would exchange for the amount of shares provided
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Check whether state update is required
     * @return `true` if state update is required, `false` otherwise
     */
    function isStateUpdateRequired() external view returns (bool);

    /**
     * @notice Updates the total amount of assets in the Vault and its exit queue
     * @param harvestParams The parameters for harvesting Keeper rewards
     */
    function updateState(IKeeperRewards.HarvestParams calldata harvestParams) external;
}

/**
 * @title IEthFoxVault
 * @author StakeWise
 * @notice Defines the interface for the EthFoxVault contract
 */
interface IEthFoxVault is IVaultEthStaking, IVaultEnterExit, IVaultState {
    /**
     * @notice Ejects user from the Vault. Can only be called by the blocklist manager.
     *         The ejected user will be added to the blocklist and all his shares will be sent to the exit queue.
     * @param user The address of the user to eject
     */
    function ejectUser(address user) external;
}
