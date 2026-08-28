// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";
import { IMetaSwap } from "./interfaces/IMetaSwap.sol";

/**
 * @title MetaSwapDelegationAdapter
 * @notice Executes signed MetaSwap routes using input redeemed from a delegation chain.
 * @dev The leaf delegation must delegate to this adapter. The adapter redeems exactly `_tokenInAmount`
 *      from the root delegator and always sends swap output back to that root delegator. Address zero
 *      represents the native token.
 */
contract MetaSwapDelegationAdapter is Ownable2Step, ReentrancyGuard {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    struct ApiQuote {
        bytes apiData;
        uint256 expiration;
        bytes signature;
    }

    /// @notice Delegation manager used to redeem swap input.
    IDelegationManager public immutable delegationManager;
    /// @notice MetaSwap contract used to execute routes.
    IMetaSwap public immutable metaSwap;
    /// @notice Address authorized to sign API quotes.
    address public immutable swapApiSigner;

    /// @notice Emitted after a delegated swap pays its root delegator.
    event SwapExecuted(
        address indexed executor,
        address indexed recipient,
        IERC20 indexed tokenIn,
        IERC20 tokenOut,
        uint256 tokenInAmount,
        uint256 tokenOutAmount,
        bytes32 quoteDigest
    );
    /// @notice Emitted when the owner recovers an asset.
    event TokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    error ApiQuoteExpired();
    error AmountInMismatch();
    error FailedNativeTokenTransfer(address recipient);
    error IdenticalTokens();
    error IncorrectInputReceived(uint256 expected, uint256 received);
    error InsufficientOutput(uint256 minimum, uint256 received);
    error InvalidApiData();
    error InvalidApiSignature();
    error InvalidDelegationsLength();
    error InvalidZeroAddress();
    error InvalidZeroAmount();
    error RemainingAllowance(uint256 remaining);
    error RemainingInputBalance(uint256 remaining);
    error TokenInMismatch();
    error TokenOutMismatch();

    /**
     * @notice Initializes the adapter.
     * @param _owner Owner allowed to recover accidentally sent assets.
     * @param _swapApiSigner Address authorized to sign MetaSwap API quotes.
     * @param _delegationManager Delegation manager used to redeem input assets.
     * @param _metaSwap MetaSwap contract used to execute swaps.
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
    }

    /**
     * @notice Allows the adapter to receive redeemed native input and native swap output.
     */
    receive() external payable { }

    /**
     * @notice Redeems input from a delegation, executes a signed route, and pays the root delegator.
     * @dev Requires a chain of at least two delegations, ordered leaf to root. This enforces the
     *      user-to-operator-to-adapter pattern used by VedaAdapter. The delegation caveats should
     *      restrict the transfer asset, amount, and redeemer.
     * @param _delegations Delegation chain ordered leaf to root.
     * @param _tokenIn Input token, or address zero for native input.
     * @param _tokenOut Output token, or address zero for native output.
     * @param _tokenInAmount Exact amount redeemed and swapped.
     * @param _minTokenOut Minimum output paid to the root delegator.
     * @param _quote Signed, expiring MetaSwap API calldata.
     * @return tokenOutAmount_ Actual output paid to the root delegator.
     */
    function swap(
        Delegation[] calldata _delegations,
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
        uint256 delegationsLength_ = _delegations.length;
        if (delegationsLength_ < 2) revert InvalidDelegationsLength();
        if (_tokenInAmount == 0 || _minTokenOut == 0) revert InvalidZeroAmount();
        if (_tokenIn == _tokenOut) revert IdenticalTokens();

        bytes32 quoteDigest_ = _validateSignature(_quote, _minTokenOut);
        (string memory aggregatorId_, bytes memory swapData_) =
            _decodeApiData(_quote.apiData, _tokenIn, _tokenOut, _tokenInAmount, _minTokenOut);

        tokenOutAmount_ = _redeemAndSwap(_delegations, _tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, aggregatorId_, swapData_);

        address recipient_ = _delegations[delegationsLength_ - 1].delegator;
        _sendTokens(_tokenOut, recipient_, tokenOutAmount_);

        emit SwapExecuted(msg.sender, recipient_, _tokenIn, _tokenOut, _tokenInAmount, tokenOutAmount_, quoteDigest_);
    }

    function _redeemAndSwap(
        Delegation[] calldata _delegations,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        string memory _aggregatorId,
        bytes memory _swapData
    )
        private
        returns (uint256 tokenOutAmount_)
    {
        uint256 inputBefore_ = _getSelfBalance(_tokenIn);
        uint256 outputBefore_ = _getSelfBalance(_tokenOut);
        _redeemInput(_delegations, _tokenIn, _tokenInAmount);

        uint256 inputReceived_ = _getSelfBalance(_tokenIn) - inputBefore_;
        if (inputReceived_ != _tokenInAmount) revert IncorrectInputReceived(_tokenInAmount, inputReceived_);

        bool nativeInput_ = address(_tokenIn) == address(0);
        if (!nativeInput_) _tokenIn.forceApprove(address(metaSwap), _tokenInAmount);

        metaSwap.swap{ value: nativeInput_ ? _tokenInAmount : 0 }(_aggregatorId, _tokenIn, _tokenInAmount, _swapData);
        _assertInputConsumed(_tokenIn, inputBefore_, nativeInput_);

        tokenOutAmount_ = _getSelfBalance(_tokenOut) - outputBefore_;
        if (tokenOutAmount_ < _minTokenOut) revert InsufficientOutput(_minTokenOut, tokenOutAmount_);
    }

    /**
     * @notice Returns the eth-signed digest authorized by the API signer.
     * @param _apiData Encoded MetaSwap call.
     * @param _expiration Quote expiration timestamp.
     * @param _minTokenOut Minimum output authorized by the signer.
     * @return digest_ Ethereum signed-message digest for the quote.
     */
    function getQuoteDigest(
        bytes calldata _apiData,
        uint256 _expiration,
        uint256 _minTokenOut
    )
        public
        pure
        returns (bytes32 digest_)
    {
        digest_ = keccak256(abi.encode(_apiData, _expiration, _minTokenOut)).toEthSignedMessageHash();
    }

    /**
     * @notice Recovers assets accidentally sent to the adapter.
     * @dev Recommended delegation: owner-only recovery restricted by token, recipient, and amount.
     * @param _token Token to recover, or address zero for native tokens.
     * @param _recipient Address receiving the recovered assets.
     * @param _amount Amount to recover.
     */
    function withdraw(IERC20 _token, address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidZeroAddress();
        _sendTokens(_token, _recipient, _amount);
        emit TokensWithdrawn(_token, _recipient, _amount);
    }

    function _redeemInput(Delegation[] calldata _delegations, IERC20 _token, uint256 _amount) private {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        if (address(_token) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), _amount, hex"");
        } else {
            executionCallDatas_[0] =
                ExecutionLib.encodeSingle(address(_token), 0, abi.encodeCall(IERC20.transfer, (address(this), _amount)));
        }

        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
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

    function _validateSignature(ApiQuote calldata _quote, uint256 _minTokenOut) private view returns (bytes32 messageHash_) {
        if (block.timestamp >= _quote.expiration) revert ApiQuoteExpired();
        messageHash_ = keccak256(abi.encode(_quote.apiData, _quote.expiration, _minTokenOut));
        if (ECDSA.recover(messageHash_.toEthSignedMessageHash(), _quote.signature) != swapApiSigner) {
            revert InvalidApiSignature();
        }
    }

    function _assertInputConsumed(IERC20 _tokenIn, uint256 _inputBefore, bool _nativeInput) private view {
        if (!_nativeInput) {
            uint256 remainingAllowance_ = _tokenIn.allowance(address(this), address(metaSwap));
            if (remainingAllowance_ != 0) revert RemainingAllowance(remainingAllowance_);
        }

        uint256 remainingInput_ = _getSelfBalance(_tokenIn) - _inputBefore;
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
