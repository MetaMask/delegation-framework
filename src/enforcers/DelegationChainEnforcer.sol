// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Delegation } from "../utils/Types.sol";

/**
 * @title DelegationChainEnforcer
 * @notice Enforces referral-chain payments using ERC20 allowance delegations. After redemption,
 *         the contract receives ERC20 allowance delegations, redeems them, and distributes prizes.
 *         To set up a chain, call `post` with an array of up to MAX_REFERRAL_DEPTH referral addresses.
 *         The last addresses according to the maxPrizePayments will be paid their configured prize levels.
 *         A hash of the addresses prevents replays.
 *         Combine with a RedeemerEnforcer so that the Intermediary Chain Account (ICA) can
 *         validate any off-chain requirements (e.g., KYC, step-completions) before permitting
 *         redemption. The ICA acts at each level as an intermediary, enabling delegations to
 *         unknown addresses with proper enforcers and terms to prevent errors.
 *
 * @dev This enforcer works in a single execution call with default execution mode. It relies
 *      on other enforcers to validate root delegation parameters, e.g the target, method, value, etc,
 *      avoiding redundant checks on each chain level. Prize amounts are fixed to exactly maxPrizePayments levels and
 *      must be set via the owner. Cannot post the same chain twice or redeem more than once per chain hash.
 */
contract DelegationChainEnforcer is CaveatEnforcer, Ownable2Step {
    using ExecutionLib for bytes;

    /// @dev Maximum number of referrers in the referral chain
    uint256 public constant MAX_REFERRAL_DEPTH = 20;

    /// @dev Maximum number of prizes that will be paid in the referral chain
    uint256 public immutable maxPrizePayments;

    /// @dev The Delegation Manager contract to redeem the delegation
    IDelegationManager public immutable delegationManager;

    /// @dev Enforcer to compare args and terms in allowance caveats
    address public immutable argsEqualityCheckEnforcer;

    /// @dev The token address to be used for the prize payments
    address public immutable prizeToken;

    /// @dev Maps delegation manager addresses to referral array hashes to recipient addresses
    mapping(address delegationManager => mapping(bytes32 referralChainHash => address[] recipients)) private referrals;

    /// @dev Maps delegation manager addresses to referral array hashes to redemption status
    mapping(address delegationManager => mapping(bytes32 referralChainHash => bool redeemed)) private redeemed;

    /// @dev Array of prize amounts for each position in the referral array
    uint256[] private prizeAmounts;

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

    /**
     * @dev Emitted when a payment is completed
     * @param sender The address of the delegation manager on which the payment was completed
     * @param referralChainHash The hash of the referral array
     */
    event PaymentCompleted(address indexed sender, bytes32 indexed referralChainHash);

    /**
     * @dev Emitted when a payment has been already made for a referral chain
     * @param sender The address of the delegation manager on which the payment was made
     * @param referralChainHash The hash of the referral array
     */
    event ReferralChainAlreadyPaid(address indexed sender, bytes32 indexed referralChainHash);

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @dev Initializes the contract with the owner, delegation manager, args equality check enforcer, and prize levels
     * @param _owner The address that will be the owner of the contract
     * @param _delegationManager The address of the delegation manager contract
     * @param _argsEqualityCheckEnforcer The address of the args equality check enforcer
     * @param _prizeToken The address of the token to be used for the prize payments
     * @param _prizeAmounts Array of prize amounts for each position in the referral array, from the first to the last position
     *        The maxPrizePayments is set to the length of this prizeAmounts array and it cannot be changed.
     */
    constructor(
        address _owner,
        IDelegationManager _delegationManager,
        address _argsEqualityCheckEnforcer,
        address _prizeToken,
        uint256[] memory _prizeAmounts
    )
        Ownable(_owner)
    {
        require(_delegationManager != IDelegationManager(address(0)), "DelegationChainEnforcer:invalid-delegationManager");
        require(_argsEqualityCheckEnforcer != address(0), "DelegationChainEnforcer:invalid-argsEqualityCheckEnforcer");
        require(_prizeToken != address(0), "DelegationChainEnforcer:invalid-prizeToken");

        delegationManager = _delegationManager;
        argsEqualityCheckEnforcer = _argsEqualityCheckEnforcer;
        prizeToken = _prizeToken;
        maxPrizePayments = _prizeAmounts.length;
        require(maxPrizePayments > 1, "DelegationChainEnforcer:invalid-max-prize-payments");
        _setPrizes(_prizeAmounts);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Update prize amounts for the last maxPrizePayments referrers
     * @dev Owner-only. Accepts exactly maxPrizePayments non-zero values.
     * @param _prizeAmounts Array of maxPrizePayments prize amounts, from the first to the last position
     */
    function setPrizes(uint256[] memory _prizeAmounts) external onlyOwner {
        _setPrizes(_prizeAmounts);
    }

    /**
     * @notice Register a referral array for later prize redemption
     * @dev Owner-only. Stores only the last maxPrizePayments amount of addresses that will be paid their
     *      configured prize levels in the afterHook.
     * @dev Computes a unique hash to prevent replay or duplicate registration.
     * @param _delegators Full referral array addresses (length 2–MAX_REFERRAL_DEPTH), from root to leaf
     */
    function post(address[] calldata _delegators) external onlyOwner {
        uint256 delegatorsLength_ = _delegators.length;
        require(
            delegatorsLength_ > 1 && delegatorsLength_ <= MAX_REFERRAL_DEPTH, "DelegationChainEnforcer:invalid-delegators-length"
        );

        bytes32 referralChainHash_ = keccak256(abi.encode(_delegators));

        address[] storage referrals_ = referrals[address(delegationManager)][referralChainHash_];
        require(referrals_.length == 0, "DelegationChainEnforcer:referral-chain-already-posted");

        // Push up to the last delegators according to the amount of prizes.
        uint256 startIndex_ = delegatorsLength_ > maxPrizePayments ? delegatorsLength_ - maxPrizePayments : 0;
        for (uint256 i = startIndex_; i < delegatorsLength_; ++i) {
            referrals_.push(_delegators[i]);
        }

        emit ReferralArrayPosted(msg.sender, referralChainHash_);
    }

    /**
     * @notice Get the referrals for a given referral chain hash
     * @param _delegationManager The address of the delegation manager
     * @param _referralChainHash The hash of the referral chain
     * @return referrals_ The array of referrals
     */
    function getReferrals(
        address _delegationManager,
        bytes32 _referralChainHash
    )
        external
        view
        returns (address[] memory referrals_)
    {
        return referrals[_delegationManager][_referralChainHash];
    }

    /**
     * @notice Get all the prize amounts for the referrers
     * @return prizeAmounts_ The array of prize amounts
     */
    function getPrizeAmounts() external view returns (uint256[] memory) {
        return prizeAmounts;
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
     * @dev Executes after the delegation is redeemed, distributing prizes to participants
     * @dev This hook executes the payment to the recipients only once for the same referral array hash, after the
     *      first run it is skipped.
     * @dev Decodes allowance delegations, checks caveat enforcer, builds transfer calls, redeems via
     *      delegationManager, verifies balances, then marks redeemed.
     * @param _args ABI-encoded (Delegation[][] allowanceDelegations)
     * @param _executionCallData Calldata containing encoded referral array
     * @param _delegationHash The hash of the delegation
     * @param _redeemer The address of the redeemer
     */
    function afterHook(
        bytes calldata,
        bytes calldata _args,
        ModeCode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
    {
        bytes32 referralChainHash_ = _getReferralChainHash(_executionCallData);

        // Stops afterHook execution if the referral hash has already been paid
        if (redeemed[msg.sender][referralChainHash_]) {
            emit ReferralChainAlreadyPaid(msg.sender, referralChainHash_);
            return;
        }
        redeemed[msg.sender][referralChainHash_] = true;

        address[] memory referrals_ = referrals[msg.sender][referralChainHash_];

        (Delegation[][] memory allowanceDelegations_, uint256 allowanceLength_) =
            _validateAndDecodeArgs(_args, _delegationHash, _redeemer);

        require(referrals_.length == allowanceLength_, "DelegationChainEnforcer:invalid-delegations-length");

        bytes[] memory permissionContexts_ = new bytes[](allowanceLength_);
        bytes[] memory executionCallDatas_ = new bytes[](allowanceLength_);
        ModeCode[] memory encodedModes_ = new ModeCode[](allowanceLength_);
        uint256[] memory balancesBefore_ = new uint256[](allowanceLength_);

        address token_ = prizeToken;
        for (uint256 i = 0; i < allowanceLength_;) {
            balancesBefore_[i] = IERC20(token_).balanceOf(referrals_[i]);
            permissionContexts_[i] = abi.encode(allowanceDelegations_[i]);
            executionCallDatas_[i] =
                ExecutionLib.encodeSingle(token_, 0, abi.encodeCall(IERC20.transfer, (referrals_[i], prizeAmounts[i])));
            encodedModes_[i] = ModeLib.encodeSimpleSingle();
            unchecked {
                ++i;
            }
        }

        // Attempt to redeem the delegation and make the payment
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        _validateTransfer(referrals_, IERC20(token_), balancesBefore_);

        emit PaymentCompleted(msg.sender, referralChainHash_);
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
     * @param _prizeAmounts Array of maxPrizePayments prize amounts, sorted from the first to the last position
     */
    function _setPrizes(uint256[] memory _prizeAmounts) internal {
        uint256 prizeAmountsLength_ = _prizeAmounts.length;
        require(prizeAmountsLength_ == maxPrizePayments, "DelegationChainEnforcer:invalid-prize-amounts-length");

        // Clear existing prize amounts
        delete prizeAmounts;

        for (uint256 i = 0; i < prizeAmountsLength_; ++i) {
            require(_prizeAmounts[i] > 0, "DelegationChainEnforcer:invalid-prize-amount");
            prizeAmounts.push(_prizeAmounts[i]);
        }

        emit PrizesSet(msg.sender, _prizeAmounts);
    }

    /**
     * @dev Validates that transfers were successful by checking recipient balances
     * @param _recipients Array of recipient addresses
     * @param _token The token address
     * @param balanceBefore_ Array of balances before the transfer
     */
    function _validateTransfer(address[] memory _recipients, IERC20 _token, uint256[] memory balanceBefore_) internal view {
        uint256[] memory prizes_ = prizeAmounts;
        uint256 recipientsLength_ = _recipients.length;
        for (uint256 i = 0; i < recipientsLength_; ++i) {
            uint256 newBalance_ = _token.balanceOf(_recipients[i]);
            require(newBalance_ >= balanceBefore_[i] + prizes_[i], "DelegationChainEnforcer:payment-not-received");
        }
    }

    /**
     * @dev Validates and decodes the arguments for the delegation
     * @param _args Encoded allowance delegations and token address
     * @param _delegationHash The hash of the delegation
     * @param _redeemer The address of the redeemer
     * @return allowanceDelegations_ Array of allowance delegations
     * @return allowanceLength_ The length of the allowance delegations
     */
    function _validateAndDecodeArgs(
        bytes calldata _args,
        bytes32 _delegationHash,
        address _redeemer
    )
        internal
        view
        returns (Delegation[][] memory allowanceDelegations_, uint256 allowanceLength_)
    {
        (allowanceDelegations_) = abi.decode(_args, (Delegation[][]));
        allowanceLength_ = allowanceDelegations_.length;
        require(allowanceLength_ > 0, "DelegationChainEnforcer:invalid-allowance-delegations-length");
        bytes memory packedArgs = abi.encodePacked(_delegationHash, _redeemer);
        for (uint256 i = 0; i < allowanceLength_; ++i) {
            require(
                allowanceDelegations_[i][0].caveats.length > 0
                    && allowanceDelegations_[i][0].caveats[0].enforcer == argsEqualityCheckEnforcer,
                "DelegationChainEnforcer:missing-argsEqualityCheckEnforcer"
            );
            // The Args Enforcer with this data (hash & redeemer) must be the first Enforcer in the payment delegations caveats
            allowanceDelegations_[i][0].caveats[0].args = packedArgs;
        }
    }

    /**
     * @dev Gets the referral array hash from execution call data
     * @param _executionCallData Calldata containing encoded referral array
     * @return referralChainHash_ The hash of the referral array
     */
    function _getReferralChainHash(bytes calldata _executionCallData) internal pure returns (bytes32 referralChainHash_) {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();
        // Passing the addresses of the post() function. It is already the exact ABI encoding of the address[]
        referralChainHash_ = keccak256(callData_[4:]);
    }

    /**
     * @dev Validates the position of a delegator in the referral array during the beforeHook
     * @param _executionCallData Calldata containing encoded referral array
     * @param _terms 32 bytes encoded with the delegator's expected position in the referral array
     * @param _delegator The address of the delegator
     */
    function _validatePosition(bytes calldata _executionCallData, bytes calldata _terms, address _delegator) internal pure {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        // Target, value, method, must be validated by other enforcers, on root the delegation.
        (address[] memory delegators_) = abi.decode(callData_[4:], (address[]));

        // Restriction for gas costs.
        require(delegators_.length <= MAX_REFERRAL_DEPTH, "DelegationChainEnforcer:invalid-delegators-length");

        uint256 expectedPosition_ = getTermsInfo(_terms);

        require(delegators_.length > expectedPosition_, "DelegationChainEnforcer:invalid-expected-position");

        require(delegators_[expectedPosition_] == _delegator, "DelegationChainEnforcer:invalid-delegator-or-position");
    }
}
