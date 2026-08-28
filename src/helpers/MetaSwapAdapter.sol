// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IMetaSwap } from "./interfaces/IMetaSwap.sol";

/**
 * @title MetaSwapAdapter
 * @notice Executes signed MetaSwap routes after receiving ERC-20 or native input.
 * @dev ERC-20 input is transferred in the same delegated batch. Native input is supplied as `msg.value` in a
 *      single delegated call. Address zero represents the native token. The adapter assumes the input and output
 *      tokens differ; the companion enforcer guarantees this invariant.
 */
contract MetaSwapAdapter is Ownable2Step, ReentrancyGuard {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    struct ApiQuote {
        bytes apiData;
        uint256 expiration;
        bytes signature;
    }

    IMetaSwap public immutable metaSwap;
    address public immutable swapApiSigner;

    event SwapExecuted(
        address indexed caller,
        IERC20 indexed tokenIn,
        IERC20 indexed tokenOut,
        uint256 tokenInAmount,
        uint256 tokenOutAmount,
        bytes32 quoteDigest
    );
    event TokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    error ApiQuoteExpired();
    error AmountInMismatch();
    error FailedNativeTokenTransfer(address recipient);
    error InsufficientOutput(uint256 minimum, uint256 received);
    error InvalidApiData();
    error InvalidApiSignature();
    error InvalidValue(uint256 expected, uint256 actual);
    error InvalidZeroAddress();
    error InvalidZeroAmount();
    error RemainingAllowance(uint256 remaining);
    error RemainingInputBalance(uint256 remaining);
    error TokenInMismatch();
    error TokenOutMismatch();
    error UnexpectedInputBalance(uint256 expected, uint256 actual);

    constructor(address _owner, address _swapApiSigner, IMetaSwap _metaSwap) Ownable(_owner) {
        if (_swapApiSigner == address(0) || address(_metaSwap) == address(0)) {
            revert InvalidZeroAddress();
        }

        swapApiSigner = _swapApiSigner;
        metaSwap = _metaSwap;
    }

    /**
     * @notice Allows the adapter to receive native swap output.
     */
    receive() external payable { }

    /**
     * @notice Executes a signed route using tokens transferred to this adapter immediately before this call.
     * @param _tokenIn Input token, or address zero for native input supplied as `msg.value`.
     * @param _tokenOut Output token returned to `msg.sender`.
     * @param _tokenInAmount Exact input amount.
     * @param _minTokenOut Minimum output received by `msg.sender`.
     * @param _quote Signed, expiring MetaSwap API calldata.
     * @return tokenOutAmount_ Actual output sent to `msg.sender`.
     */
    function swap(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        ApiQuote calldata _quote
    )
        external
        payable
        nonReentrant
        returns (uint256 tokenOutAmount_)
    {
        if (_tokenInAmount == 0 || _minTokenOut == 0) revert InvalidZeroAmount();

        bool nativeInput_ = address(_tokenIn) == address(0);
        uint256 nativeBalanceBefore_ = _requireMatchingValue(nativeInput_, _tokenInAmount);
        bytes32 quoteDigest_ = _validateSignature(_quote);

        (string memory aggregatorId_, bytes memory swapData_) =
            _decodeApiData(_quote.apiData, _tokenIn, _tokenOut, _tokenInAmount, _minTokenOut);

        if (!nativeInput_) {
            uint256 inputBalance_ = _tokenIn.balanceOf(address(this));
            if (inputBalance_ != _tokenInAmount) revert UnexpectedInputBalance(_tokenInAmount, inputBalance_);
            _tokenIn.forceApprove(address(metaSwap), _tokenInAmount);
        }

        uint256 outputBefore_ = _getSelfBalance(_tokenOut);
        metaSwap.swap{ value: msg.value }(aggregatorId_, _tokenIn, _tokenInAmount, swapData_);
        _assertNoResidualInput(_tokenIn, nativeInput_, nativeBalanceBefore_);

        tokenOutAmount_ = _getSelfBalance(_tokenOut) - outputBefore_;
        if (tokenOutAmount_ < _minTokenOut) revert InsufficientOutput(_minTokenOut, tokenOutAmount_);

        _sendTokens(_tokenOut, msg.sender, tokenOutAmount_);
        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _tokenInAmount, tokenOutAmount_, quoteDigest_);
    }

    /**
     * @notice Returns the eth-signed digest authorized by the API signer.
     */
    function getQuoteDigest(bytes calldata _apiData, uint256 _expiration) public pure returns (bytes32) {
        return keccak256(abi.encode(_apiData, _expiration)).toEthSignedMessageHash();
    }

    /**
     * @notice Recovers tokens accidentally sent outside an atomic transfer-and-swap batch.
     * @dev Recommended delegation: owner-only recovery restricted by token, recipient, and amount.
     */
    function withdraw(IERC20 _token, address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidZeroAddress();
        _sendTokens(_token, _recipient, _amount);
        emit TokensWithdrawn(_token, _recipient, _amount);
    }

    function _decodeApiData(
        bytes calldata _apiData,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut
    )
        private
        pure
        returns (string memory aggregatorId_, bytes memory swapData_)
    {
        if (_apiData.length < 4 || bytes4(_apiData[:4]) != IMetaSwap.swap.selector) revert InvalidApiData();

        IERC20 outerTokenIn_;
        uint256 outerAmountIn_;
        (aggregatorId_, outerTokenIn_, outerAmountIn_, swapData_) = abi.decode(_apiData[4:], (string, IERC20, uint256, bytes));

        if (bytes(aggregatorId_).length == 0) revert InvalidApiData();
        if (outerTokenIn_ != _tokenIn) revert TokenInMismatch();
        if (outerAmountIn_ != _tokenInAmount) revert AmountInMismatch();

        (, // Swaps API omitted leading address
            IERC20 innerTokenIn_,
            IERC20 innerTokenOut_,
            uint256 innerAmountIn_,
            uint256 quotedAmountOut_,, // metadata
            uint256 feeAmount_,, // fee wallet
            bool feeFromOutput_
        ) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), swapData_),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );

        if (innerTokenIn_ != _tokenIn) revert TokenInMismatch();
        if (innerTokenOut_ != _tokenOut) revert TokenOutMismatch();
        if (!feeFromOutput_ && feeAmount_ + innerAmountIn_ != _tokenInAmount) revert AmountInMismatch();
        if (quotedAmountOut_ < _minTokenOut) revert InsufficientOutput(_minTokenOut, quotedAmountOut_);
    }

    function _requireMatchingValue(bool _nativeInput, uint256 _tokenInAmount) private view returns (uint256 nativeBalanceBefore_) {
        if (_nativeInput) {
            if (msg.value != _tokenInAmount) revert InvalidValue(_tokenInAmount, msg.value);
            return address(this).balance - msg.value;
        }
        if (msg.value != 0) revert InvalidValue(0, msg.value);
    }

    function _validateSignature(ApiQuote calldata _quote) private view returns (bytes32 messageHash_) {
        if (block.timestamp >= _quote.expiration) revert ApiQuoteExpired();
        messageHash_ = keccak256(abi.encode(_quote.apiData, _quote.expiration));
        if (ECDSA.recover(messageHash_.toEthSignedMessageHash(), _quote.signature) != swapApiSigner) {
            revert InvalidApiSignature();
        }
    }

    function _assertNoResidualInput(IERC20 _tokenIn, bool _nativeInput, uint256 _nativeBalanceBefore) private view {
        if (!_nativeInput) {
            uint256 remainingAllowance_ = _tokenIn.allowance(address(this), address(metaSwap));
            if (remainingAllowance_ != 0) revert RemainingAllowance(remainingAllowance_);
        }

        uint256 remainingInput_ = _getSelfBalance(_tokenIn);
        if (_nativeInput) remainingInput_ -= _nativeBalanceBefore;
        if (remainingInput_ != 0) revert RemainingInputBalance(remainingInput_);
    }

    function _getSelfBalance(IERC20 _token) private view returns (uint256) {
        if (address(_token) == address(0)) return address(this).balance;
        return _token.balanceOf(address(this));
    }

    function _sendTokens(IERC20 _token, address _recipient, uint256 _amount) private {
        if (address(_token) == address(0)) {
            (bool success_,) = _recipient.call{ value: _amount }("");
            if (!success_) revert FailedNativeTokenTransfer(_recipient);
        } else {
            _token.safeTransfer(_recipient, _amount);
        }
    }
}
