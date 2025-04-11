// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import { IMetaSwap } from "./interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { CallType, ExecType, Delegation, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../utils/Constants.sol";

/**
 * @title DelegationMetaSwapAdapter
 * @notice Acts as a middleman to orchestrate token swaps using delegations and an aggregator (MetaSwap).
 * @dev This contract depends on an ArgsEqualityCheckEnforcer. The root delegation must include a caveat
 *      with this enforcer as its first element. Its arguments indicate whether the swap should enforce the token
 *      whitelist ("Token-Whitelist-Enforced") or not ("Token-Whitelist-Not-Enforced"). The root delegator is
 *      responsible for including this enforcer to signal the desired behavior.
 *
 * @dev This adapter is intended to be used with the Swaps API. Accordingly, all API requests must include a valid
 *      signature that incorporates an expiration timestamp. The signature is verified during swap execution to ensure
 *      that it is still valid.
 */
contract DelegationMetaSwapAdapter is ExecutionHelper, Ownable2Step {
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;
    using SafeERC20 for IERC20;

    struct SignatureData {
        bytes apiData;
        uint256 expiration;
        bytes signature;
    }

    ////////////////////////////// State //////////////////////////////

    /// @dev Constant value used to enforce the token whitelist
    string public constant WHITELIST_ENFORCED = "Token-Whitelist-Enforced";

    /// @dev Constant value used to avoid enforcing the token whitelist
    string public constant WHITELIST_NOT_ENFORCED = "Token-Whitelist-Not-Enforced";

    /// @dev The DelegationManager contract that has root access to this contract
    IDelegationManager public immutable delegationManager;

    /// @dev The MetaSwap contract used to swap tokens
    IMetaSwap public immutable metaSwap;

    /// @dev The enforcer used to compare args and terms
    address public immutable argsEqualityCheckEnforcer;

    /// @dev Address of the API signer account.
    address public swapApiSigner;

    /// @dev Indicates if a token is allowed to be used in the swaps
    mapping(IERC20 token => bool allowed) public isTokenAllowed;

    /// @dev A mapping indicating if an aggregator ID hash is allowed.
    mapping(bytes32 aggregatorIdHash => bool allowed) public isAggregatorAllowed;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the DelegationManager contract address is set.
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    /// @dev Emitted when the MetaSwap contract address is set.
    event SetMetaSwap(IMetaSwap indexed newMetaSwap);

    /// @dev Emitted when the Args Equality Check Enforcer contract address is set.
    event SetArgsEqualityCheckEnforcer(address indexed newArgsEqualityCheckEnforcer);

    /// @dev Emitted when the contract sends tokens (or native tokens) to a recipient.
    event SentTokens(IERC20 indexed token, address indexed recipient, uint256 amount);

    /// @dev Emitted when the allowed token status changes for a token.
    event ChangedTokenStatus(IERC20 token, bool status);

    /// @dev Emitted when the allowed aggregator ID status changes.
    event ChangedAggregatorIdStatus(bytes32 indexed aggregatorIdHash, string aggregatorId, bool status);

    /// @dev Emitted when the Signer API is updated.
    event SwapApiSignerUpdated(address indexed newSigner);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when the caller is not the delegation manager
    error NotDelegationManager();

    /// @dev Error thrown when the call is not made by this contract itself.
    error NotSelf();

    /// @dev Error thrown when msg.sender is not the leaf delegator.
    error NotLeafDelegator();

    /// @dev Error thrown when an execution with an unsupported CallType is made.
    error UnsupportedCallType(CallType callType);

    /// @dev Error thrown when an execution with an unsupported ExecType is made.
    error UnsupportedExecType(ExecType execType);

    /// @dev Error thrown when the input and output tokens are the same.
    error InvalidIdenticalTokens();

    /// @dev Error thrown when delegations input is an empty array.
    error InvalidEmptyDelegations();

    /// @dev Error while transferring the native token to the recipient.
    error FailedNativeTokenTransfer(address recipient);

    /// @dev Error when the tokenFrom is not in the allow list.
    error TokenFromIsNotAllowed(IERC20 token);

    /// @dev Error when the tokenTo is not in the allow list.
    error TokenToIsNotAllowed(IERC20 token);

    /// @dev Error when the aggregator ID is not in the allow list.
    error AggregatorIdIsNotAllowed(string aggregatorId);

    /// @dev Error when the input arrays of a function have different lengths.
    error InputLengthsMismatch();

    /// @dev Error when the contract did not receive enough tokens to perform the swap.
    error InsufficientTokens();

    /// @dev Error when the api data comes with an invalid swap function selector.
    error InvalidSwapFunctionSelector();

    /// @dev Error when the tokenFrom in the api data and swap data do not match.
    error TokenFromMismath();

    /// @dev Error when the amountFrom in the api data and swap data do not match.
    error AmountFromMismath();

    /// @dev Error when the delegations do not include the ArgsEqualityCheckEnforcer
    error MissingArgsEqualityCheckEnforcer();

    /// @dev Error thrown when API signature is invalid.
    error InvalidApiSignature();

    /// @dev Error thrown when the signature expiration has passed.
    error SignatureExpired();

    ////////////////////////////// Modifiers //////////////////////////////

    /**
     * @notice Require the function call to come from the DelegationManager.
     */
    modifier onlyDelegationManager() {
        if (msg.sender != address(delegationManager)) revert NotDelegationManager();
        _;
    }

    /**
     * @notice Require the function call to come from the this contract itself.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the DelegationMetaSwapAdapter contract.
     * @param _owner The initial owner of the contract.
     * @param _swapApiSigner The initial swap API signer.
     * @param _delegationManager The address of the trusted DelegationManager contract has privileged access to call
     *        executeByExecutor based on a given delegation.
     * @param _metaSwap The address of the trusted MetaSwap contract.
     * @param _argsEqualityCheckEnforcer The address of the ArgsEqualityCheckEnforcer contract.
     */
    constructor(
        address _owner,
        address _swapApiSigner,
        IDelegationManager _delegationManager,
        IMetaSwap _metaSwap,
        address _argsEqualityCheckEnforcer
    )
        Ownable(_owner)
    {
        swapApiSigner = _swapApiSigner;
        delegationManager = _delegationManager;
        metaSwap = _metaSwap;
        argsEqualityCheckEnforcer = _argsEqualityCheckEnforcer;
        emit SwapApiSignerUpdated(_swapApiSigner);
        emit SetDelegationManager(_delegationManager);
        emit SetMetaSwap(_metaSwap);
        emit SetArgsEqualityCheckEnforcer(_argsEqualityCheckEnforcer);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive the chain's native token.
     */
    receive() external payable { }

    /**
     * @notice Executes a token swap using a delegation and transfers the swapped tokens to the root delegator, after validating
     * signature and expiration.
     * @dev The msg.sender must be the leaf delegator
     * @param _signatureData Includes:
     * - apiData Encoded swap parameters, used by the aggregator.
     * - expiration Timestamp after which the signature is invalid.
     * - signature Signature validating the provided apiData.
     * @param _delegations Array of Delegation objects containing delegation-specific data, sorted leaf to root.
     * @param _useTokenWhitelist Indicates whether the tokens must be validated or not.
     */
    function swapByDelegation(
        SignatureData calldata _signatureData,
        Delegation[] memory _delegations,
        bool _useTokenWhitelist
    )
        external
    {
        _validateSignature(_signatureData);

        (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_) =
            _decodeApiData(_signatureData.apiData);
        uint256 delegationsLength_ = _delegations.length;

        if (delegationsLength_ == 0) revert InvalidEmptyDelegations();
        if (tokenFrom_ == tokenTo_) revert InvalidIdenticalTokens();

        _validateTokens(tokenFrom_, tokenTo_, _delegations, _useTokenWhitelist);

        if (!isAggregatorAllowed[keccak256(abi.encode(aggregatorId_))]) revert AggregatorIdIsNotAllowed(aggregatorId_);
        if (_delegations[0].delegator != msg.sender) revert NotLeafDelegator();

        // Prepare the call that will be executed internally via onlySelf
        bytes memory encodedSwap_ = abi.encodeWithSelector(
            this.swapTokens.selector,
            aggregatorId_,
            tokenFrom_,
            tokenTo_,
            _delegations[delegationsLength_ - 1].delegator,
            amountFrom_,
            _getSelfBalance(tokenFrom_),
            swapData_
        );

        bytes[] memory permissionContexts_ = new bytes[](2);
        permissionContexts_[0] = abi.encode(_delegations);
        permissionContexts_[1] = abi.encode(new Delegation[](0));

        ModeCode[] memory encodedModes_ = new ModeCode[](2);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](2);

        if (address(tokenFrom_) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), amountFrom_, hex"");
        } else {
            bytes memory encodedTransfer_ = abi.encodeWithSelector(IERC20.transfer.selector, address(this), amountFrom_);
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(tokenFrom_), 0, encodedTransfer_);
        }
        executionCallDatas_[1] = ExecutionLib.encodeSingle(address(this), 0, encodedSwap_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    /**
     * @notice Executes the actual token swap via the MetaSwap contract and transfer the output tokens to the recipient.
     * @dev This function can only be called internally by this contract (`onlySelf`).
     * @param _aggregatorId The identifier for the swap aggregator/DEX aggregator.
     * @param _tokenFrom The input token of the swap.
     * @param _tokenTo The output token of the swap.
     * @param _recipient The address that will receive the swapped tokens.
     * @param _amountFrom The amount of tokens to be swapped.
     * @param _balanceFromBefore The contract’s balance of _tokenFrom before the incoming token transfer is credited.
     * @param _swapData Arbitrary data required by the aggregator (e.g. encoded swap params).
     */
    function swapTokens(
        string calldata _aggregatorId,
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        address _recipient,
        uint256 _amountFrom,
        uint256 _balanceFromBefore,
        bytes calldata _swapData
    )
        external
        onlySelf
    {
        uint256 tokenFromObtained_ = _getSelfBalance(_tokenFrom) - _balanceFromBefore;
        if (tokenFromObtained_ < _amountFrom) revert InsufficientTokens();

        if (tokenFromObtained_ > _amountFrom) {
            _sendTokens(_tokenFrom, tokenFromObtained_ - _amountFrom, _recipient);
        }

        uint256 balanceToBefore_ = _getSelfBalance(_tokenTo);

        uint256 value_ = 0;

        if (address(_tokenFrom) == address(0)) {
            value_ = _amountFrom;
        } else {
            uint256 allowance_ = _tokenFrom.allowance(address(this), address(metaSwap));
            if (allowance_ < _amountFrom) {
                _tokenFrom.safeIncreaseAllowance(address(metaSwap), type(uint256).max);
            }
        }

        metaSwap.swap{ value: value_ }(_aggregatorId, _tokenFrom, _amountFrom, _swapData);

        uint256 obtainedAmount_ = _getSelfBalance(_tokenTo) - balanceToBefore_;

        _sendTokens(_tokenTo, obtainedAmount_, _recipient);
    }

    /**
     * @notice Updates the address authorized to sign API requests.
     * @param _newSigner The new authorized signer address.
     */
    function setSwapApiSigner(address _newSigner) external onlyOwner {
        swapApiSigner = _newSigner;
        emit SwapApiSignerUpdated(_newSigner);
    }

    /**
     * @notice Executes one calls on behalf of this contract,
     *         authorized by the DelegationManager.
     * @dev Only callable by the DelegationManager. Supports single-call execution,
     *         and handles the revert logic via ExecType.
     * @dev Related: @erc7579/MSAAdvanced.sol
     * @param _mode The encoded execution mode of the transaction (CallType, ExecType, etc.).
     * @param _executionCalldata The encoded call data (single) to be executed.
     * @return returnData_ An array of returned data from each executed call.
     */
    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        onlyDelegationManager
        returns (bytes[] memory returnData_)
    {
        (CallType callType_, ExecType execType_,,) = _mode.decode();

        // Only support single call type with default execution
        if (CallType.unwrap(CALLTYPE_SINGLE) != CallType.unwrap(callType_)) revert UnsupportedCallType(callType_);
        if (ExecType.unwrap(EXECTYPE_DEFAULT) != ExecType.unwrap(execType_)) revert UnsupportedExecType(execType_);
        // Process single execution directly without additional checks
        (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
        returnData_ = new bytes[](1);
        returnData_[0] = _execute(target_, value_, callData_);
        return returnData_;
    }

    /**
     * @notice Withdraws a specified token from the contract to a recipient.
     * @dev Only callable by the contract owner.
     * @param _token The token to be withdrawn (use address(0) for native token).
     * @param _amount The amount of tokens (or native) to withdraw.
     * @param _recipient The address to receive the withdrawn tokens.
     */
    function withdraw(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        _sendTokens(_token, _amount, _recipient);
    }

    /**
     * @notice Updates the allowed (whitelist) status of multiple tokens in a single call.
     * @dev Only callable by the contract owner.
     * @param _tokens Array of tokens to modify.
     * @param _statuses Corresponding array of booleans to set each token's allowed status.
     */
    function updateAllowedTokens(IERC20[] calldata _tokens, bool[] calldata _statuses) external onlyOwner {
        uint256 tokensLength_ = _tokens.length;
        if (tokensLength_ != _statuses.length) revert InputLengthsMismatch();

        for (uint256 i = 0; i < tokensLength_; ++i) {
            IERC20 token = _tokens[i];
            bool status_ = _statuses[i];
            if (isTokenAllowed[token] != status_) {
                isTokenAllowed[token] = status_;

                emit ChangedTokenStatus(token, status_);
            }
        }
    }

    /**
     * @notice Updates the allowed (whitelist) status of multiple aggregator IDs in a single call.
     * @dev Only callable by the contract owner.
     * @param _aggregatorIds Array of aggregator ID strings.
     * @param _statuses Corresponding array of booleans (true = allowed, false = disallowed).
     */
    function updateAllowedAggregatorIds(string[] calldata _aggregatorIds, bool[] calldata _statuses) external onlyOwner {
        uint256 aggregatorsLength_ = _aggregatorIds.length;
        if (aggregatorsLength_ != _statuses.length) revert InputLengthsMismatch();

        for (uint256 i = 0; i < aggregatorsLength_; ++i) {
            bytes32 aggregatorIdHash_ = keccak256(abi.encode(_aggregatorIds[i]));
            bool status_ = _statuses[i];
            if (isAggregatorAllowed[aggregatorIdHash_] != status_) {
                isAggregatorAllowed[aggregatorIdHash_] = status_;

                emit ChangedAggregatorIdStatus(aggregatorIdHash_, _aggregatorIds[i], status_);
            }
        }
    }

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @notice Sends tokens or native token to a specified recipient.
     * @param _token ERC20 token to send or address(0) for native token.
     * @param _amount Amount of tokens or native token to send.
     * @param _recipient Address to receive the funds.
     * @dev Reverts if native token transfer fails.
     */
    function _sendTokens(IERC20 _token, uint256 _amount, address _recipient) private {
        if (address(_token) == address(0)) {
            (bool success_,) = _recipient.call{ value: _amount }("");

            if (!success_) revert FailedNativeTokenTransfer(_recipient);
        } else {
            IERC20(_token).safeTransfer(_recipient, _amount);
        }

        emit SentTokens(_token, _recipient, _amount);
    }

    /**
     * @dev Validates that the tokens are whitelisted or not based on the _useTokenWhitelist flag.
     * @dev Adds the argsCheckEnforcer args to later validate if the token whitelist must be have been used or not.
     * @param _tokenFrom The input token of the swap.
     * @param _tokenTo The output token of the swap.
     * @param _delegations The delegation chain; the last delegation must include the ArgsEqualityCheckEnforcer.
     * @param _useTokenWhitelist Flag indicating whether token whitelist checks should be enforced.
     */
    function _validateTokens(
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        Delegation[] memory _delegations,
        bool _useTokenWhitelist
    )
        private
        view
    {
        // The Args Enforcer must be the first caveat in the root delegation
        uint256 lastIndex_ = _delegations.length - 1;
        if (
            _delegations[lastIndex_].caveats.length == 0
                || _delegations[lastIndex_].caveats[0].enforcer != argsEqualityCheckEnforcer
        ) {
            revert MissingArgsEqualityCheckEnforcer();
        }

        // The args are set by this contract depending on the useTokenWhitelist flag
        if (_useTokenWhitelist) {
            if (!isTokenAllowed[_tokenFrom]) revert TokenFromIsNotAllowed(_tokenFrom);
            if (!isTokenAllowed[_tokenTo]) revert TokenToIsNotAllowed(_tokenTo);
            _delegations[lastIndex_].caveats[0].args = abi.encode(WHITELIST_ENFORCED);
        } else {
            _delegations[lastIndex_].caveats[0].args = abi.encode(WHITELIST_NOT_ENFORCED);
        }
    }

    /**
     * @dev Internal helper to decode aggregator data from `apiData`.
     * @param _apiData Bytes that includes aggregatorId, tokenFrom, amountFrom, and the aggregator swap data.
     */
    function _decodeApiData(bytes calldata _apiData)
        private
        pure
        returns (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_)
    {
        bytes4 functionSelector_ = bytes4(_apiData[:4]);
        if (functionSelector_ != IMetaSwap.swap.selector) revert InvalidSwapFunctionSelector();

        // Excluding the function selector
        bytes memory paramTerms_ = _apiData[4:];
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(paramTerms_, (string, IERC20, uint256, bytes));

        // Note: Prepend address(0) to format the data correctly because of the Swaps API. See internal docs.
        (
            , // address(0)
            IERC20 swapTokenFrom_,
            IERC20 swapTokenTo_,
            uint256 swapAmountFrom_,
            , // AmountTo
            , // Metadata
            uint256 feeAmount_,
            , // FeeWallet
            bool feeTo_
        ) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), swapData_),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );

        if (swapTokenFrom_ != tokenFrom_) revert TokenFromMismath();

        // When the fee is deducted from the tokenFrom the (feeAmount) plus the amount actually swapped (swapAmountFrom)
        // must equal the total provided (amountFrom); otherwise, the input is inconsistent.
        if (!feeTo_ && (feeAmount_ + swapAmountFrom_ != amountFrom_)) revert AmountFromMismath();

        tokenTo_ = swapTokenTo_;
    }

    /**
     * @dev Returns this contract's balance of the specified ERC20 token.
     *      If `_token` is address(0), it returns the native token balance.
     * @param _token The token to check balance for.
     * @return balance_ The balance of the specified token.
     */
    function _getSelfBalance(IERC20 _token) private view returns (uint256 balance_) {
        if (address(_token) == address(0)) return address(this).balance;

        return _token.balanceOf(address(this));
    }

    /**
     * @dev Validates the expiration and signature of the provided apiData.
     * @param _signatureData Contains the apiData, the expiration and signature.
     */
    function _validateSignature(SignatureData memory _signatureData) private view {
        if (block.timestamp > _signatureData.expiration) revert SignatureExpired();

        bytes32 messageHash_ = keccak256(abi.encodePacked(_signatureData.apiData, _signatureData.expiration));
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);

        address recoveredSigner_ = ECDSA.recover(ethSignedMessageHash_, _signatureData.signature);
        if (recoveredSigner_ != swapApiSigner) revert InvalidApiSignature();
    }
}
