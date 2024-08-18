// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action, Delegation } from "../utils/Types.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";

/**
 * @title NativeTokenPaymentEnforcer
 * @notice This contract enforces payment in native token (e.g., ETH) for the right to use a delegation.
 * @dev The redeemer must include a payment delegation in the arguments when executing an action.
 * The payment, made in native token, is processed during the execution of the delegated action, ensuring that the
 * enforced conditions are met.
 * Combining `NativeTokenTransferAmountEnforcer` and `ArgsEqualityCheckEnforcer` when creating the payment delegation is recommended
 * to prevent front-running attacks.
 */
contract NativeTokenPaymentEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    /// @dev The Delegation Manager contract to redeem the delegation
    IDelegationManager public immutable delegationManager;
    /// @dev The enforcer used to compare args and terms
    address public immutable argsEqualityCheckEnforcer;

    ////////////////////////////// Events //////////////////////////////

    // Event emitted when a payment is validated
    event ValidatedPayment(
        address indexed sender,
        bytes32 indexed delegationHash,
        address indexed recipient,
        address delegator,
        address redeemer,
        uint256 amount
    );

    ////////////////////////////// Constructor //////////////////////////////

    constructor(IDelegationManager _delegationManager, address _argsEqualityCheckEnforcer) {
        delegationManager = _delegationManager;
        argsEqualityCheckEnforcer = _argsEqualityCheckEnforcer;
    }

    ////////////////////////////// External Functions //////////////////////////////

    /**
     * @notice Enforces the conditions that should hold after a transaction is performed.
     * @param _terms Encoded 52 packed bytes where: the first 20 bytes are the address of the recipient,
     * the next 32 bytes are the amount to charge for the delegation.
     * @param _args Encoded arguments containing the delegation chain for the payment.
     * @param _delegationHash The hash of the delegation.
     * @param _delegator The address of the delegator.
     * @param _redeemer The address that is redeeming the delegation.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata _args,
        Action calldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        require(msg.sender == address(delegationManager), "NativeTokenPaymentEnforcer:only-delegation-manager");

        // Decode the payment terms and arguments
        (address recipient_, uint256 amount_) = getTermsInfo(_terms);

        Delegation[] memory delegations_ = abi.decode(_args, (Delegation[]));

        // Assign the delegation hash as the args to the args equality enforcer.
        for (uint256 x = 0; x < delegations_.length; ++x) {
            Delegation memory delegation_ = delegations_[x];
            for (uint256 i = 0; i < delegation_.caveats.length; ++i) {
                if (delegation_.caveats[i].enforcer == argsEqualityCheckEnforcer) {
                    delegation_.caveats[i].args = abi.encodePacked(_delegationHash);
                }
            }
        }

        uint256 balanceBefore_ = recipient_.balance;

        bytes[] memory encodedDelegations_ = new bytes[](1);
        encodedDelegations_[0] = abi.encode(delegations_);

        Action[] memory actions_ = new Action[](1);
        actions_[0] = Action({ to: recipient_, value: amount_, data: hex"" });

        // Attempt to redeem the delegation and make the payment
        delegationManager.redeemDelegation(encodedDelegations_, actions_);

        // Ensure the recipient received the payment
        uint256 balanceAfter_ = recipient_.balance;
        require(balanceAfter_ >= balanceBefore_ + amount_, "NativeTokenPaymentEnforcer:payment-not-received");

        emit ValidatedPayment(msg.sender, _delegationHash, recipient_, _delegator, _redeemer, amount_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded 52 packed bytes where: the first 20 bytes are the address of the recipient,
     * the next 32 bytes are the amount to charge for the delegation.
     * @return recipient_ The recipient that receives the payment.
     * @return amount_ The native token amount that must be paid.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address recipient_, uint256 amount_) {
        require(_terms.length == 52, "NativeTokenPaymentEnforcer:invalid-terms-length");

        recipient_ = address(bytes20(_terms[:20]));
        amount_ = uint256(bytes32(_terms[20:]));
    }
}
