// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { LiFiSwapQuoteLib } from "../libraries/LiFiSwapQuoteLib.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title LiFiSwapEnforcer
 * @notice Enforces periodic LiFi swap/bridge delegations backed by signed quotes from a trusted quote signer.
 * @dev Validates calldata via keccak256 hash binding, slippage bounds, and optional same-chain EVM output balance checks.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev Terms are validated before the quote signature is trusted, so a delegation with a zero quoteSigner cannot be
 *      satisfied by a malformed signature (ecrecover returns address(0)).
 * @custom:assumptions
 *      - `msg.sender` is expected to be the DelegationManager. Enforcer state (period budget, afterHook context) is
 *        namespaced by `msg.sender`, so a direct external call only pollutes the caller's own namespace and cannot
 *        affect a real delegation's storage (consistent with `ERC20PeriodTransferEnforcer`).
 *      - `DelegationManager.redeemDelegations` has no `nonReentrant` guard; the `balanceOf` call in
 *        `_prepareAfterHookContext` is therefore a reentrancy surface. Impact is bounded: the period budget is already
 *        consumed before the call, and the afterHook context is not yet written, so a reentrant `afterHook` no-ops.
 *        The user-pinned `outputAssetId` must nonetheless be a trusted ERC20, or `bytes32(0)` for native ETH (verified
 *        via `address.balance` in the afterHook).
 *      - `inputToken == address(0)` is a valid native ETH sentinel; the execution must carry `value == inputAmount`.
 */
contract LiFiSwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using LiFiSwapQuoteLib for LiFiSwapQuoteLib.Terms;
    using LiFiSwapQuoteLib for LiFiSwapQuoteLib.SignedLiFiQuote;

    // GenericSwapFacetV3 selectors (same-chain EVM swaps). Hardcoded (not .selector) because the
    // enforcer is standalone and does not import the lifinance/contracts repo.
    bytes4 private constant SEL_GENERIC_SINGLE_ERC20_ERC20 = 0x4666fc80;
    bytes4 private constant SEL_GENERIC_SINGLE_ERC20_NATIVE = 0x733214a3;
    bytes4 private constant SEL_GENERIC_SINGLE_NATIVE_ERC20 = 0xaf7060fd;
    bytes4 private constant SEL_GENERIC_MULTI_ERC20_NATIVE = 0x2c57e884;
    bytes4 private constant SEL_GENERIC_MULTI_ERC20_ERC20 = 0x5fd9ae2e;
    bytes4 private constant SEL_GENERIC_MULTI_NATIVE_ERC20 = 0x736eac0b;

    // NEARIntentsFacet selectors (EVM -> BTC).
    bytes4 private constant SEL_NEAR_START = 0x5cf8113b;
    bytes4 private constant SEL_NEAR_SWAP = 0x3110c7b9;

    // LayerSwapFacet selectors (EVM -> BTC).
    bytes4 private constant SEL_LAYERSWAP_START = 0xee9e98e0;
    bytes4 private constant SEL_LAYERSWAP_SWAP = 0x4c279d6b;

    struct PeriodicAllowance {
        uint256 periodAmount;
        uint256 periodDuration;
        uint256 startDate;
        uint256 lastTransferPeriod;
        uint256 transferredInCurrentPeriod;
    }

    struct AfterHookContext {
        bool enabled;
        address outputToken;
        address recipient;
        uint256 minAmountOut;
        uint256 balanceBefore;
    }

    mapping(address delegationManager => mapping(bytes32 delegationHash => PeriodicAllowance)) public periodicAllowances;

    mapping(bytes32 contextKey => AfterHookContext context) public afterHookContexts;

    event SwappedInPeriod(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        address inputToken,
        uint256 periodAmount,
        uint256 periodDuration,
        uint256 startDate,
        uint256 transferredInCurrentPeriod,
        uint256 swapTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager,
        bytes calldata _terms
    )
        external
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        LiFiSwapQuoteLib.Terms memory terms_ = LiFiSwapQuoteLib.decodeTerms(_terms);
        PeriodicAllowance memory storedAllowance_ = periodicAllowances[_delegationManager][_delegationHash];

        if (storedAllowance_.startDate != 0) {
            return _getAvailableAmount(storedAllowance_);
        }

        PeriodicAllowance memory allowance_ = PeriodicAllowance({
            periodAmount: terms_.periodAmount,
            periodDuration: terms_.periodDuration,
            startDate: terms_.startDate,
            lastTransferPeriod: 0,
            transferredInCurrentPeriod: 0
        });
        return _getAvailableAmount(allowance_);
    }

    /**
     * @notice Hook called before a LiFi swap/bridge execution.
     * @dev Validates terms (zero/range checks) BEFORE trusting the quote signature, then verifies the signature
     *      (which now binds `delegationHash` + `chainId`), calldata hash, quote↔terms match, slippage, and period budget.
     * @dev `msg.sender` is expected to be the DelegationManager; see contract-level assumptions.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        LiFiSwapQuoteLib.Terms memory terms_ = LiFiSwapQuoteLib.decodeTerms(_terms);
        _validateTerms(terms_);

        (LiFiSwapQuoteLib.RouteKind routeKind_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_, bytes memory signature_) =
            _decodeArgs(_args);

        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(target_ == terms_.lifiDiamond, "LiFiSwapEnforcer:invalid-target");
        // Native ETH input (inputToken == address(0)) requires value == inputAmount; ERC20 input requires value == 0.
        if (terms_.inputToken == address(0)) {
            require(value_ == quote_.inputAmount, "LiFiSwapEnforcer:invalid-native-value");
        } else {
            require(value_ == 0, "LiFiSwapEnforcer:invalid-value");
        }
        require(callData_.length >= 4, "LiFiSwapEnforcer:invalid-calldata-length");
        require(block.timestamp < quote_.expiration, "LiFiSwapEnforcer:quote-expired");
        require(
            LiFiSwapQuoteLib.recoverQuoteSigner(quote_, _delegationHash, signature_) == terms_.quoteSigner,
            "LiFiSwapEnforcer:invalid-quote-signature"
        );
        require(keccak256(callData_) == quote_.calldataHash, "LiFiSwapEnforcer:calldata-hash-mismatch");

        _validateQuoteMatchesTerms(quote_, terms_, _delegator);
        require(
            LiFiSwapQuoteLib.minAmountOutMeetsSlippage(
                quote_.minAmountOut, quote_.expectedAmountOut, terms_.slippageBps
            ),
            "LiFiSwapEnforcer:slippage-exceeded"
        );

        // Decode the LiFi calldata and assert destination chain + recipient match terms. Runs after the
        // quote<->terms metadata checks so those cheaper mismatches surface first.
        _verifyCalldataMatchesTerms(terms_, routeKind_, callData_);

        _validateAndConsumePeriod(terms_, quote_.inputAmount, _delegationHash, _redeemer);

        _prepareAfterHookContext(terms_, quote_, _delegationHash);
    }

    /**
     * @notice Hook called after a LiFi swap/bridge execution.
     * @dev For same-chain EVM recipients/assets, verifies the output token balance increased by `quote.minAmountOut`.
     *      For cross-chain or non-EVM recipients, `beforeHook` does not set a context and this hook silently no-ops —
     *      destination delivery cannot be proven on the source chain. The silent no-op is intentional.
     */
    function afterHook(
        bytes calldata /* _terms */,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        bytes32 contextKey_ = _getContextKey(_delegationHash);
        AfterHookContext memory context_ = afterHookContexts[contextKey_];

        if (!context_.enabled) {
            return;
        }

        delete afterHookContexts[contextKey_];

        uint256 balanceAfter_ = context_.outputToken == address(0)
            ? context_.recipient.balance
            : IERC20(context_.outputToken).balanceOf(context_.recipient);
        require(
            balanceAfter_ >= context_.balanceBefore + context_.minAmountOut,
            "LiFiSwapEnforcer:insufficient-output-received"
        );
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _decodeArgs(bytes calldata _args)
        private
        pure
        returns (
            LiFiSwapQuoteLib.RouteKind routeKind_,
            LiFiSwapQuoteLib.SignedLiFiQuote memory quote_,
            bytes memory signature_
        )
    {
        (routeKind_, quote_, signature_) =
            abi.decode(_args, (LiFiSwapQuoteLib.RouteKind, LiFiSwapQuoteLib.SignedLiFiQuote, bytes));
    }

    function _validateQuoteMatchesTerms(
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        LiFiSwapQuoteLib.Terms memory _terms,
        address _delegator
    )
        private
        pure
    {
        require(_quote.delegator == _delegator, "LiFiSwapEnforcer:invalid-delegator");
        require(_quote.lifiDiamond == _terms.lifiDiamond, "LiFiSwapEnforcer:invalid-diamond");
        require(_quote.inputToken == _terms.inputToken, "LiFiSwapEnforcer:invalid-input-token");
        require(_quote.outputAssetId == _terms.outputAssetId, "LiFiSwapEnforcer:invalid-output-asset");
        require(_quote.outputRecipient == _terms.outputRecipient, "LiFiSwapEnforcer:invalid-output-recipient");
        require(_quote.destinationChainId == _terms.destinationChainId, "LiFiSwapEnforcer:invalid-destination-chain");
    }

    function _validateTerms(LiFiSwapQuoteLib.Terms memory _terms) private pure {
        require(_terms.lifiDiamond != address(0), "LiFiSwapEnforcer:invalid-zero-diamond");
        // address(0) for inputToken and bytes32(0) for outputAssetId are valid native ETH sentinels.
        require(_terms.quoteSigner != address(0), "LiFiSwapEnforcer:invalid-zero-quote-signer");
        require(_terms.outputRecipient != bytes32(0), "LiFiSwapEnforcer:invalid-zero-output-recipient");
        require(_terms.destinationChainId != 0, "LiFiSwapEnforcer:invalid-zero-destination-chain");
        require(_terms.periodAmount > 0, "LiFiSwapEnforcer:invalid-zero-period-amount");
        require(_terms.periodDuration > 0, "LiFiSwapEnforcer:invalid-zero-period-duration");
        require(_terms.startDate > 0, "LiFiSwapEnforcer:invalid-zero-start-date");
        require(_terms.slippageBps < LiFiSwapQuoteLib.BPS_DENOMINATOR, "LiFiSwapEnforcer:invalid-slippage-bps");
    }

    function _validateAndConsumePeriod(
        LiFiSwapQuoteLib.Terms memory _terms,
        uint256 _inputAmount,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        require(_inputAmount > 0, "LiFiSwapEnforcer:invalid-zero-input-amount");

        PeriodicAllowance storage allowance_ = periodicAllowances[msg.sender][_delegationHash];

        if (allowance_.startDate == 0) {
            require(block.timestamp >= _terms.startDate, "LiFiSwapEnforcer:swap-not-started");

            allowance_.periodAmount = _terms.periodAmount;
            allowance_.periodDuration = _terms.periodDuration;
            allowance_.startDate = _terms.startDate;
        }

        (uint256 available_, bool isNewPeriod_, uint256 currentPeriod_) = _getAvailableAmount(allowance_);

        require(_inputAmount <= available_, "LiFiSwapEnforcer:period-amount-exceeded");

        if (isNewPeriod_) {
            allowance_.lastTransferPeriod = currentPeriod_;
            allowance_.transferredInCurrentPeriod = 0;
        }

        allowance_.transferredInCurrentPeriod += _inputAmount;

        emit SwappedInPeriod(
            msg.sender,
            _redeemer,
            _delegationHash,
            _terms.inputToken,
            _terms.periodAmount,
            _terms.periodDuration,
            _terms.startDate,
            allowance_.transferredInCurrentPeriod,
            block.timestamp
        );
    }

    /**
     * @notice Caches the recipient's output-token balance for the `afterHook` check, when on-chain verification applies.
     * @dev Makes an external `balanceOf` call to the user-pinned `outputAssetId`. This is a reentrancy surface; see the
     *      contract-level assumptions. The context is written only after the external call returns.
     */
    function _prepareAfterHookContext(
        LiFiSwapQuoteLib.Terms memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes32 _delegationHash
    )
        private
    {
        bytes32 contextKey_ = _getContextKey(_delegationHash);
        delete afterHookContexts[contextKey_];

        if (!LiFiSwapQuoteLib.shouldVerifyOutputOnChain(_terms.destinationChainId, _terms.outputRecipient, _terms.outputAssetId))
        {
            return;
        }

        bool isNative_ = LiFiSwapQuoteLib.isNativeAsset(_terms.outputAssetId);
        address outputToken_ = isNative_ ? address(0) : LiFiSwapQuoteLib.toEvmAddress(_terms.outputAssetId);
        address recipient_ = LiFiSwapQuoteLib.toEvmAddress(_terms.outputRecipient);

        uint256 balanceBefore_ = isNative_
            ? recipient_.balance
            : IERC20(outputToken_).balanceOf(recipient_);

        afterHookContexts[contextKey_] = AfterHookContext({
            enabled: true,
            outputToken: outputToken_,
            recipient: recipient_,
            minAmountOut: _quote.minAmountOut,
            balanceBefore: balanceBefore_
        });
    }

    function _getAvailableAmount(PeriodicAllowance memory _allowance)
        internal
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        if (block.timestamp < _allowance.startDate) {
            return (0, false, 0);
        }

        currentPeriod_ = (block.timestamp - _allowance.startDate) / _allowance.periodDuration + 1;

        isNewPeriod_ = (_allowance.lastTransferPeriod != currentPeriod_);

        uint256 alreadyTransferred_ = isNewPeriod_ ? 0 : _allowance.transferredInCurrentPeriod;

        availableAmount_ = _allowance.periodAmount > alreadyTransferred_
            ? _allowance.periodAmount - alreadyTransferred_
            : 0;
    }

    function _getContextKey(bytes32 _delegationHash) private view returns (bytes32) {
        return keccak256(abi.encode(msg.sender, _delegationHash));
    }

    ////////////////////////////// Calldata Verification //////////////////////////////

    /// @notice Decodes the LiFi execution calldata and asserts destination chain + recipient match `terms`.
    /// @dev `routeKind_` is provided in `_args` (not signed by the quote signer), so it is untrusted: each
    ///      branch cross-checks it against the calldata selector and `terms` shape before decoding. A lying
    ///      enum reverts rather than picking a weak decode path. No hardcoded chain IDs / token addresses.
    function _verifyCalldataMatchesTerms(
        LiFiSwapQuoteLib.Terms memory _terms,
        LiFiSwapQuoteLib.RouteKind _routeKind,
        bytes calldata _callData
    ) private view {
        require(_callData.length >= 4, "LiFiSwapEnforcer:calldata-too-short");
        bytes4 selector_ = bytes4(_callData[:4]);

        if (_routeKind == LiFiSwapQuoteLib.RouteKind.SameChain) {
            _verifySameChain(_terms, selector_, _callData);
        } else if (_routeKind == LiFiSwapQuoteLib.RouteKind.EvmBridge) {
            _verifyEvmBridge(_terms, _callData);
        } else if (_routeKind == LiFiSwapQuoteLib.RouteKind.NearBtc) {
            _verifyNonEvmBtc(_terms, selector_, _callData, 0x00); // NEAR: nonEVMReceiver is 1st field
        } else if (_routeKind == LiFiSwapQuoteLib.RouteKind.LayerSwapBtc) {
            _verifyNonEvmBtc(_terms, selector_, _callData, 0x60); // LayerSwap: nonEVMReceiver is 4th field
        } else {
            revert("LiFiSwapEnforcer:unsupported-route");
        }
    }

    /// @dev Same-chain EVM swap via GenericSwapFacetV3. No BridgeData; destination chain is not in calldata,
    ///      so it is asserted via `terms.destinationChainId == block.chainid`. `_receiver` is the 4th param
    ///      head at calldata offset 0x64 (4-byte selector + 0x60).
    function _verifySameChain(
        LiFiSwapQuoteLib.Terms memory _terms,
        bytes4 _selector,
        bytes calldata _callData
    ) private view {
        require(_terms.destinationChainId == block.chainid, "LiFiSwapEnforcer:route-dest-chain-mismatch");
        require(LiFiSwapQuoteLib.isCleanEvmAddress(_terms.outputRecipient), "LiFiSwapEnforcer:route-recipient-shape-mismatch");
        require(_isGenericSwapSelector(_selector), "LiFiSwapEnforcer:route-selector-mismatch");

        address receiver_ = address(uint160(uint256(_readWord(_callData, 0x64))));
        require(receiver_ == LiFiSwapQuoteLib.toEvmAddress(_terms.outputRecipient), "LiFiSwapEnforcer:calldata-recipient-mismatch");
    }

    /// @dev EVM-to-EVM bridge. Selector-agnostic: decode `ILiFi.BridgeData` (receiver @ +0xA0, destChain @ +0xE0).
    ///      Reject the non-EVM sentinel so a non-EVM bridge cannot slip through the EVM decode path.
    function _verifyEvmBridge(LiFiSwapQuoteLib.Terms memory _terms, bytes calldata _callData) private view {
        require(_terms.destinationChainId != block.chainid, "LiFiSwapEnforcer:route-dest-chain-mismatch");
        require(LiFiSwapQuoteLib.isCleanEvmAddress(_terms.outputRecipient), "LiFiSwapEnforcer:route-recipient-shape-mismatch");

        uint256 bd_ = _bridgeDataBody(_callData);
        address receiver_ = address(uint160(uint256(_readWord(_callData, bd_ + 0xA0))));
        require(receiver_ != LiFiSwapQuoteLib.NON_EVM_ADDRESS, "LiFiSwapEnforcer:non-evm-sentinel-receiver");
        require(receiver_ == LiFiSwapQuoteLib.toEvmAddress(_terms.outputRecipient), "LiFiSwapEnforcer:calldata-recipient-mismatch");

        uint256 destChain_ = uint256(_readWord(_callData, bd_ + 0xE0));
        require(destChain_ == _terms.destinationChainId, "LiFiSwapEnforcer:calldata-dest-chain-mismatch");
    }

    /// @dev EVM-to-BTC via a bridge whose bridge-specific struct carries `nonEVMReceiver`. `nonEvmFieldOff_`
    ///      is the offset of `nonEVMReceiver` within that struct (0x00 for NEAR, 0x60 for LayerSwap).
    function _verifyNonEvmBtc(
        LiFiSwapQuoteLib.Terms memory _terms,
        bytes4 _selector,
        bytes calldata _callData,
        uint256 nonEvmFieldOff_
    ) private view {
        require(_terms.destinationChainId != block.chainid, "LiFiSwapEnforcer:route-dest-chain-mismatch");
        require(!LiFiSwapQuoteLib.isCleanEvmAddress(_terms.outputRecipient), "LiFiSwapEnforcer:route-recipient-shape-mismatch");

        bool isNear_ = nonEvmFieldOff_ == 0x00;
        bool isLayerSwap_ = nonEvmFieldOff_ == 0x60;
        if (isNear_) {
            require(_selector == SEL_NEAR_START || _selector == SEL_NEAR_SWAP, "LiFiSwapEnforcer:route-selector-mismatch");
        } else if (isLayerSwap_) {
            require(
                _selector == SEL_LAYERSWAP_START || _selector == SEL_LAYERSWAP_SWAP,
                "LiFiSwapEnforcer:route-selector-mismatch"
            );
        } else {
            revert("LiFiSwapEnforcer:unsupported-route");
        }

        (uint256 bd_, uint256 structBody_) = _bridgeSpecificStructBody(_callData);
        bytes32 nonEvmReceiver_ = _readWord(_callData, structBody_ + nonEvmFieldOff_);
        require(nonEvmReceiver_ == _terms.outputRecipient, "LiFiSwapEnforcer:calldata-recipient-mismatch");

        uint256 destChain_ = uint256(_readWord(_callData, bd_ + 0xE0));
        require(destChain_ == _terms.destinationChainId, "LiFiSwapEnforcer:calldata-dest-chain-mismatch");
    }

    /// @dev Returns the absolute offset of the `ILiFi.BridgeData` body within `_callData`. The body sits
    ///      behind the head offset stored in `param[0]` (calldata word at offset 0x04).
    function _bridgeDataBody(bytes calldata _callData) private pure returns (uint256 bd_) {
        uint256 bdOff_ = uint256(_readWord(_callData, 0x04));
        bd_ = 0x04 + bdOff_;
    }

    /// @dev Returns (bridgeData body absolute, bridge-specific struct body absolute). The bridge-specific
    ///      struct sits behind a head offset in `param[1]` (calldata 0x44) when there are no source swaps,
    ///      or `param[2]` (calldata 0x64) when `BridgeData.hasSourceSwaps` (read @ +0x100) is true.
    function _bridgeSpecificStructBody(bytes calldata _callData)
        private
        pure
        returns (uint256 bd_, uint256 structBody_)
    {
        bd_ = _bridgeDataBody(_callData);
        bool hasSourceSwaps_ = uint256(_readWord(_callData, bd_ + 0x100)) != 0;
        // Head slot holding the bridge-specific struct offset: param[1] @ calldata 0x24 (no source swaps,
        // 2 params) or param[2] @ calldata 0x44 (with source swaps, 3 params). Note these are bytes-calldata
        // offsets (no length prefix); the equivalent bytes-memory offsets in CalldataVerificationFacet
        // are 0x44 / 0x64 because bytes memory carries a 0x20 length prefix.
        uint256 headSlotAbs_ = hasSourceSwaps_ ? 0x44 : 0x24;
        uint256 structOff_ = uint256(_readWord(_callData, headSlotAbs_));
        structBody_ = 0x04 + structOff_;
    }

    function _isGenericSwapSelector(bytes4 _selector) private pure returns (bool) {
        return _selector == SEL_GENERIC_SINGLE_ERC20_ERC20 || _selector == SEL_GENERIC_SINGLE_ERC20_NATIVE
            || _selector == SEL_GENERIC_SINGLE_NATIVE_ERC20 || _selector == SEL_GENERIC_MULTI_ERC20_NATIVE
            || _selector == SEL_GENERIC_MULTI_ERC20_ERC20 || _selector == SEL_GENERIC_MULTI_NATIVE_ERC20;
    }

    /// @dev Reads a 32-byte word at `_offset` in `_data` with a bounds check that avoids overflow on
    ///      attacker-controlled offsets (subtraction-based guard, mirroring CalldataVerificationFacet).
    function _readWord(bytes calldata _data, uint256 _offset) private pure returns (bytes32 word_) {
        require(_data.length >= 32 && _offset <= _data.length - 32, "LiFiSwapEnforcer:calldata-too-short");
        word_ = bytes32(_data[_offset:_offset + 32]);
    }
}
