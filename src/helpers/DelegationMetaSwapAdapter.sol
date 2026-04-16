// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { IMetaSwap } from "./interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";

/**
 * @title DelegationMetaSwapAdapter
 * @notice Acts as a middleman to orchestrate token swaps using delegations and an aggregator (MetaSwap).
 * @dev The delegator creates a single delegation directly to this adapter. No redelegation is required.
 *      Token whitelist is always enforced via the contract-level `isTokenAllowed` mapping managed by the owner.
 *      The delegation itself should include period-based transfer enforcers (ERC20PeriodTransferEnforcer or
 *      NativeTokenPeriodTransferEnforcer) plus a RedeemerEnforcer to restrict who can redeem.
 *
 * @dev This adapter is intended to be used with the Swaps API. Accordingly, all API requests must include a valid
 *      signature that incorporates an expiration timestamp. The signature is verified during swap execution to ensure
 *      that it is still valid.
 */
contract DelegationMetaSwapAdapter is Ownable2Step {
    using SafeERC20 for IERC20;

    struct SignatureData {
        bytes apiData;
        uint256 expiration;
        bytes signature;
    }

    ////////////////////////////// State //////////////////////////////

    /// @dev The DelegationManager contract that has root access to this contract
    IDelegationManager public immutable delegationManager;

    /// @dev The MetaSwap contract used to swap tokens
    IMetaSwap public immutable metaSwap;

    /// @dev Address of the API signer account.
    address public swapApiSigner;

    /// @dev Indicates if a token is allowed to be used in the swaps
    mapping(IERC20 token => bool allowed) public isTokenAllowed;

    /// @dev Indicates if a caller is allowed to invoke swapByDelegation.
    mapping(address caller => bool allowed) public isCallerAllowed;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the DelegationManager contract address is set.
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    /// @dev Emitted when the MetaSwap contract address is set.
    event SetMetaSwap(IMetaSwap indexed newMetaSwap);

    /// @dev Emitted when the contract sends tokens (or native tokens) to a recipient.
    event SentTokens(IERC20 indexed token, address indexed recipient, uint256 amount);

    /// @dev Emitted when the allowed token status changes for a token.
    event ChangedTokenStatus(IERC20 token, bool status);

    /// @dev Emitted when the allowed caller status changes.
    event ChangedCallerStatus(address indexed caller, bool status);

    /// @dev Emitted when the Signer API is updated.
    event SwapApiSignerUpdated(address indexed newSigner);

    ////////////////////////////// Errors //////////////////////////////

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

    /// @dev Error thrown when API signature is invalid.
    error InvalidApiSignature();

    /// @dev Error thrown when the signature expiration has passed.
    error SignatureExpired();

    /// @dev Error thrown when the caller is not in the allowed callers list.
    error CallerNotAllowed();

    /// @dev Error thrown when the address is zero.
    error InvalidZeroAddress();

    ////////////////////////////// Modifiers //////////////////////////////

    /**
     * @notice Require the caller to be in the allowed callers whitelist.
     */
    modifier onlyAllowedCaller() {
        if (!isCallerAllowed[msg.sender]) revert CallerNotAllowed();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the DelegationMetaSwapAdapter contract.
     * @param _owner The initial owner of the contract.
     * @param _swapApiSigner The initial swap API signer.
     * @param _delegationManager The address of the trusted DelegationManager contract.
     * @param _metaSwap The address of the trusted MetaSwap contract.
     */
    constructor(
        address _owner,
        address _swapApiSigner,
        IDelegationManager _delegationManager,
        IMetaSwap _metaSwap
    )
        Ownable(_owner)
    {
        if (_swapApiSigner == address(0) || address(_delegationManager) == address(0) || address(_metaSwap) == address(0)) {
            revert InvalidZeroAddress();
        }

        swapApiSigner = _swapApiSigner;
        delegationManager = _delegationManager;
        metaSwap = _metaSwap;
        emit SwapApiSignerUpdated(_swapApiSigner);
        emit SetDelegationManager(_delegationManager);
        emit SetMetaSwap(_metaSwap);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive the chain's native token.
     */
    receive() external payable { }

    /**
     * @notice Executes a token swap using a delegation and transfers the swapped tokens to the root delegator, after
     *         validating signature and expiration.
     * @dev The delegation chain goes directly from the delegator to this adapter (no redelegation needed).
     *      The delegation should include period-based transfer enforcers and a RedeemerEnforcer.
     * @param _signatureData Includes:
     * - apiData Encoded swap parameters, used by the aggregator.
     * - expiration Timestamp after which the signature is invalid.
     * - signature Signature validating the provided apiData.
     * @param _delegations Array of Delegation objects containing delegation-specific data, sorted leaf to root.
     */
    function swapByDelegation(SignatureData calldata _signatureData, Delegation[] memory _delegations) external onlyAllowedCaller {
        _validateSignature(_signatureData);

        (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_) =
            _decodeApiData(_signatureData.apiData);
        uint256 delegationsLength_ = _delegations.length;

        if (delegationsLength_ == 0) revert InvalidEmptyDelegations();
        if (tokenFrom_ == tokenTo_) revert InvalidIdenticalTokens();

        _validateTokens(tokenFrom_, tokenTo_);

        address recipient_ = _delegations[delegationsLength_ - 1].delegator;

        // Snapshot balance before redeeming the delegation
        uint256 balanceFromBefore_ = _getSelfBalance(tokenFrom_);

        // Redeem the delegation to transfer tokens from the delegator to this adapter
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        if (address(tokenFrom_) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), amountFrom_, hex"");
        } else {
            bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), amountFrom_));
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(tokenFrom_), 0, encodedTransfer_);
        }

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Verify actual tokens received via balance delta
        _swapTokens(aggregatorId_, tokenFrom_, tokenTo_, recipient_, amountFrom_, balanceFromBefore_, swapData_);
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
     * @notice Updates the allowed (whitelist) status of multiple callers in a single call.
     * @dev Only callable by the contract owner.
     * @param _callers Array of caller addresses to modify.
     * @param _statuses Corresponding array of booleans to set each caller's allowed status.
     */
    function updateAllowedCallers(address[] calldata _callers, bool[] calldata _statuses) external onlyOwner {
        uint256 callersLength_ = _callers.length;
        if (callersLength_ != _statuses.length) revert InputLengthsMismatch();

        for (uint256 i = 0; i < callersLength_; ++i) {
            address caller_ = _callers[i];
            bool status_ = _statuses[i];
            if (isCallerAllowed[caller_] != status_) {
                isCallerAllowed[caller_] = status_;
                emit ChangedCallerStatus(caller_, status_);
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
            _token.safeTransfer(_recipient, _amount);
        }

        emit SentTokens(_token, _recipient, _amount);
    }

    /**
     * @dev Validates that both tokens are whitelisted by the contract owner.
     * @param _tokenFrom The input token of the swap.
     * @param _tokenTo The output token of the swap.
     */
    function _validateTokens(IERC20 _tokenFrom, IERC20 _tokenTo) private view {
        if (!isTokenAllowed[_tokenFrom]) revert TokenFromIsNotAllowed(_tokenFrom);
        if (!isTokenAllowed[_tokenTo]) revert TokenToIsNotAllowed(_tokenTo);
    }

    /**
     * @dev Executes the token swap via the MetaSwap contract and sends the output tokens to the recipient.
     *      Verifies the actual tokens received by comparing balances before and after the delegation redemption.
     * @param _aggregatorId The identifier for the swap aggregator.
     * @param _tokenFrom The input token of the swap.
     * @param _tokenTo The output token of the swap.
     * @param _recipient The address that will receive the swapped tokens.
     * @param _amountFrom The expected amount of tokens to be swapped.
     * @param _balanceFromBefore The contract's balance of _tokenFrom before the delegation was redeemed.
     * @param _swapData Arbitrary data required by the aggregator.
     */
    function _swapTokens(
        string memory _aggregatorId,
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        address _recipient,
        uint256 _amountFrom,
        uint256 _balanceFromBefore,
        bytes memory _swapData
    )
        private
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
                _tokenFrom.forceApprove(address(metaSwap), type(uint256).max);
            }
        }

        metaSwap.swap{ value: value_ }(_aggregatorId, _tokenFrom, _amountFrom, _swapData);

        uint256 obtainedAmount_ = _getSelfBalance(_tokenTo) - balanceToBefore_;

        _sendTokens(_tokenTo, obtainedAmount_, _recipient);
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

        bytes memory paramTerms_ = _apiData[4:];
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(paramTerms_, (string, IERC20, uint256, bytes));

        // Note: Prepend address(0) to format the data correctly because of the Swaps API. See internal docs.
        (, // address(0)
            IERC20 swapTokenFrom_,
            IERC20 swapTokenTo_,
            uint256 swapAmountFrom_,, // AmountTo
            , // Metadata
            uint256 feeAmount_,, // FeeWallet
            bool feeTo_
        ) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), swapData_),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );

        if (swapTokenFrom_ != tokenFrom_) revert TokenFromMismatch();

        if (!feeTo_ && (feeAmount_ + swapAmountFrom_ != amountFrom_)) revert AmountFromMismatch();

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
}
