// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IComplianceVedaTeller
 * @notice Interface for compliance-gated Veda tellers using the Base V0.3 deposit API.
 * @dev Asset fields use address instead of Solmate's ERC20 type because both have the same ABI encoding.
 */
interface IComplianceVedaTeller {
    struct DepositParams {
        address depositAsset;
        uint256 depositAmount;
        uint256 minimumMint;
    }

    struct ComplianceData {
        uint256 deadline;
        bytes signature;
    }

    /**
     * @notice Deposits an asset and mints vault shares to `to`.
     * @dev The compliance signature is bound to this teller, chain ID, caller, recipient, asset, amount, and deadline.
     */
    function deposit(
        DepositParams calldata params,
        address to,
        address referralAddress,
        ComplianceData calldata compliance
    )
        external
        payable
        returns (uint256 shares);

    /**
     * @notice Burns shares from the caller and sends the selected asset to `to`.
     * @dev Available on TellerWithYieldStreaming.
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
