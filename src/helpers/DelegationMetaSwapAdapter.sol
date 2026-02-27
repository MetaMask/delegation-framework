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
import { IMetaSwapParamsEnforcer } from "./interfaces/IMetaSwapParamsEnforcer.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { CallType, ExecType, Caveat, Delegation, ModeCode } from "../utils/Types.sol";
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

    /// @dev Packed params for _executeSwap to avoid stack-too-deep.
    struct SwapParams {
        string aggregatorId;
        IERC20 tokenFrom;
        IERC20 tokenTo;
        address recipient;
        uint256 amountFrom;
        uint256 balanceFromBefore;
        bytes swapData;
        uint256 minAmountOut;
        uint256 effectiveMaxSlippagePercent;
    }

    ////////////////////////////// State //////////////////////////////

    /// @dev Pre-encoded empty delegations context for the second permission context in redeemDelegations (avoids allocation per call).
    bytes private emptyDelegationsContext = abi.encode(new Delegation[](0));

    /// @dev Constant value used to enforce the token whitelist
    string public constant WHITELIST_ENFORCED = "Token-Whitelist-Enforced";

    /// @dev Constant value used to avoid enforcing the token whitelist
    string public constant WHITELIST_NOT_ENFORCED = "Token-Whitelist-Not-Enforced";

    /// @dev 100% in 18-decimal fixed point. Slippage format: 100e18 = 100%, 10e18 = 10%.
    uint256 private constant PERCENT_100 = 100e18;

    /// @dev The DelegationManager contract that has root access to this contract
    IDelegationManager public immutable delegationManager;

    /// @dev The MetaSwap contract used to swap tokens
    IMetaSwap public immutable metaSwap;

    /// @dev The enforcer used to compare args and terms
    address public immutable argsEqualityCheckEnforcer;

    /// @dev Enforcer for root swap params (allowed output tokens, recipient, max slippage).
    address public immutable metaSwapParamsEnforcer;

    /// @dev Address of the API signer account.
    address public swapApiSigner;

    /// @dev Indicates if a token is allowed to be used in the swaps
    mapping(IERC20 token => bool allowed) public isTokenAllowed;

    /// @dev Admin-set max slippage per output token (100e18 = 100%; 0 = no check).
    mapping(IERC20 token => uint256) public maxSlippagePercentPerToken;

    /// @dev A mapping indicating if an aggregator ID hash is allowed.
    mapping(bytes32 aggregatorIdHash => bool allowed) public isAggregatorAllowed;

    /// @dev Allowed operators that may call swapByDelegation.
    mapping(address operator => bool allowed) public allowedOperators;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the DelegationManager contract address is set.
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    /// @dev Emitted when the MetaSwap contract address is set.
    event SetMetaSwap(IMetaSwap indexed newMetaSwap);

    /// @dev Emitted when the Args Equality Check Enforcer contract address is set.
    event SetArgsEqualityCheckEnforcer(address indexed newArgsEqualityCheckEnforcer);

    /// @dev Emitted when the MetaSwapParamsEnforcer contract address is set.
    event SetMetaSwapParamsEnforcer(address indexed newMetaSwapParamsEnforcer);

    /// @dev Emitted when the contract sends tokens (or native tokens) to a recipient.
    event SentTokens(IERC20 indexed token, address indexed recipient, uint256 amount);

    /// @dev Emitted when the allowed token status changes for a token.
    event ChangedTokenStatus(IERC20 token, bool status);

    /// @dev Emitted when the allowed aggregator ID status changes.
    event ChangedAggregatorIdStatus(bytes32 indexed aggregatorIdHash, string aggregatorId, bool status);

    /// @dev Emitted when the Signer API is updated.
    event SwapApiSignerUpdated(address indexed newSigner);

    /// @dev Emitted when the max slippage for a token is set by the owner.
    event MaxSlippagePercentSet(IERC20 indexed token, uint256 maxSlippagePercent);

    /// @dev Emitted when an operator's allowed status is changed.
    event OperatorStatusChanged(address indexed operator, bool status);

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
    error TokenFromMismatch();

    /// @dev Error when the amountFrom in the api data and swap data do not match.
    error AmountFromMismatch();

    /// @dev Error when the delegations do not include the ArgsEqualityCheckEnforcer
    error MissingArgsEqualityCheckEnforcer();

    /// @dev Error thrown when API signature is invalid.
    error InvalidApiSignature();

    /// @dev Error thrown when the signature expiration has passed.
    error SignatureExpired();

    /// @dev Error thrown when the address is zero.
    error InvalidZeroAddress();

    /// @dev Error thrown when the swap output is below the minimum allowed by slippage tolerance.
    error SlippageExceeded(uint256 minAmountOut, uint256 obtainedAmount, uint256 maxSlippagePercent);

    /// @dev Error thrown when max slippage percent exceeds PERCENT_100 (100e18).
    error InvalidMaxSlippage(uint256 percent);

    /// @dev Error thrown when delegation's max slippage exceeds the per-token cap.
    error DelegationSlippageExceedsTokenCap(uint256 delegationSlippagePercent, uint256 tokenCapPercent);

    /// @dev Error thrown when swap output token has no per-token slippage cap set (must be > 0).
    error PerTokenSlippageNotSet(IERC20 token);

    /// @dev Error thrown when the caller is not an allowed operator.
    error NotAllowedOperator(address operator);

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

    /**
     * @notice Require the caller to be an allowed operator for swapByDelegation.
     */
    modifier onlyAllowedOperator() {
        if (!allowedOperators[msg.sender]) revert NotAllowedOperator(msg.sender);
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
     * @param _metaSwapParamsEnforcer Address of the MetaSwapParamsEnforcer (allowed output tokens, recipient, slippage).
     */
    constructor(
        address _owner,
        address _swapApiSigner,
        IDelegationManager _delegationManager,
        IMetaSwap _metaSwap,
        address _argsEqualityCheckEnforcer,
        address _metaSwapParamsEnforcer
    )
        Ownable(_owner)
    {
        if (
            _swapApiSigner == address(0) || address(_delegationManager) == address(0) || address(_metaSwap) == address(0)
                || _argsEqualityCheckEnforcer == address(0) || _metaSwapParamsEnforcer == address(0)
        ) revert InvalidZeroAddress();

        swapApiSigner = _swapApiSigner;
        delegationManager = _delegationManager;
        metaSwap = _metaSwap;
        argsEqualityCheckEnforcer = _argsEqualityCheckEnforcer;
        metaSwapParamsEnforcer = _metaSwapParamsEnforcer;
        emit SwapApiSignerUpdated(_swapApiSigner);
        emit SetDelegationManager(_delegationManager);
        emit SetMetaSwap(_metaSwap);
        emit SetArgsEqualityCheckEnforcer(_argsEqualityCheckEnforcer);
        emit SetMetaSwapParamsEnforcer(_metaSwapParamsEnforcer);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive the chain's native token.
     */
    receive() external payable { }

    /**
     * @notice Executes a token swap using a delegation and transfers the swapped tokens to the root delegator, after validating
     * signature and expiration.
     * @dev Only callable by allowed operators. The msg.sender must be the leaf delegator (enforced after operator check).
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
        onlyAllowedOperator
    {
        _validateSignature(_signatureData);

        (
            string memory aggregatorId_,
            IERC20 tokenFrom_,
            IERC20 tokenTo_,
            uint256 amountFrom_,
            uint256 minAmountOut_,
            bytes memory swapData_
        ) = _decodeApiData(_signatureData.apiData);
        uint256 delegationsLength_ = _delegations.length;

        if (delegationsLength_ == 0) revert InvalidEmptyDelegations();
        if (tokenFrom_ == tokenTo_) revert InvalidIdenticalTokens();

        _validateTokens(tokenFrom_, tokenTo_, _delegations, _useTokenWhitelist);

        if (!isAggregatorAllowed[keccak256(abi.encode(aggregatorId_))]) revert AggregatorIdIsNotAllowed(aggregatorId_);
        if (_delegations[0].delegator != msg.sender) revert NotLeafDelegator();

        address rootDelegator_ = _delegations[delegationsLength_ - 1].delegator;
        (address recipient_, uint256 effectiveMaxSlippagePercent_) = _getRootSwapParams(_delegations, tokenTo_, rootDelegator_);

        bytes memory encodedSwap_ = _encodeSwapCall(
            aggregatorId_,
            tokenFrom_,
            tokenTo_,
            recipient_,
            amountFrom_,
            swapData_,
            minAmountOut_,
            effectiveMaxSlippagePercent_
        );

        bytes[] memory permissionContexts_ = new bytes[](2);
        permissionContexts_[0] = abi.encode(_delegations);
        permissionContexts_[1] = emptyDelegationsContext;

        ModeCode[] memory encodedModes_ = new ModeCode[](2);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](2);

        if (address(tokenFrom_) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), amountFrom_, hex"");
        } else {
            bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), amountFrom_));
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(tokenFrom_), 0, encodedTransfer_);
        }
        executionCallDatas_[1] = ExecutionLib.encodeSingle(address(this), 0, encodedSwap_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    /**
     * @notice Executes the actual token swap via the MetaSwap contract and transfer the output tokens to the recipient.
     * @dev This function can only be called internally by this contract (`onlySelf`).
     */
    function swapTokens(
        string calldata _aggregatorId,
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        address _recipient,
        uint256 _amountFrom,
        uint256 _balanceFromBefore,
        bytes calldata _swapData,
        uint256 _minAmountOut,
        uint256 _effectiveMaxSlippagePercent
    )
        external
        onlySelf
    {
        SwapParams memory p_ = SwapParams({
            aggregatorId: _aggregatorId,
            tokenFrom: _tokenFrom,
            tokenTo: _tokenTo,
            recipient: _recipient,
            amountFrom: _amountFrom,
            balanceFromBefore: _balanceFromBefore,
            swapData: _swapData,
            minAmountOut: _minAmountOut,
            effectiveMaxSlippagePercent: _effectiveMaxSlippagePercent
        });
        _executeSwap(p_);
    }

    /**
     * @dev Internal swap execution and slippage check (single struct param to avoid stack-too-deep).
     */
    function _executeSwap(SwapParams memory p_) internal {
        uint256 tokenFromObtained_ = _getSelfBalance(p_.tokenFrom) - p_.balanceFromBefore;
        if (tokenFromObtained_ < p_.amountFrom) revert InsufficientTokens();

        if (tokenFromObtained_ > p_.amountFrom) {
            _sendTokens(p_.tokenFrom, tokenFromObtained_ - p_.amountFrom, p_.recipient);
        }

        uint256 balanceToBefore_ = _getSelfBalance(p_.tokenTo);

        if (address(p_.tokenFrom) == address(0)) {
            metaSwap.swap{ value: p_.amountFrom }(p_.aggregatorId, p_.tokenFrom, p_.amountFrom, p_.swapData);
        } else {
            uint256 allowance_ = p_.tokenFrom.allowance(address(this), address(metaSwap));
            if (allowance_ < p_.amountFrom) {
                p_.tokenFrom.safeIncreaseAllowance(address(metaSwap), type(uint256).max);
            }
            metaSwap.swap(p_.aggregatorId, p_.tokenFrom, p_.amountFrom, p_.swapData);
        }

        uint256 obtainedAmount_ = _getSelfBalance(p_.tokenTo) - balanceToBefore_;

        // Post-swap slippage check disabled for now. Re-enable when desired.
        // if (p_.minAmountOut > 0 && p_.effectiveMaxSlippagePercent > 0) {
        //     uint256 minAllowed_ = p_.minAmountOut * (PERCENT_100 - p_.effectiveMaxSlippagePercent) / PERCENT_100;
        //     if (obtainedAmount_ < minAllowed_) {
        //         revert SlippageExceeded(p_.minAmountOut, obtainedAmount_, p_.effectiveMaxSlippagePercent);
        //     }
        // }

        _sendTokens(p_.tokenTo, obtainedAmount_, p_.recipient);
    }

    /**
     * @notice Updates the address authorized to sign API requests.
     * @param _newSigner The new authorized signer address.
     */
    function setSwapApiSigner(address _newSigner) external onlyOwner {
        if (_newSigner == address(0)) revert InvalidZeroAddress();
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
     * @notice Sets the maximum slippage for multiple output tokens (admin default).
     * @dev When per-delegation maxSlippagePercent is 0, these values are used. 0 = no check. Each must be <= 100e18.
     * @param _tokens Output tokens (tokenTo) to set slippage for.
     * @param _maxSlippagePercents Max slippage per token (100e18 = 100%, 10e18 = 10%). Length must match _tokens.
     */
    function setMaxSlippagePercentForToken(IERC20[] calldata _tokens, uint256[] calldata _maxSlippagePercents) external onlyOwner {
        uint256 length_ = _tokens.length;
        if (length_ != _maxSlippagePercents.length) revert InputLengthsMismatch();

        for (uint256 i = 0; i < length_; ++i) {
            uint256 percent_ = _maxSlippagePercents[i];
            if (percent_ > PERCENT_100) revert InvalidMaxSlippage(percent_);
            maxSlippagePercentPerToken[_tokens[i]] = percent_;
            emit MaxSlippagePercentSet(_tokens[i], percent_);
        }
    }

    /**
     * @notice Updates the allowed operator status for addresses that may call swapByDelegation.
     * @dev Only callable by the contract owner.
     * @param _operators Array of operator addresses.
     * @param _statuses Corresponding array of booleans (true = allowed, false = disallowed).
     */
    function updateAllowedOperators(address[] calldata _operators, bool[] calldata _statuses) external onlyOwner {
        uint256 length_ = _operators.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();

        for (uint256 i = 0; i < length_; ++i) {
            address operator_ = _operators[i];
            bool status_ = _statuses[i];
            if (allowedOperators[operator_] != status_) {
                allowedOperators[operator_] = status_;
                emit OperatorStatusChanged(operator_, status_);
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
     * @dev Validates the expiration and signature of the provided apiData.
     * @param _signatureData Contains the apiData, the expiration and signature.
     */
    function _validateSignature(SignatureData memory _signatureData) internal view {
        if (block.timestamp >= _signatureData.expiration) revert SignatureExpired();

        bytes32 messageHash_ = keccak256(abi.encode(_signatureData.apiData, _signatureData.expiration));
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);

        address recoveredSigner_ = ECDSA.recover(ethSignedMessageHash_, _signatureData.signature);
        if (recoveredSigner_ != swapApiSigner) revert InvalidApiSignature();
    }

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
     * @dev Builds the encoded swapTokens call for redeemDelegations (reduces stack depth in swapByDelegation).
     */
    function _encodeSwapCall(
        string memory _aggregatorId,
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        address _recipient,
        uint256 _amountFrom,
        bytes memory _swapData,
        uint256 _minAmountOut,
        uint256 _effectiveMaxSlippagePercent
    )
        private
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            this.swapTokens,
            (
                _aggregatorId,
                _tokenFrom,
                _tokenTo,
                _recipient,
                _amountFrom,
                _getSelfBalance(_tokenFrom),
                _swapData,
                _minAmountOut,
                _effectiveMaxSlippagePercent
            )
        );
    }

    /**
     * @dev Resolves recipient and effective max slippage from root delegation's MetaSwapParamsEnforcer caveat (if present).
     * Sets that caveat's args to tokenTo so the enforcer can validate during redeem.
     * Effective slippage = delegation slippage if non-zero, else maxSlippagePercentPerToken[tokenTo] (same as used in _executeSwap).
     * @return recipient_ Address to receive swap output (root delegator if no params or recipient zero).
     * @return effectiveMaxSlippagePercent_ Slippage that will be used for the swap (delegation or per-token default). Format: 100e18 = 100%.
     */
    function _getRootSwapParams(
        Delegation[] memory _delegations,
        IERC20 _tokenTo,
        address _rootDelegator
    )
        private
        view
        returns (address recipient_, uint256 effectiveMaxSlippagePercent_)
    {
        recipient_ = _rootDelegator;
        uint256 maxSlippagePercentFromDelegation_ = 0;

        // Root delegation must have caveat[0] = ArgsEqualityCheckEnforcer (enforced in _validateTokens), so start at 1.
        uint256 lastIndex_ = _delegations.length - 1;
        Caveat[] memory caveats_ = _delegations[lastIndex_].caveats;
        uint256 caveatsLength_ = caveats_.length;

        for (uint256 i = 1; i < caveatsLength_; ++i) {
            if (caveats_[i].enforcer != metaSwapParamsEnforcer) continue;

            (, address recipientFromTerms, uint256 maxSlippagePercent) =
                IMetaSwapParamsEnforcer(caveats_[i].enforcer).getTermsInfo(caveats_[i].terms);

            _delegations[lastIndex_].caveats[i].args = abi.encode(_tokenTo);
            recipient_ = recipientFromTerms != address(0) ? recipientFromTerms : _rootDelegator;
            maxSlippagePercentFromDelegation_ = maxSlippagePercent;
            break;
        }

        uint256 perTokenCap_ = maxSlippagePercentPerToken[_tokenTo];
        if (perTokenCap_ == 0) {
            revert PerTokenSlippageNotSet(_tokenTo);
        }
        if (maxSlippagePercentFromDelegation_ > perTokenCap_) {
            revert DelegationSlippageExceedsTokenCap(maxSlippagePercentFromDelegation_, perTokenCap_);
        }
        effectiveMaxSlippagePercent_ =
            maxSlippagePercentFromDelegation_ != 0 ? maxSlippagePercentFromDelegation_ : perTokenCap_;
        return (recipient_, effectiveMaxSlippagePercent_);
    }

    /**
     * @notice Decodes apiData (selector + abi.encode(aggregatorId, tokenFrom, amountFrom, swapData)). Same logic as internal
     * decode.
     * @param _apiData Calldata passed to swap or used in swapByDelegation.
     * @return aggregatorId_ aggregatorId from apiData.
     * @return tokenFrom_ tokenFrom from apiData.
     * @return tokenTo_ tokenTo derived from swapData.
     * @return amountFrom_ amountFrom from apiData.
     * @return amountTo_ amountTo from swapData.
     * @return swapData_ raw swapData bytes.
     */
    function decodeApiData(bytes calldata _apiData)
        external
        pure
        returns (
            string memory aggregatorId_,
            IERC20 tokenFrom_,
            IERC20 tokenTo_,
            uint256 amountFrom_,
            uint256 amountTo_,
            bytes memory swapData_
        )
    {
        return _decodeApiData(_apiData);
    }

    /**
     * @dev Internal helper to decode aggregator data from `apiData`.
     * @param _apiData Bytes that includes aggregatorId, tokenFrom, amountFrom, and the aggregator swap data.
     */
    function _decodeApiData(bytes calldata _apiData)
        internal
        pure
        returns (
            string memory aggregatorId_,
            IERC20 tokenFrom_,
            IERC20 tokenTo_,
            uint256 amountFrom_,
            uint256 amountTo_,
            bytes memory swapData_
        )
    {
        bytes4 functionSelector_ = bytes4(_apiData[:4]);
        if (functionSelector_ != IMetaSwap.swap.selector) revert InvalidSwapFunctionSelector();

        // Excluding the function selector
        bytes memory paramTerms_ = _apiData[4:];
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(paramTerms_, (string, IERC20, uint256, bytes));

        // Note: Prepend address(0) to format the data correctly because of the Swaps API. See internal docs.
        (, // address(0)
            IERC20 swapTokenFrom_,
            IERC20 swapTokenTo_,
            uint256 swapAmountFrom_,
            uint256 swapAmountTo_,, // Metadata
            uint256 feeAmount_,, // FeeWallet
            bool feeTo_
        ) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), swapData_),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );

        if (swapTokenFrom_ != tokenFrom_) revert TokenFromMismatch();

        // When the fee is deducted from the tokenFrom the (feeAmount) plus the amount actually swapped (swapAmountFrom)
        // must equal the total provided (amountFrom); otherwise, the input is inconsistent.
        if (!feeTo_ && (feeAmount_ + swapAmountFrom_ != amountFrom_)) revert AmountFromMismatch();

        tokenTo_ = swapTokenTo_;
        amountTo_ = swapAmountTo_;
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
}
