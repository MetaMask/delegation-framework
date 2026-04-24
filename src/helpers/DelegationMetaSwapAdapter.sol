// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { IMetaSwap } from "./interfaces/IMetaSwap.sol";
import { IDeleGatorModule } from "./interfaces/IDeleGatorModule.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";

/**
 * @title DelegationMetaSwapAdapter
 * @notice Acts as a middleman to orchestrate token swaps using delegations and an aggregator (MetaSwap).
 * @dev The delegator creates a single delegation directly to this adapter. No redelegation is required.
 *      Swaps are gated by per-(tokenFrom, tokenTo) policies managed by the owner via `setPairLimits`.
 *      A pair must be `enabled` for the swap to proceed; the policy also caps the API-reported
 *      slippage and price impact for that pair.
 *      The delegation itself should include period-based transfer enforcers (ERC20PeriodTransferEnforcer or
 *      NativeTokenPeriodTransferEnforcer) plus a RedeemerEnforcer to restrict who can redeem.
 *
 * @dev This adapter is intended to be used with the Swaps API. Accordingly, all API requests must include a valid
 *      signature that incorporates an expiration timestamp, the API-reported slippage, and price impact for the swap.
 *      The signature is verified during swap execution to ensure that it is still valid and has not been tampered with.
 *      Slippage and price impact are both signed (`int256`): positive means unfavorable to the user (executed worse
 *      than quote) and is bounded by the pair's cap; negative or zero means favorable and is always allowed
 *      regardless of cap.
 *
 * @dev The root delegator is expected to be a Safe Module DeleGator. The recipient of the swapped tokens is resolved
 *      by calling `IDeleGatorModule(rootDelegator).safe()`. If that call fails, the swap reverts.
 */
contract DelegationMetaSwapAdapter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @notice Data required to authorize a swap via the Swaps API.
     * @param apiData Encoded swap parameters consumed by the aggregator.
     * @param expiration Unix timestamp after which the signature is invalid.
     * @param slippage API-reported slippage for this swap (1e18 = 1%, 100e18 = 100%). SIGNED: positive =
     *                 unfavorable to user; negative = favorable. The cap only applies to the unfavorable
     *                 (positive) direction; favorable values pass regardless of cap.
     * @param priceImpact API-reported price impact for this swap (1e18 = 1%, 100e18 = 100%). SIGNED, same
     *                    convention as `slippage` above.
     * @param signature ECDSA signature over keccak256(abi.encode(apiData, expiration, slippage, priceImpact)).
     */
    struct SignatureData {
        bytes apiData;
        uint256 expiration;
        int256 slippage;
        int256 priceImpact;
        bytes signature;
    }

    /**
     * @notice Per-pair admin policy used to gate swaps.
     * @dev Packed into 2 storage slots: (uint128, uint128) + bool. `uint128` comfortably holds values up
     *      to MAX_PERCENT (100e18 = 1e20).
     * @param maxSlippage    Per-pair max signed slippage    (1e18 = 1%, max 100e18).
     * @param maxPriceImpact Per-pair max signed price impact (1e18 = 1%, max 100e18).
     * @param enabled        When false, the pair is disabled and `swapByDelegation` reverts.
     */
    struct PairLimit {
        uint128 maxSlippage;
        uint128 maxPriceImpact;
        bool enabled;
    }

    /**
     * @notice Single-element input for `setPairLimits` batch admin call.
     * @dev Composes `PairLimit` so the policy fields stay in one place.
     */
    struct PairLimitInput {
        IERC20 tokenFrom;
        IERC20 tokenTo;
        PairLimit limit;
    }

    ////////////////////////////// Constants //////////////////////////////

    /// @dev 100% in 18-decimal fixed point. Slippage and price impact format: 1e18 = 1%, 100e18 = 100%.
    uint256 public constant MAX_PERCENT = 100e18;

    ////////////////////////////// State //////////////////////////////

    /// @dev The DelegationManager contract that has root access to this contract
    IDelegationManager public immutable delegationManager;

    /// @dev The MetaSwap contract used to swap tokens
    IMetaSwap public immutable metaSwap;

    /// @dev The chain's WETH9 address. Treated as equivalent to `address(0)` for pairLimits lookup
    IERC20 public immutable weth;

    /// @dev Address of the API signer account.
    address public swapApiSigner;

    /// @dev Indicates if a caller is allowed to invoke swapByDelegation.
    mapping(address caller => bool allowed) public isCallerAllowed;

    /// @dev Per-(tokenFrom, tokenTo) policy: max slippage, max price impact, and an `enabled` flag that
    ///      doubles as the pair allow-list. A pair with `enabled == false` causes `swapByDelegation` to revert.
    /// @dev Native token (and WETH, treated as native for limits) lives under the canonical key `address(0)`.
    ///      Read via the public `getPairLimit(tokenFrom, tokenTo)` getter, which normalizes WETH internally.
    mapping(IERC20 tokenFrom => mapping(IERC20 tokenTo => PairLimit)) private pairLimits;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the DelegationManager contract address is set.
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    /// @dev Emitted when the MetaSwap contract address is set.
    event SetMetaSwap(IMetaSwap indexed newMetaSwap);

    /// @dev Emitted when the contract sends tokens (or native tokens) to a recipient.
    event SentTokens(IERC20 indexed token, address indexed recipient, uint256 amount);

    /// @dev Emitted when the allowed caller status changes.
    event ChangedCallerStatus(address indexed caller, bool indexed status);

    /// @dev Emitted when the Signer API is updated.
    event SwapApiSignerUpdated(address indexed newSigner);

    /// @dev Emitted when a (tokenFrom, tokenTo) pair policy is set.
    event PairLimitSet(IERC20 indexed tokenFrom, IERC20 indexed tokenTo, uint128 maxSlippage, uint128 maxPriceImpact, bool enabled);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when the input and output tokens are the same.
    error InvalidIdenticalTokens();

    /// @dev Error thrown when delegations input is an empty array.
    error InvalidEmptyDelegations();

    /// @dev Error while transferring the native token to the recipient.
    error FailedNativeTokenTransfer(address recipient);

    /// @dev Error when the (tokenFrom, tokenTo) pair is not enabled (or never configured).
    error PairDisabled(IERC20 tokenFrom, IERC20 tokenTo);

    /// @dev Error when the input arrays of a function have different lengths.
    error InputLengthsMismatch();

    /// @dev Error when the contract did not receive exactly `_amountFrom` of `tokenFrom` after the
    ///      delegation redemption (covers both "less than" and "more than" cases).
    error UnexpectedTokenFromAmount(uint256 expected, uint256 obtained);

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

    /// @dev Error thrown when a percent value exceeds MAX_PERCENT (100e18).
    error InvalidPercent(uint256 percent);

    /// @dev Error thrown when the signed (unfavorable) slippage exceeds the admin cap for the swap
    ///      pair. Only fired when `signedSlippage > 0` AND its magnitude exceeds the cap.
    error SlippageExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, int256 signedSlippage, uint256 cap);

    /// @dev Error thrown when the signed (unfavorable) price impact exceeds the admin cap for the swap
    ///      pair. Only fired when `signedPriceImpact > 0` AND its magnitude exceeds the cap.
    error PriceImpactExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, int256 signedPriceImpact, uint256 cap);

    /// @dev Error thrown when the root delegator does not implement IDeleGatorModule.safe() correctly.
    error RecipientResolutionFailed(address rootDelegator);

    ////////////////////////////// Modifiers //////////////////////////////

    /**
     * @dev Require the caller to be in the allowed callers whitelist.
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
     * @param _weth The chain's WETH9 address. Used only to alias WETH to `address(0)` (native) when
     *              looking up pair policies; pick the correct WETH address for the target chain.
     */
    constructor(
        address _owner,
        address _swapApiSigner,
        IDelegationManager _delegationManager,
        IMetaSwap _metaSwap,
        IERC20 _weth
    )
        Ownable(_owner)
    {
        if (
            _swapApiSigner == address(0) || address(_delegationManager) == address(0) || address(_metaSwap) == address(0)
                || address(_weth) == address(0)
        ) {
            revert InvalidZeroAddress();
        }

        swapApiSigner = _swapApiSigner;
        delegationManager = _delegationManager;
        metaSwap = _metaSwap;
        weth = _weth;
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
     * @notice Executes a token swap using a delegation and transfers the swapped tokens to the Safe of the root delegator.
     * @dev The delegation chain goes directly from the delegator to this adapter (no redelegation needed).
     *      The delegation should include period-based transfer enforcers and a RedeemerEnforcer.
     *      The signature must cover apiData, expiration, slippage, and priceImpact.
     *      The (tokenFrom, tokenTo) pair must be `enabled` in `pairLimits`; slippage and priceImpact are
     *      validated against the pair's caps.
     *      The recipient is resolved via IDeleGatorModule(rootDelegator).safe().
     * @param _signatureData Includes apiData, expiration, slippage, priceImpact, and signature.
     * @param _delegations Array of Delegation objects containing delegation-specific data, sorted leaf to root.
     */
    function swapByDelegation(
        SignatureData calldata _signatureData,
        Delegation[] calldata _delegations
    )
        external
        onlyAllowedCaller
        nonReentrant
    {
        uint256 delegationsLength_ = _delegations.length;
        if (delegationsLength_ == 0) revert InvalidEmptyDelegations();

        _validateSignature(_signatureData);

        (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_) =
            _decodeApiData(_signatureData.apiData);

        // Identical-token pairs would revert in `setPairLimits`
        _validatePairPolicy(tokenFrom_, tokenTo_, _signatureData.slippage, _signatureData.priceImpact);

        address recipient_ = _resolveRecipient(_delegations[delegationsLength_ - 1].delegator);

        uint256 balanceFromBefore_ = _getSelfBalance(tokenFrom_);

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
     * @param _token The token to be withdrawn (use `address(0)` for the chain's native token).
     * @param _amount The amount of tokens (or native) to withdraw.
     * @param _recipient The address to receive the withdrawn tokens.
     */
    function withdraw(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        _sendTokens(_token, _amount, _recipient);
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

        for (uint256 i = 0; i < callersLength_;) {
            address caller_ = _callers[i];
            bool status_ = _statuses[i];
            if (isCallerAllowed[caller_] != status_) {
                isCallerAllowed[caller_] = status_;
                emit ChangedCallerStatus(caller_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Sets per-(tokenFrom, tokenTo) pair policies in a single batch call.
     * @dev Only callable by the contract owner. Format: 1e18 = 1%, 100e18 = 100%; values must be <= MAX_PERCENT.
     *      `enabled == false` disables the pair (any future swap reverts with `PairDisabled`).
     *      Identical-token pairs (`tokenFrom == tokenTo`) are rejected at config time.
     * @param _inputs Array of pair configurations.
     */
    function setPairLimits(PairLimitInput[] calldata _inputs) external onlyOwner {
        uint256 length_ = _inputs.length;
        for (uint256 i = 0; i < length_;) {
            PairLimitInput calldata in_ = _inputs[i];

            IERC20 tokenFrom_ = _canonNative(in_.tokenFrom);
            IERC20 tokenTo_ = _canonNative(in_.tokenTo);
            if (tokenFrom_ == tokenTo_) revert InvalidIdenticalTokens();
            if (uint256(in_.limit.maxSlippage) > MAX_PERCENT) revert InvalidPercent(in_.limit.maxSlippage);
            if (uint256(in_.limit.maxPriceImpact) > MAX_PERCENT) revert InvalidPercent(in_.limit.maxPriceImpact);

            pairLimits[tokenFrom_][tokenTo_] = in_.limit;
            emit PairLimitSet(tokenFrom_, tokenTo_, in_.limit.maxSlippage, in_.limit.maxPriceImpact, in_.limit.enabled);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns the pair policy for `(_tokenFrom, _tokenTo)`. WETH is treated as `address(0)`
     *         (native) for the lookup so configuring one set of caps covers ETH and WETH together.
     * @dev Also used internally by `_validatePairPolicy` so the WETH-as-native aliasing is enforced
     *      in exactly one place.
     * @param _tokenFrom Input token. Pass either `address(0)` or `weth`; both resolve to the same entry.
     * @param _tokenTo Output token. Same WETH-aliasing rule applies.
     * @return The stored `PairLimit` for the canonical pair, or a zero-default if not configured.
     */
    function getPairLimit(IERC20 _tokenFrom, IERC20 _tokenTo) public view returns (PairLimit memory) {
        return pairLimits[_canonNative(_tokenFrom)][_canonNative(_tokenTo)];
    }

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @dev Validates the expiration and signature of the provided signature data.
     *      The signed payload is keccak256(abi.encode(apiData, expiration, slippage, priceImpact)).
     */
    function _validateSignature(SignatureData calldata _signatureData) internal view {
        if (block.timestamp >= _signatureData.expiration) revert SignatureExpired();

        bytes32 messageHash_ = keccak256(
            abi.encode(_signatureData.apiData, _signatureData.expiration, _signatureData.slippage, _signatureData.priceImpact)
        );
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);

        address recoveredSigner_ = ECDSA.recover(ethSignedMessageHash_, _signatureData.signature);
        if (recoveredSigner_ != swapApiSigner) revert InvalidApiSignature();
    }

    /**
     * @dev Validates that the (tokenFrom, tokenTo) pair is enabled and that the signed slippage and
     *      price impact are within the pair's caps.
     * @dev Both slippage and price impact are signed (`int256`). The cap only applies to the
     *      **unfavorable** direction (positive values). Negative or zero values (favorable to the user)
     *      pass regardless of cap.
     */
    function _validatePairPolicy(
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        int256 _signedSlippage,
        int256 _signedPriceImpact
    )
        private
        view
    {
        PairLimit memory limit_ = getPairLimit(_tokenFrom, _tokenTo);
        if (!limit_.enabled) revert PairDisabled(_tokenFrom, _tokenTo);
        // Cap-check only positive (unfavorable) values. Casts are safe because each check is gated on `> 0`.
        if (_signedSlippage > 0 && uint256(_signedSlippage) > limit_.maxSlippage) {
            revert SlippageExceedsCap(_tokenFrom, _tokenTo, _signedSlippage, limit_.maxSlippage);
        }
        if (_signedPriceImpact > 0 && uint256(_signedPriceImpact) > limit_.maxPriceImpact) {
            revert PriceImpactExceedsCap(_tokenFrom, _tokenTo, _signedPriceImpact, limit_.maxPriceImpact);
        }
    }

    /**
     * @dev Resolves the swap recipient by calling IDeleGatorModule(_rootDelegator).safe().
     *      Reverts with RecipientResolutionFailed if the call fails or returns the zero address.
     */
    function _resolveRecipient(address _rootDelegator) private view returns (address recipient_) {
        try IDeleGatorModule(_rootDelegator).safe() returns (address safe_) {
            if (safe_ == address(0)) revert RecipientResolutionFailed(_rootDelegator);
            recipient_ = safe_;
        } catch {
            revert RecipientResolutionFailed(_rootDelegator);
        }
    }

    /**
     * @notice Sends tokens or native token to a specified recipient.
     * @param _token ERC20 token to send. Use `address(0)` for the chain's native token.
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
     * @dev Executes the token swap via the MetaSwap contract and sends the output tokens to the recipient.
     *      Verifies the actual tokens received by comparing balances before and after the delegation redemption.
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
        if (tokenFromObtained_ != _amountFrom) revert UnexpectedTokenFromAmount(_amountFrom, tokenFromObtained_);

        uint256 value_;
        if (address(_tokenFrom) == address(0)) {
            value_ = _amountFrom;
        } else {
            uint256 allowance_ = _tokenFrom.allowance(address(this), address(metaSwap));
            if (allowance_ < _amountFrom) {
                _tokenFrom.forceApprove(address(metaSwap), type(uint256).max);
            }
        }

        uint256 balanceToBefore_ = _getSelfBalance(_tokenTo);

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
     * @dev Returns this contract's balance of the specified token. When `_token` is `address(0)`
     *      returns the contract's native (ETH) balance instead of an ERC20 `balanceOf` call.
     */
    function _getSelfBalance(IERC20 _token) private view returns (uint256 balance_) {
        if (address(_token) == address(0)) return address(this).balance;

        return _token.balanceOf(address(this));
    }

    /**
     * @dev Returns `address(0)` if `_token` is `weth`, otherwise returns `_token` unchanged. Used
     *      exclusively to alias WETH to native for `pairLimits` reads/writes — it does NOT change how
     *      the contract physically moves tokens (WETH still uses ERC20 `transferFrom` / `transfer`).
     */
    function _canonNative(IERC20 _token) private view returns (IERC20) {
        return _token == weth ? IERC20(address(0)) : _token;
    }
}
