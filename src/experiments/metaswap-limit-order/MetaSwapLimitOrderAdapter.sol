// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IMetaSwap } from "../../helpers/interfaces/IMetaSwap.sol";

/**
 * @title MetaSwapLimitOrderAdapter
 * @notice Executes short-lived MetaSwap routes after receiving an exact delegated ERC-20 transfer.
 * @dev The delegation binds the pair, input, and minimum output. The API signature authenticates only the
 *      route selected after the maker signs. Output always returns to the calling maker account.
 */
contract MetaSwapLimitOrderAdapter is ReentrancyGuard {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    struct ApiQuote {
        string aggregatorId;
        bytes swapData;
        uint64 validUntil;
        bytes signature;
    }

    IMetaSwap public immutable metaSwap;
    address public immutable apiSigner;

    event SwapExecuted(
        address indexed maker,
        IERC20 indexed tokenIn,
        IERC20 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 quoteDigest
    );

    error ApiQuoteExpired();
    error IdenticalTokens();
    error IncorrectInputConsumed(uint256 expected, uint256 actual);
    error InsufficientInput(uint256 expected, uint256 available);
    error InsufficientOutput(uint256 minimum, uint256 actual);
    error InvalidApiSignature();
    error InvalidQuote();
    error InvalidZeroAddress();
    error InvalidZeroAmount();
    error RemainingAllowance(uint256 remaining);

    /**
     * @notice Sets immutable MetaSwap and API signer dependencies.
     * @param _metaSwap MetaSwap settlement contract.
     * @param _apiSigner Signer trusted only to attest executable route bytes.
     */
    constructor(IMetaSwap _metaSwap, address _apiSigner) {
        if (address(_metaSwap) == address(0) || _apiSigner == address(0)) revert InvalidZeroAddress();
        metaSwap = _metaSwap;
        apiSigner = _apiSigner;
    }

    /**
     * @notice Swaps an exact ERC-20 input and returns all newly received output to the caller.
     * @dev Must be called immediately after the delegated account transfers `_amountIn` to this adapter.
     * @param _tokenIn Maker-signed input token.
     * @param _tokenOut Maker-signed output token.
     * @param _amountIn Exact input amount that MetaSwap must consume.
     * @param _minAmountOut Minimum actual output returned to the maker.
     * @param _quote Short-lived API-signed dynamic route.
     * @return amountOut_ Actual output returned to the maker.
     */
    function swap(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        ApiQuote calldata _quote
    )
        external
        nonReentrant
        returns (uint256 amountOut_)
    {
        if (address(_tokenIn) == address(0) || address(_tokenOut) == address(0)) revert InvalidZeroAddress();
        if (_tokenIn == _tokenOut) revert IdenticalTokens();
        if (_amountIn == 0 || _minAmountOut == 0) revert InvalidZeroAmount();

        bytes32 quoteDigest_ = _validateQuote(_tokenIn, _tokenOut, _amountIn, _minAmountOut, _quote);
        uint256 inputBefore_ = _tokenIn.balanceOf(address(this));
        if (inputBefore_ < _amountIn) revert InsufficientInput(_amountIn, inputBefore_);
        uint256 outputBefore_ = _tokenOut.balanceOf(address(this));

        _tokenIn.forceApprove(address(metaSwap), _amountIn);
        metaSwap.swap(_quote.aggregatorId, _tokenIn, _amountIn, _quote.swapData);

        uint256 remainingAllowance_ = _tokenIn.allowance(address(this), address(metaSwap));
        if (remainingAllowance_ != 0) revert RemainingAllowance(remainingAllowance_);

        uint256 inputAfter_ = _tokenIn.balanceOf(address(this));
        uint256 inputConsumed_ = inputBefore_ - inputAfter_;
        if (inputConsumed_ != _amountIn) revert IncorrectInputConsumed(_amountIn, inputConsumed_);

        amountOut_ = _tokenOut.balanceOf(address(this)) - outputBefore_;
        if (amountOut_ < _minAmountOut) revert InsufficientOutput(_minAmountOut, amountOut_);

        _tokenOut.safeTransfer(msg.sender, amountOut_);
        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _amountIn, amountOut_, quoteDigest_);
    }

    /**
     * @notice Returns the adapter- and chain-bound digest signed by the API.
     * @param _tokenIn Input token authorized by the quote.
     * @param _tokenOut Output token authorized by the quote.
     * @param _amountIn Exact input authorized by the quote.
     * @param _minAmountOut Minimum output authorized by the quote.
     * @param _aggregatorId MetaSwap aggregator identifier.
     * @param _swapData Dynamic MetaSwap route bytes.
     * @param _validUntil Exclusive quote expiration.
     * @return digest_ Ethereum signed-message digest.
     */
    function getQuoteDigest(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        string calldata _aggregatorId,
        bytes calldata _swapData,
        uint64 _validUntil
    )
        public
        view
        returns (bytes32 digest_)
    {
        digest_ = keccak256(
                abi.encode(
                    address(this),
                    block.chainid,
                    _tokenIn,
                    _tokenOut,
                    _amountIn,
                    _minAmountOut,
                    keccak256(bytes(_aggregatorId)),
                    keccak256(_swapData),
                    _validUntil
                )
            ).toEthSignedMessageHash();
    }

    function _validateQuote(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        ApiQuote calldata _quote
    )
        private
        view
        returns (bytes32 digest_)
    {
        if (bytes(_quote.aggregatorId).length == 0 || _quote.validUntil == 0) revert InvalidQuote();
        if (block.timestamp >= _quote.validUntil) revert ApiQuoteExpired();
        digest_ = getQuoteDigest(
            _tokenIn, _tokenOut, _amountIn, _minAmountOut, _quote.aggregatorId, _quote.swapData, _quote.validUntil
        );
        if (ECDSA.recover(digest_, _quote.signature) != apiSigner) revert InvalidApiSignature();
    }
}
