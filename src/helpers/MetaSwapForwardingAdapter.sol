// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IMetaSwap } from "./interfaces/IMetaSwap.sol";

/**
 * @title MetaSwapForwardingAdapter
 * @notice Forwards signed MetaSwap calldata after an atomic batch prefunds this adapter.
 * @dev The companion enforcer guarantees that the preceding batch action transfers the declared input.
 *      This adapter verifies a signed parameter manifest, checks settlement, and forwards `apiData` unchanged.
 *      Address zero represents the native token.
 */
contract MetaSwapForwardingAdapter is Ownable2Step, ReentrancyGuard {
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
    error FailedNativeTokenTransfer(address recipient);
    error IdenticalTokens();
    error InsufficientOutput(uint256 minimum, uint256 received);
    error InvalidApiData();
    error InvalidApiSignature();
    error InvalidZeroAddress();
    error InvalidZeroAmount();
    error RemainingAllowance(uint256 remaining);
    error RemainingInputBalance(uint256 remaining);
    error UnexpectedInputBalance(uint256 expected, uint256 actual);

    /**
     * @notice Initializes the forwarding adapter.
     * @param _owner Owner allowed to recover accidentally sent assets.
     * @param _swapApiSigner Address authorized to sign quote manifests.
     * @param _metaSwap MetaSwap contract receiving the forwarded calldata.
     */
    constructor(address _owner, address _swapApiSigner, IMetaSwap _metaSwap) Ownable(_owner) {
        if (_swapApiSigner == address(0) || address(_metaSwap) == address(0)) revert InvalidZeroAddress();

        swapApiSigner = _swapApiSigner;
        metaSwap = _metaSwap;
    }

    /// @notice Receives prefunded native input and native swap output.
    receive() external payable { }

    /**
     * @notice Executes an API-signed MetaSwap call using input prefunded by the preceding batch action.
     * @param _tokenIn Input token, or address zero for native input.
     * @param _tokenOut Output token, or address zero for native output.
     * @param _tokenInAmount Exact prefunded input amount.
     * @param _minTokenOut Minimum output returned to the caller.
     * @param _quote Signed, expiring MetaSwap calldata and parameter manifest.
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
        nonReentrant
        returns (uint256 tokenOutAmount_)
    {
        if (_tokenInAmount == 0 || _minTokenOut == 0) revert InvalidZeroAmount();
        if (_tokenIn == _tokenOut) revert IdenticalTokens();
        if (_quote.apiData.length < 4 || bytes4(_quote.apiData[:4]) != IMetaSwap.swap.selector) revert InvalidApiData();

        bytes32 quoteDigest_ = _validateSignature(_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, _quote);

        uint256 inputBalance_ = _getSelfBalance(_tokenIn);
        if (inputBalance_ != _tokenInAmount) revert UnexpectedInputBalance(_tokenInAmount, inputBalance_);

        bool nativeInput_ = address(_tokenIn) == address(0);
        if (!nativeInput_) _tokenIn.forceApprove(address(metaSwap), _tokenInAmount);

        uint256 outputBefore_ = _getSelfBalance(_tokenOut);
        _forwardApiData(_quote.apiData, nativeInput_ ? _tokenInAmount : 0);
        _assertInputConsumed(_tokenIn, nativeInput_);

        tokenOutAmount_ = _getSelfBalance(_tokenOut) - outputBefore_;
        if (tokenOutAmount_ < _minTokenOut) revert InsufficientOutput(_minTokenOut, tokenOutAmount_);

        _sendTokens(_tokenOut, msg.sender, tokenOutAmount_);
        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _tokenInAmount, tokenOutAmount_, quoteDigest_);
    }

    /**
     * @notice Returns the Ethereum signed-message digest authorized by the API signer.
     */
    function getQuoteDigest(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        bytes calldata _apiData,
        uint256 _expiration
    )
        public
        view
        returns (bytes32 digest_)
    {
        digest_ = keccak256(
                abi.encode(block.chainid, address(this), _tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, _apiData, _expiration)
            ).toEthSignedMessageHash();
    }

    /**
     * @notice Recovers assets accidentally sent outside an atomic prefund-and-swap batch.
     * @dev Recommended delegation: owner-only recovery restricted by token, recipient, and amount.
     */
    function withdraw(IERC20 _token, address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidZeroAddress();
        _sendTokens(_token, _recipient, _amount);
        emit TokensWithdrawn(_token, _recipient, _amount);
    }

    function _validateSignature(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        ApiQuote calldata _quote
    )
        private
        view
        returns (bytes32 digest_)
    {
        if (block.timestamp >= _quote.expiration) revert ApiQuoteExpired();
        digest_ = getQuoteDigest(_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, _quote.apiData, _quote.expiration);
        if (ECDSA.recover(digest_, _quote.signature) != swapApiSigner) revert InvalidApiSignature();
    }

    function _forwardApiData(bytes calldata _apiData, uint256 _value) private {
        address metaSwap_ = address(metaSwap);
        assembly ("memory-safe") {
            let pointer_ := mload(0x40)
            calldatacopy(pointer_, _apiData.offset, _apiData.length)

            if iszero(call(gas(), metaSwap_, _value, pointer_, _apiData.length, 0, 0)) {
                let returnDataSize_ := returndatasize()
                returndatacopy(pointer_, 0, returnDataSize_)
                revert(pointer_, returnDataSize_)
            }
        }
    }

    function _assertInputConsumed(IERC20 _tokenIn, bool _nativeInput) private view {
        if (!_nativeInput) {
            uint256 remainingAllowance_ = _tokenIn.allowance(address(this), address(metaSwap));
            if (remainingAllowance_ != 0) revert RemainingAllowance(remainingAllowance_);
        }

        uint256 remainingInput_ = _getSelfBalance(_tokenIn);
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
