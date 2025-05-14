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
 * @notice Enforces referral-chain payments using ERC20 allowance delegations. After redemption,
 *         the contract receives ERC20 allowance delegations, redeems them, and distributes prizes.
 *         To set up a chain, call `post` with an array of up to 20 referral addresses. The last 5
 *         in the array will be paid according to configured prize levels. A hash prevents replays.
 *         Combine with a RedeemerEnforcer so that the Intermediary Chain Account (ICA) can
 *         validate any off-chain requirements (e.g., KYC, step-completions) before permitting
 *         redemption. The ICA acts at each level as an intermediary, enabling delegations to
 *         unknown addresses with proper enforcers and terms to prevent errors.
 *
 * @dev This enforcer works in a single execution call with default execution mode. It relies
 *      on other enforcers to validate root delegation parameters, e.g the target, method, value, etc,
 *      avoiding redundant checks on each chain level. Prize amounts are fixed to exactly 5 levels and
 *      must be set via the owner. Cannot post the same chain twice or redeem more than once per chain hash.
 */
contract DelegationChainEnforcer is CaveatEnforcer, Ownable {
    using ExecutionLib for bytes;

    /// @dev Maps delegation manager addresses to referral array hashes to recipient addresses
    mapping(address delegationManager => mapping(bytes32 referralChainHash => address[] recipients)) public referrals;

    /// @dev Maps delegation manager addresses to referral array hashes to redemption status
    mapping(address delegationManager => mapping(bytes32 referralChainHash => bool redeemed)) public redeemed;

    /// @dev The Delegation Manager contract to redeem the delegation
    IDelegationManager public immutable delegationManager;

    /// @dev Enforcer to compare args and terms in allowance caveats
    address public immutable argsEqualityCheckEnforcer;

    // TODO: make this constant if possible
    /// @dev Array of prize amounts for each position in the referral array
    uint256[] public prizeAmounts;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @dev Emitted when a new referral array is posted
     * @param sender The address that posted the referral array
     * @param referralChainHash The hash of the referral array
     */
    event ReferralArrayPosted(address indexed sender, bytes32 indexed referralChainHash);

    /**
     * @dev Emitted when prize amounts are set
     * @param sender The address that set the prizes
     * @param prizeLevels The array of prize amounts
     */
    event PrizesSet(address indexed sender, uint256[] prizeLevels);

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @dev Initializes the contract with the owner, delegation manager, args equality check enforcer, and prize levels
     * @param _owner The address that will be the owner of the contract
     * @param _delegationManager The address of the delegation manager contract
     * @param _argsEqualityCheckEnforcer The address of the args equality check enforcer
     * @param _prizeLevels Array of prize amounts for each position in the referral array
     */
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
        // TODO: make the levels an array or struct limited to length 5
        _setPrizes(_prizeLevels);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Update prize amounts for the last 5 referrers
     * @dev Owner-only. Accepts exactly 5 non-zero values.
     * @param _prizeLevels Array of 5 prize amounts, for positions 0 through 4
     */
    function setPrizes(uint256[] memory _prizeLevels) external onlyOwner {
        _setPrizes(_prizeLevels);
    }

    /**
     * @notice Register a referral array for later prize redemption
     * @dev Owner-only. Accepts 2 to 20 addresses. Stores only the last 5 (in reverse order).
     *      Computes a unique hash to prevent replay or duplicate registration.
     * @param _delegators Full referral array addresses (length 2–20), from root to leaf
     */
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

        emit ReferralArrayPosted(msg.sender, referralChainHash_);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @dev Validates that the delegation being redeemed correctly matches the delegation chain order
     * @param _terms 32 bytes encoded with the delegator's expected position in the referral array
     * @param _mode The mode of execution (single call type and default execution mode)
     * @param _executionCallData Calldata containing encoded referral array
     * @param _delegator The address of the delegator
     */
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

    /**
     * @dev Validates the position of a delegator in the referral array
     * @param _executionCallData Calldata containing encoded referral array
     * @param _terms 32 bytes encoded with the delegator's expected position in the referral array
     * @param _delegator The address of the delegator
     */
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

    /**
     * @dev Executes after the delegation is redeemed, distributing prizes to participants
     * @dev This hook executes the payment to the recipients only once for the same referral array hash, after the
     *      first run it is skipped.
     * @dev Decodes allowance delegations, checks caveat enforcer, builds transfer calls, redeems via
     *      delegationManager, verifies balances, then marks redeemed.
     * @param _args ABI-encoded (Delegation[][] allowanceDelegations, address token)
     * @param _executionCallData Calldata containing encoded referral array
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address of the redeemer
     */
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
     * @dev Decodes the terms used in this CaveatEnforcer
     * @param _terms 32 bytes encoded with the delegator's expected position in the referral array
     * @return expectedPosition_ The position of the expected delegator in the delegation chain
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 expectedPosition_) {
        require(_terms.length == 32, "DelegationChainEnforcer:invalid-terms-length");
        expectedPosition_ = uint256(bytes32(_terms[:32]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @dev Sets the prize amounts for each position in the referral array
     * @param _prizeLevels Array of prize amounts for each position in the referral array
     */
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

    /**
     * @dev Gets the balances of recipients for a specific token
     * @param _recipients Array of recipient addresses
     * @param _token The token address
     * @return balances_ Array of balances for each recipient
     */
    function _getBalances(address[] memory _recipients, address _token) internal view returns (uint256[] memory balances_) {
        uint256 recipientsLength_ = _recipients.length;
        balances_ = new uint256[](recipientsLength_);
        for (uint256 i = 0; i < recipientsLength_; ++i) {
            balances_[i] = IERC20(_token).balanceOf(_recipients[i]);
        }
    }

    /**
     * @dev Validates that transfers were successful by checking recipient balances
     * @param _recipients Array of recipient addresses
     * @param _token The token address
     * @param balanceBefore_ Array of balances before the transfer
     */
    function _validateTransfer(address[] memory _recipients, address _token, uint256[] memory balanceBefore_) internal view {
        // TODO: prizeAmounts read twice from storage
        uint256[] memory balances_ = _getBalances(_recipients, _token);
        for (uint256 i = 0; i < _recipients.length; ++i) {
            require(balances_[i] >= balanceBefore_[i] + prizeAmounts[i], "DelegationChainEnforcer:payment-not-received");
        }
    }

    /**
     * @dev Gets the referrals and length for a specific referral array hash
     * @param _referralChainHash The hash of the referral array
     * @return referrals_ Array of referral addresses
     * @return referralLength_ The length of the referral array
     */
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

    /**
     * @dev Gets the referral array hash from execution call data
     * @param _executionCallData Calldata containing encoded referral array
     * @return referralChainHash_ The hash of the referral array
     */
    function _getReferralChainHash(bytes calldata _executionCallData) internal pure returns (bytes32 referralChainHash_) {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();
        (address[] memory delegators_) = abi.decode(callData_[4:], (address[]));
        referralChainHash_ = keccak256(abi.encode(delegators_));
    }

    /**
     * @dev Validates and decodes the arguments for the delegation
     * @param _args Encoded allowance delegations and token address
     * @param _delegationHash The hash of the delegation
     * @param _redeemer The address of the redeemer
     * @return allowanceDelegations_ Array of allowance delegations
     * @return allowanceLength_ The length of the allowance delegations
     * @return token_ The token address
     */
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
