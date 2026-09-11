// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LiFiSwapQuoteLib
 * @notice Shared types and helpers for LiFi signed-quote swap delegations.
 */
library LiFiSwapQuoteLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant TERMS_LENGTH = 284;

    /// @notice Sentinel address LiFi places in `BridgeData.receiver` for non-EVM destinations.
    /// @dev Mirrors `LiFiData.NON_EVM_ADDRESS` from the lifinance/contracts repo without importing it,
    ///      so the enforcer stays standalone and chain-agnostic. The value fits in 160 bits, so
    ///      `isCleanEvmAddress` returns true for it — callers must reject it explicitly for EVM routes.
    address internal constant NON_EVM_ADDRESS = 0x11f111f111f111F111f111f111F111f111f111F1;

    /// @notice Selects the calldata decode path in `LiFiSwapEnforcer.beforeHook`.
    /// @dev Provided in `_args` (not signed by the quote signer); cross-checked against the calldata
    ///      selector and `terms` shape before its decode path runs, so a lying enum reverts.
    enum RouteKind {
        SameChain, // GenericSwap facet, same-chain EVM swap (no BridgeData)
        EvmBridge, // EVM-to-EVM bridge using ILiFi.BridgeData layout
        NearBtc, // EVM-to-BTC via NEAR Intents (nonEVMReceiver is 1st struct field)
        LayerSwapBtc // EVM-to-BTC via LayerSwap (nonEVMReceiver is 4th struct field @ +0x60)
    }

    struct Terms {
        address lifiDiamond;
        address inputToken;
        bytes32 outputAssetId;
        bytes32 outputRecipient;
        uint256 destinationChainId;
        address quoteSigner;
        uint256 periodAmount;
        uint256 periodDuration;
        uint256 startDate;
        uint256 slippageBps;
    }

    struct SignedLiFiQuote {
        address delegator;
        address lifiDiamond;
        address inputToken;
        bytes32 outputAssetId;
        bytes32 outputRecipient;
        uint256 destinationChainId;
        uint256 inputAmount;
        uint256 expectedAmountOut;
        uint256 minAmountOut;
        bytes32 calldataHash;
        uint256 expiration;
    }

    function encodeTerms(Terms memory _terms) internal pure returns (bytes memory terms_) {
        terms_ = abi.encodePacked(
            _terms.lifiDiamond,
            _terms.inputToken,
            _terms.outputAssetId,
            _terms.outputRecipient,
            _terms.destinationChainId,
            _terms.quoteSigner,
            _terms.periodAmount,
            _terms.periodDuration,
            _terms.startDate,
            _terms.slippageBps
        );
    }

    function decodeTerms(bytes calldata _terms) internal pure returns (Terms memory terms_) {
        require(_terms.length == TERMS_LENGTH, "LiFiSwapQuoteLib:invalid-terms-length");

        terms_.lifiDiamond = address(bytes20(_terms[0:20]));
        terms_.inputToken = address(bytes20(_terms[20:40]));
        terms_.outputAssetId = bytes32(_terms[40:72]);
        terms_.outputRecipient = bytes32(_terms[72:104]);
        terms_.destinationChainId = uint256(bytes32(_terms[104:136]));
        terms_.quoteSigner = address(bytes20(_terms[136:156]));
        terms_.periodAmount = uint256(bytes32(_terms[156:188]));
        terms_.periodDuration = uint256(bytes32(_terms[188:220]));
        terms_.startDate = uint256(bytes32(_terms[220:252]));
        terms_.slippageBps = uint256(bytes32(_terms[252:284]));
    }

    function hashQuote(SignedLiFiQuote memory _quote, bytes32 _delegationHash) internal view returns (bytes32) {
        return keccak256(abi.encode(_quote, _quote.expiration, _delegationHash, block.chainid));
    }

    function recoverQuoteSigner(
        SignedLiFiQuote memory _quote,
        bytes32 _delegationHash,
        bytes memory _signature
    )
        internal
        view
        returns (address)
    {
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(hashQuote(_quote, _delegationHash));
        return ECDSA.recover(ethSignedMessageHash_, _signature);
    }

    function minAmountOutMeetsSlippage(
        uint256 _minAmountOut,
        uint256 _expectedAmountOut,
        uint256 _slippageBps
    )
        internal
        pure
        returns (bool)
    {
        if (_expectedAmountOut == 0) {
            return false;
        }

        uint256 minimumAllowed_ =
            Math.mulDiv(_expectedAmountOut, BPS_DENOMINATOR - _slippageBps, BPS_DENOMINATOR);
        return _minAmountOut >= minimumAllowed_;
    }

    function isCleanEvmAddress(bytes32 _value) internal pure returns (bool) {
        return _value != bytes32(0) && uint256(_value) >> 160 == 0;
    }

    function toEvmAddress(bytes32 _value) internal pure returns (address) {
        return address(uint160(uint256(_value)));
    }

    /// @notice Returns true if `outputAssetId` is the native ETH sentinel (bytes32(0)).
    function isNativeAsset(bytes32 _outputAssetId) internal pure returns (bool) {
        return _outputAssetId == bytes32(0);
    }

    function shouldVerifyOutputOnChain(
        uint256 _destinationChainId,
        bytes32 _outputRecipient,
        bytes32 _outputAssetId
    )
        internal
        view
        returns (bool)
    {
        return _destinationChainId == block.chainid && isCleanEvmAddress(_outputRecipient)
            && (_outputAssetId == bytes32(0) || isCleanEvmAddress(_outputAssetId));
    }
}
