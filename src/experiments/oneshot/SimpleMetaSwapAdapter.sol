// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IMetaSwap } from "../../helpers/interfaces/IMetaSwap.sol";

/**
 * @title SimpleMetaSwapAdapter
 * @notice Minimal adapter for delegation-driven limit orders.
 * @dev A batch first transfers `_tokenInAmount` to this adapter, then calls {swap}.
 *      The API signs only route data; token addresses, input, and minimum output are
 *      separate function arguments bound by {MetaSwapLimitOrderEnforcer}.
 */
contract SimpleMetaSwapAdapter {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    struct ApiQuote {
        bytes apiData;
        uint256 expiration;
        bytes signature;
    }

    IMetaSwap public immutable metaSwap;
    address public immutable apiSigner;
    mapping(bytes32 quoteDigest => bool used) public usedQuotes;

    error ApiQuoteExpired();
    error IdenticalTokens();
    error InsufficientInputBalance(uint256 required, uint256 available);
    error InsufficientOutput(uint256 required, uint256 received);
    error InvalidApiSignature();
    error InvalidApiData();
    error ApiQuoteAlreadyUsed();
    error InvalidZeroAddress();

    constructor(IMetaSwap _metaSwap, address _apiSigner) {
        if (address(_metaSwap) == address(0) || _apiSigner == address(0)) revert InvalidZeroAddress();
        metaSwap = _metaSwap;
        apiSigner = _apiSigner;
    }

    /**
     * @notice Executes a signed MetaSwap route using tokens transferred earlier in the same delegated batch.
     * @param _tokenIn User-signed input token.
     * @param _tokenOut User-signed output token.
     * @param _tokenInAmount Exact user-signed input amount.
     * @param _minTokenOut Minimum acceptable output; receiving more is allowed.
     * @param _quote Short-lived route payload signed by `apiSigner`.
     * @return tokenOutAmount_ Actual output returned to the caller.
     */
    function swap(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        ApiQuote calldata _quote
    )
        external
        returns (uint256 tokenOutAmount_)
    {
        if (address(_tokenIn) == address(0) || address(_tokenOut) == address(0)) revert InvalidZeroAddress();
        if (_tokenIn == _tokenOut) revert IdenticalTokens();
        if (block.timestamp >= _quote.expiration) revert ApiQuoteExpired();
        bytes32 quoteDigest_ = getQuoteDigest(_quote.apiData, _quote.expiration);
        if (ECDSA.recover(quoteDigest_, _quote.signature) != apiSigner) {
            revert InvalidApiSignature();
        }
        if (usedQuotes[quoteDigest_]) revert ApiQuoteAlreadyUsed();
        usedQuotes[quoteDigest_] = true;

        uint256 inputBalance_ = _tokenIn.balanceOf(address(this));
        if (inputBalance_ < _tokenInAmount) revert InsufficientInputBalance(_tokenInAmount, inputBalance_);

        (string memory aggregatorId_, bytes memory swapData_) = abi.decode(_quote.apiData, (string, bytes));
        if (bytes(aggregatorId_).length == 0) revert InvalidApiData();

        uint256 outputBefore_ = _tokenOut.balanceOf(address(this));
        _tokenIn.forceApprove(address(metaSwap), _tokenInAmount);
        metaSwap.swap(aggregatorId_, _tokenIn, _tokenInAmount, swapData_);
        _tokenIn.forceApprove(address(metaSwap), 0);

        tokenOutAmount_ = _tokenOut.balanceOf(address(this)) - outputBefore_;
        if (tokenOutAmount_ < _minTokenOut) revert InsufficientOutput(_minTokenOut, tokenOutAmount_);
        _tokenOut.safeTransfer(msg.sender, tokenOutAmount_);

        // The enforcer proves an exact transfer immediately before this call. Return
        // at most that operation's unused input; never intentionally retain order funds.
        uint256 unusedInput_ = _tokenIn.balanceOf(address(this));
        if (unusedInput_ > _tokenInAmount) unusedInput_ = _tokenInAmount;
        if (unusedInput_ > 0) _tokenIn.safeTransfer(msg.sender, unusedInput_);
    }

    /**
     * @notice Returns the adapter- and chain-bound digest the API signer authorizes.
     */
    function getQuoteDigest(bytes calldata _apiData, uint256 _expiration) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, keccak256(_apiData), _expiration)).toEthSignedMessageHash();
    }
}
