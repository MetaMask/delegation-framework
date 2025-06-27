// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/// @title Interface for a liquid staking aggregation contract
/// @author Jack Clancy - Consensys
interface ILiquidStakingAggregator {
    /// @notice Deposit ETH to Lido and receive stETH
    /// @param maxFeeRate Maximum fee rate to accept (in basis points * 10)
    function depositToLido(uint256 maxFeeRate) external payable;

    /// @notice Deposit ETH to Rocket Pool and receive rETH
    /// @param maxFeeRate Maximum fee rate to accept (in basis points * 10)
    function depositToRP(uint256 maxFeeRate) external payable;

    /// @notice Deposits MATIC to Lido and forwards minted stMatic to caller
    /// @param amount Amount of MATIC to deposit
    /// @param maxFeeRate Maximum fee rate the caller is willing to accept
    function depositToStMatic(uint256 amount, uint256 maxFeeRate) external;

    /// @notice Deposits MATIC to Stader and forwards minted MaticX to caller
    /// @param amount Amount of MATIC to deposit
    /// @param maxFeeRate Maximum fee rate the caller is willing to accept
    function depositToMaticx(uint256 amount, uint256 maxFeeRate) external;

    /// @notice Updates the fee for staking transactions
    /// @dev Fee is in 0.1bp increments. i.e. fee = 10 is setting to 1bp
    /// @param _newFee The new fee for future transactions
    function updateFee(uint256 _newFee) external;

    /// @notice Updates the recipient of the fees collected by the contract
    /// @param _newFeesRecipent The recipient of future fees
    function updateFeesRecipient(address payable _newFeesRecipent) external;

    /// @notice Returns several RocketPool constants that the FE needs
    /// @dev Deposit fee in wei. Number needs to be divided by 1e18 to get in percentage
    /// @return Array containing [currentDeposits, depositFee, depositPoolCap, exchangeRate]
    function fetchRPConstants() external view returns (uint256[4] memory);

    /// @notice Gets the current fee rate
    /// @return Current fee in 1/10th of bps
    function fee() external view returns (uint256);

    /// @notice Gets the current fees recipient
    /// @return Address of the current fees recipient
    function feesRecipient() external view returns (address payable);
}
