// Based on:
// https://github.com/Se7en-Seas/boring-vault/blob/main/src/base/Roles/TellerWithMultiAssetSupport.sol
// https://github.com/Veda-Labs/boring-vault/blob/dev/oct-2025/src/base/Roles/TellerWithYieldStreaming.sol

// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IVedaTeller
 * @notice Interface for the user-facing functions of Veda's TellerWithMultiAssetSupport.
 * @dev Uses `address` for asset parameters to avoid importing Solmate's ERC20.
 *      The Teller is the entry/exit point for the BoringVault. All functions use `requiresAuth`,
 *      so callers must be authorized on the Teller's Authority.
 */
interface IVedaTeller {
    /**
     * @notice Allows users to deposit into the BoringVault, if the contract is not paused.
     * @dev Shares are minted to `msg.sender`. A share lock period may apply.
     * @param depositAsset The ERC20 token to deposit
     * @param depositAmount The amount to deposit
     * @param minimumMint The minimum shares the user expects to receive
     * @param referralAddress Address used for referral tracking
     * @return shares The number of vault shares minted
     */
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address referralAddress
    )
        external
        payable
        returns (uint256 shares);

    /**
     * @notice Allows an authorized caller to deposit into the BoringVault for another address, if this contract is not paused.
     * @dev Intended for router-like integrations; this selector should remain role-gated.
     * @param depositAsset The ERC20 token to deposit
     * @param depositAmount The amount to deposit
     * @param minimumMint The minimum shares the user expects to receive
     * @param to The address that will receive the minted vault shares
     * @param referralAddress Address used for referral tracking
     * @return shares The number of vault shares minted
     */
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        address referralAddress
    )
        external
        payable
        returns (uint256 shares);

    /**
     * @notice Allows users to withdraw from the BoringVault.
     * @dev Available on TellerWithYieldStreaming. Burns shares from `msg.sender` and sends
     *      underlying assets to `to`. Updates vested yield before withdrawal.
     * @param withdrawAsset The ERC20 token to receive
     * @param shareAmount The amount of vault shares to burn
     * @param minimumAssets The minimum underlying assets expected
     * @param to The address that will receive the underlying assets
     * @return assetsOut The amount of underlying assets sent
     */
    function withdraw(
        address withdrawAsset,
        uint256 shareAmount,
        uint256 minimumAssets,
        address to
    )
        external
        returns (uint256 assetsOut);
}
