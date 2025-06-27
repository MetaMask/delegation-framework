// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/// @title Interface for Lido's withdrawal queue contract
/// @notice Interface for requesting and claiming stETH withdrawals
interface IWithdrawalQueue {
    /// @notice Output format struct for withdrawal status
    struct WithdrawalRequestStatus {
        /// @notice stETH token amount that was locked on withdrawal queue for this request
        uint256 amountOfStETH;
        /// @notice amount of stETH shares locked on withdrawal queue for this request
        uint256 amountOfShares;
        /// @notice address that can claim or transfer this request
        address owner;
        /// @notice timestamp of when the request was created, in seconds
        uint256 timestamp;
        /// @notice true, if request is finalized
        bool isFinalized;
        /// @notice true, if request is claimed. Request is claimable if (isFinalized && !isClaimed)
        bool isClaimed;
    }

    /// @notice Permit input structure for gasless approvals
    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Request withdrawals with permit signature
    /// @param _amounts Array of stETH amounts to withdraw
    /// @param _owner Address that will own the withdrawal requests
    /// @param _permit Permit signature data
    /// @return requestIds Array of withdrawal request IDs
    function requestWithdrawalsWithPermit(
        uint256[] calldata _amounts,
        address _owner,
        PermitInput calldata _permit
    )
        external
        returns (uint256[] memory requestIds);

    /// @notice Request withdrawals (requires prior approval)
    /// @param _amounts Array of stETH amounts to withdraw
    /// @param _owner Address that will own the withdrawal requests
    /// @return requestIds Array of withdrawal request IDs
    function requestWithdrawals(uint256[] calldata _amounts, address _owner) external returns (uint256[] memory requestIds);

    /// @notice Get withdrawal requests for an owner
    /// @param _owner Address to get requests for
    /// @return requestsIds Array of request IDs
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestsIds);

    /// @notice Returns status for requests with provided ids
    /// @param _requestIds Array of withdrawal request ids
    /// @return statuses Array of withdrawal request statuses
    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    /// @notice Claim withdrawal requests
    /// @param _requestIds Array of request IDs to claim
    /// @param _hints Array of hints for efficient claiming
    function claimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external;
}
