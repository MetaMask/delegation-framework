// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Delegation } from "../utils/Types.sol";
import "forge-std/Test.sol";

/**
 * @title DelegationChainEnforcer
 * @dev This contract enforces the allowed methods a delegate may call.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev Combine with other enforcers to validate the target, method, value, etc, in the root delegation, this avoids
 *  a redundant validation in this enforcer on each level.
 */
contract DelegationChainEnforcer is CaveatEnforcer, Ownable {
    using ExecutionLib for bytes;

    mapping(address delegationManager => mapping(bytes32 referralChainHash => address[] recipients)) public referrals;
    mapping(address delegationManager => mapping(bytes32 referralChainHash => bool redeemed)) public redeemed;

    /// @dev The Delegation Manager contract to redeem the delegation
    IDelegationManager public immutable delegationManager;

    /// @dev The enforcer used to compare args and terms
    address public immutable argsEqualityCheckEnforcer;

    // TODO: make this constant if possible
    uint256[] public prizeAmounts;

    ////////////////////////////// Events //////////////////////////////

    event ReferralChainPosted(address indexed sender, bytes32 indexed referralChainHash);
    event PrizesSet(address indexed sender, uint256[] prizeLevels);
    ////////////////////////////// Constructor //////////////////////////////

    // TODO: make the levels an array or struct limited to length 5
    constructor(
        address _owner,
        IDelegationManager _delegationManager,
        address _argsEqualityCheckEnforcer,
        uint256[] memory _prizeLevels
    )
        Ownable(_owner)
    {
        require(_delegationManager != IDelegationManager(address(0)), "DelegationChainEnforcer:invalid-delegationManager");
        require(_argsEqualityCheckEnforcer != address(0), "DelegationChainEnforcer:invalid-argsEqualityCheckEnforcer");

        delegationManager = _delegationManager;
        argsEqualityCheckEnforcer = _argsEqualityCheckEnforcer;
        _setPrizes(_prizeLevels);
    }

    ////////////////////////////// External Methods //////////////////////////////

    function setPrizes(uint256[] memory _prizeLevels) external onlyOwner {
        _setPrizes(_prizeLevels);
    }

    function post(address[] calldata _delegators) external onlyOwner {
        uint256 delegatorsLength_ = _delegators.length;
        require(delegatorsLength_ > 1, "DelegationChainEnforcer:invalid-delegators-length");

        // TODO: make sure someonen can't add himself twice in the same delegation chain
        // TODO: make sure the intermediary chain is involved otherwise fail, pleople would add themselves to the chain at the end
        // multiple times to get paid multiple times, or an address they control?

        bytes32 referralChainHash_ = keccak256(abi.encode(_delegators));

        // TODO: centralization risk what can someone with a delegation do, we need to trust
        address[] storage referrals_ = referrals[address(delegationManager)][referralChainHash_];
        require(referrals_.length == 0, "DelegationChainEnforcer:referral-chain-already-posted");

        // Push up to the last 5 delegators in reverse order
        uint256 startIndex_ = delegatorsLength_ < 5 ? 0 : delegatorsLength_ - 5;
        for (uint256 i = delegatorsLength_; i > startIndex_; i--) {
            referrals_.push(_delegators[i - 1]);
        }

        emit ReferralChainPosted(msg.sender, referralChainHash_);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    // The beforeHook validates that the delegation being redeemed correctly matches the delegation chain order (checking the
    // delegator address, and the delegate address if present in the terms).

    // Upon successful validation of the entire delegation chain, the transaction executes the attestation call on the
    // DelegationChainEnforcer contract. This call formally posts the entire delegation chain addresses on-chain, creating a
    // permanent record of the referral event.
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address
    )
        public
        pure
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _validatePosition(_executionCallData, _terms, _delegator);
    }

    function _validatePosition(bytes calldata _executionCallData, bytes calldata _terms, address _delegator) internal pure {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        // Target, value, method, must be validated by other enforcers, on root the delegation.
        (address[] memory delegators_) = abi.decode(callData_[4:], (address[]));

        // Restriction for gas costs.
        require(delegators_.length <= 20, "DelegationChainEnforcer:invalid-delegators-length");

        uint256 expectedPosition_ = getTermsInfo(_terms);

        require(delegators_.length > expectedPosition_, "DelegationChainEnforcer:invalid-expected-position");

        require(delegators_[expectedPosition_] == _delegator, "DelegationChainEnforcer:invalid-delegator-or-position");
    }

    // This only runs the entire function if the delegation chain has not been redeemed yet.
    // The redeemer fills the args on the root delegation, and it will only run for that delegation.
    function afterHook(
        bytes calldata,
        bytes calldata _args,
        ModeCode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        console2.log("Checkpoint after hook");
        console2.log("_delegator:", _delegator);
        console2.log("_redeemer:", _redeemer);

        bytes32 referralChainHash_ = _getReferralChainHash(_executionCallData);
        // Stops afterHook execution if the referral hash has already been redeemed
        // TODO: add a test to check this mapping
        if (redeemed[msg.sender][referralChainHash_]) return;

        address[] memory referrals_ = referrals[msg.sender][referralChainHash_];

        // (address[] memory referrals_, uint256 referralLength_) = _getReferralsAndValidateRedemption(referralChainHash_);
        // require(referralLength_ > 2, "DelegationChainEnforcer:invalid-referrals-length");

        // TODO: make the token constant if possible
        (Delegation[][] memory allowanceDelegations_, uint256 allowanceLength_, address token_) =
            _validateAndDecodeArgs(_args, _delegationHash, _redeemer);

        bytes[] memory permissionContexts_ = new bytes[](allowanceLength_);
        bytes[] memory executionCallDatas_ = new bytes[](allowanceLength_);
        ModeCode[] memory encodedModes_ = new ModeCode[](allowanceLength_);

        console2.log("allowanceDelegations_.length:", allowanceDelegations_.length);
        // console2.log("referralLength_:", referralLength_);

        require(referrals_.length == allowanceDelegations_.length, "DelegationChainEnforcer:invalid-delegations-length");

        for (uint256 i = 0; i < allowanceLength_; ++i) {
            permissionContexts_[i] = abi.encode(allowanceDelegations_[i]);
            executionCallDatas_[i] =
                ExecutionLib.encodeSingle(token_, 0, abi.encodeCall(IERC20.transfer, (referrals_[i], prizeAmounts[i])));
            encodedModes_[i] = ModeLib.encodeSimpleSingle();
            console2.log("prizeAmounts[i]:", prizeAmounts[i]);
        }

        uint256[] memory balanceBefore_ = _getBalances(referrals_, token_);

        console2.log("ABOUT TO REDEEM INSIDE AFTERHOOK");
        // Attempt to redeem the delegation and make the payment
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
        console2.log("AFTER REDEMPTION INSIDE AFTERHOOK");

        //TODO: If this fails, for memory, then try to pass the redeemDelegations() as callback below.
        _validateTransfer(referrals_, token_, balanceBefore_);

        redeemed[msg.sender][referralChainHash_] = true;
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return expectedPosition_ The position of the expected delegator in the delegation chain.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 expectedPosition_) {
        require(_terms.length == 32, "DelegationChainEnforcer:invalid-terms-length");
        expectedPosition_ = uint256(bytes32(_terms[:32]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _setPrizes(uint256[] memory _prizeLevels) internal {
        uint256 prizeLevelsLength_ = _prizeLevels.length;
        require(prizeLevelsLength_ == 5, "DelegationChainEnforcer:invalid-prize-levels-length");

        // Clear existing prize amounts
        delete prizeAmounts;

        for (uint256 i = 0; i < prizeLevelsLength_; ++i) {
            require(_prizeLevels[i] > 0, "DelegationChainEnforcer:invalid-prize-level");
            prizeAmounts.push(_prizeLevels[i]);
        }

        emit PrizesSet(msg.sender, _prizeLevels);
    }

    function _getBalances(address[] memory _recipients, address _token) internal view returns (uint256[] memory balances_) {
        uint256 recipientsLength_ = _recipients.length;
        balances_ = new uint256[](recipientsLength_);
        for (uint256 i = 0; i < recipientsLength_; ++i) {
            balances_[i] = IERC20(_token).balanceOf(_recipients[i]);
        }
    }

    function _validateTransfer(address[] memory _recipients, address _token, uint256[] memory balanceBefore_) internal view {
        // TODO: prizeAmounts read twice from storage
        uint256[] memory balances_ = _getBalances(_recipients, _token);
        for (uint256 i = 0; i < _recipients.length; ++i) {
            require(balances_[i] >= balanceBefore_[i] + prizeAmounts[i], "DelegationChainEnforcer:payment-not-received");
        }
    }

    function _getReferrals(bytes32 _referralChainHash)
        internal
        view
        returns (address[] memory referrals_, uint256 referralLength_)
    {
        referrals_ = referrals[msg.sender][_referralChainHash];
        referralLength_ = referrals_.length;
        console2.log("msg.sender:", msg.sender);
        console2.log("referralLength_:", referralLength_);
    }

    function _getReferralChainHash(bytes calldata _executionCallData) internal pure returns (bytes32 referralChainHash_) {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();
        (address[] memory delegators_) = abi.decode(callData_[4:], (address[]));
        referralChainHash_ = keccak256(abi.encode(delegators_));
    }

    function _validateAndDecodeArgs(
        bytes calldata _args,
        bytes32 _delegationHash,
        address _redeemer
    )
        internal
        view
        returns (Delegation[][] memory allowanceDelegations_, uint256 allowanceLength_, address token_)
    {
        // TODO: make the token constant if possible
        // TODO: we could assume a single direct delegation with the total amount, instead of an array of delegations
        (allowanceDelegations_, token_) = abi.decode(_args, (Delegation[][], address));
        allowanceLength_ = allowanceDelegations_.length;
        require(allowanceLength_ > 0, "DelegationChainEnforcer:invalid-allowance-delegations-length");

        for (uint256 i = 0; i < allowanceLength_; ++i) {
            require(
                allowanceDelegations_[i][0].caveats.length > 0
                    && allowanceDelegations_[i][0].caveats[0].enforcer == argsEqualityCheckEnforcer,
                "DelegationChainEnforcer:missing-argsEqualityCheckEnforcer"
            );
            // The Args Enforcer with this data (hash & redeemer) must be the first Enforcer in the payment delegations caveats
            allowanceDelegations_[i][0].caveats[0].args = abi.encodePacked(_delegationHash, _redeemer);
        }
    }
}
