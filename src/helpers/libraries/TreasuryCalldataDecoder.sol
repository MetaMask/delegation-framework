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
 *      Swap inner layout matches `DelegationMetaSwapAdapter` when `swapData` is prefixed for tuple decoding.
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

    /**
     * @notice Inner swap tuple decoded from aggregator `swapData` after synthetic leading address padding.
     * @param tokenFrom Input token (must match outer `apiData` token).
     * @param tokenTo Output token reported by the quote.
     * @param amountFrom Inner amount-from field from the swap route.
     * @param amountTo Quoted amount-to / minimum out depending on adapter semantics.
     * @param metadata Opaque metadata bytes from the quote.
     * @param feeAmount Fee component when `feeTo` is false (must reconcile with outer amount when not fee-on-output).
     * @param feeWallet Fee recipient when applicable.
     * @param feeTo When true, fee accounting may bypass the strict outer amount equality check in `decodeSwapApiData`.
     */
    struct SwapInnerDecoded {
        IERC20 tokenFrom;
        IERC20 tokenTo;
        uint256 amountFrom;
        uint256 amountTo;
        bytes metadata;
        uint256 feeAmount;
        address feeWallet;
        bool feeTo;
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
     * @notice Decodes inner swap route bytes using the same synthetic leading address as `DelegationMetaSwapAdapter`.
     * @param _swapData Opaque swap blob from outer MetaSwap parameters (not including the outer selector).
     * @return inner_ Decoded inner swap fields.
     */
    function decodeSwapInner(bytes memory _swapData) internal pure returns (SwapInnerDecoded memory inner_) {
        (
            ,
            inner_.tokenFrom,
            inner_.tokenTo,
            inner_.amountFrom,
            inner_.amountTo,
            inner_.metadata,
            inner_.feeAmount,
            inner_.feeWallet,
            inner_.feeTo
        ) =
            abi.decode(
                abi.encodePacked(abi.encode(address(0)), _swapData),
                (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
            );
    }

    /**
     * @notice Decodes full MetaSwap `apiData`: selector + `(aggregatorId, tokenFrom, amountFrom, swapData)` and
     *         validates inner consistency.
     * @dev Reverts if inner `tokenFrom` mismatches outer or if fee mode requires `feeAmount + inner.amountFrom == amountFrom`.
     * @param _apiData Full bytes: `IMetaSwap.swap` selector + ABI-encoded parameters.
     * @return aggregatorId_ Aggregator identifier string.
     * @return tokenFrom_ Outer input token (must match inner).
     * @return tokenTo_ Output token taken from decoded inner route.
     * @return amountFrom_ Outer amount field used for redemption and swap call.
     * @return swapData_ Opaque inner swap bytes passed through to `metaSwap.swap`.
     */
    function decodeSwapApiData(bytes calldata _apiData)
        internal
        pure
        returns (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_)
    {
        bytes4 selector_ = bytes4(_apiData[:4]);
        if (selector_ != IMetaSwap.swap.selector) revert InvalidSwapFunctionSelector();

        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(_apiData[4:], (string, IERC20, uint256, bytes));

        SwapInnerDecoded memory inner_ = decodeSwapInner(swapData_);
        if (inner_.tokenFrom != tokenFrom_) revert TokenFromMismatch();
        if (!inner_.feeTo && (inner_.feeAmount + inner_.amountFrom != amountFrom_)) revert AmountFromMismatch();

        tokenTo_ = inner_.tokenTo;
    }
}
