// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMetaBridge } from "../interfaces/IMetaBridge.sol";
import { IMetaSwap } from "../interfaces/IMetaSwap.sol";

/**
 * @title TreasuryCalldataDecoder
 * @notice Pure decode helpers for MetaSwap and MetaBridge style `apiData` blobs consumed by `TreasuryManager`.
 * @dev Bridge inner layout matches on-chain adapter decoding when prefixed with a synthetic destination-wallet
 *      field (`destWalletAddress` slot set to `address(0)`).
 *      MetaSwap `decodeSwapApiData` mirrors `DelegationMetaSwapAdapterOriginal._decodeApiData` verbatim.
 *      (outer from `apiData[4:]`, then `abi.encodePacked(abi.encode(address(0)), swapData_)` for the inner 9-tuple).
 */
library TreasuryCalldataDecoder {
    /**
     * @notice Bridge adapter payload embedded in MetaBridge opaque bytes (after outer `IMetaBridge.bridge` decode).
     * @dev ABI layout must stay aligned with legacy adapter structs; field names reflect `tokenFrom` / `tokenTo` vocabulary.
     * @param destWalletAddress Placeholder slot; always `address(0)` when produced by `decodeBridgeAdapterTail`. Intentionally
     *                          ignored by `TreasuryManager` — the API-signed `destWalletAddress` is the sole source of truth.
     * @param aggregator Bridge / liquidity aggregator contract address for the inner call path.
     * @param spender Address approved to pull source tokens when executing the bridge step.
     * @param destinationChainId Target chain identifier for policy checks.
     * @param tokenFrom Source-chain token address expected by the adapter.
     * @param tokenTo Destination token address for policy checks on the treasury side.
     * @param amountFrom Source amount field inside adapter data (may differ from outer fee-inclusive amount).
     * @param aggregatorCalldata Encoded inner call for the aggregator.
     * @param fee Optional fee term from the bridge quote.
     * @param feeWallet Optional fee recipient from the bridge quote.
     */
    struct BridgeAdapterDecoded {
        address destWalletAddress;
        address aggregator;
        address spender;
        uint256 destinationChainId;
        address tokenFrom;
        address tokenTo;
        uint256 amountFrom;
        bytes aggregatorCalldata;
        uint256 fee;
        address feeWallet;
    }

    error AmountFromMismatch();
    error InvalidBridgeFunctionSelector();
    error InvalidSwapFunctionSelector();
    error TokenFromMismatch();

    /**
     * @notice Decodes outer `apiData` for `IMetaBridge.bridge(adapterId, srcToken, amount, data)`.
     * @param _apiData Full bytes: 4-byte selector + ABI body
     *                 `(string adapterId, address srcToken, uint256 amount, bytes bridgeInnerData)`.
     * @return adapterId_ Relay / adapter identifier string.
     * @return tokenFrom_ Source token as `IERC20` (from address field).
     * @return amountFrom_ Outer amount field from the API payload.
     * @return bridgeInnerData_ Opaque bytes forwarded as MetaBridge `data` / inner adapter tail input.
     */
    function decodeOuterBridgeCalldata(bytes calldata _apiData)
        internal
        pure
        returns (string memory adapterId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory bridgeInnerData_)
    {
        bytes4 selector_ = bytes4(_apiData[:4]);
        if (selector_ != IMetaBridge.bridge.selector) revert InvalidBridgeFunctionSelector();

        address tokenAddr_;
        (adapterId_, tokenAddr_, amountFrom_, bridgeInnerData_) = abi.decode(_apiData[4:], (string, address, uint256, bytes));
        tokenFrom_ = IERC20(tokenAddr_);
    }

    /**
     * @notice Decodes full MetaBridge `apiData`: selector + outer fields + adapter tail, and validates inner consistency.
     * @dev Reverts if outer `tokenFrom` differs from inner `tokenFrom`, or if `inner.amountFrom + inner.fee` does not
     *      equal `outer.amountFrom`.
     * @param _apiData Full bytes: `IMetaBridge.bridge` selector + ABI-encoded parameters.
     * @return adapterId_ Bridge adapter identifier string.
     * @return tokenFrom_ Outer source token (must match inner).
     * @return amountFrom_ Outer source amount; equals `inner.amountFrom + inner.fee`.
     * @return bridgeInnerData_ Opaque bytes forwarded to `metaBridge.bridge`.
     * @return inner_ Decoded adapter struct (destination wallet, chain id, tokens, fee, etc.).
     */
    function decodeBridgeApiData(bytes calldata _apiData)
        internal
        pure
        returns (
            string memory adapterId_,
            IERC20 tokenFrom_,
            uint256 amountFrom_,
            bytes memory bridgeInnerData_,
            BridgeAdapterDecoded memory inner_
        )
    {
        (adapterId_, tokenFrom_, amountFrom_, bridgeInnerData_) = decodeOuterBridgeCalldata(_apiData);
        inner_ = decodeBridgeAdapterTail(bridgeInnerData_);
        if (address(tokenFrom_) != inner_.tokenFrom) revert TokenFromMismatch();
        if (inner_.amountFrom + inner_.fee != amountFrom_) revert AmountFromMismatch();
    }

    /**
     * @notice Decodes the adapter tail when struct-encoded with a leading placeholder `destWalletAddress` of `address(0)`.
     * @param _tailAfterDestWalletPlaceholder ABI-encoded tail matching `BridgeAdapterDecoded` without the first word
     *        (destination wallet supplied as prefix).
     * @return decoded_ Fully populated bridge adapter struct.
     */
    function decodeBridgeAdapterTail(bytes memory _tailAfterDestWalletPlaceholder)
        internal
        pure
        returns (BridgeAdapterDecoded memory decoded_)
    {
        decoded_ = abi.decode(bytes.concat(abi.encode(address(0)), _tailAfterDestWalletPlaceholder), (BridgeAdapterDecoded));
    }

    /**
     * @notice Decodes full MetaSwap `apiData` (same as `DelegationMetaSwapAdapterOriginal._decodeApiData`).
     * @param _apiData Full bytes: `IMetaSwap.swap` selector + ABI-encoded parameters.
     * @return aggregatorId_ Aggregator identifier string.
     * @return tokenFrom_ Outer input token (must match inner).
     * @return tokenTo_ Output token from decoded inner route.
     * @return amountFrom_ Outer amount field used for redemption and swap call.
     * @return swapData_ Inner swap bytes passed through to `metaSwap.swap`.
     */
    function decodeSwapApiData(bytes calldata _apiData)
        internal
        pure
        returns (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_)
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
            uint256 swapAmountFrom_,, // AmountTo
            , // Metadata
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
    }
}
