// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TreasuryCalldataDecoder } from "./libraries/TreasuryCalldataDecoder.sol";

/**
 * @title BridgeDecoder
 * @notice External wrapper around `TreasuryCalldataDecoder` for Foundry tests and off-chain calldata inspection.
 * @dev Prefer calling the library from Solidity when compiling production code without this indirection.
 */
contract BridgeDecoder {
    /**
     * @notice Decodes `IMetaBridge.bridge`-style calldata into adapter id, token, amount, and inner opaque bytes.
     * @param _fullCalldata Full calldata including the 4-byte function selector.
     * @return adapterId_ Bridge adapter identifier from the outer ABI tuple.
     * @return tokenFrom_ Source token as `IERC20`.
     * @return amountFrom_ Outer amount field.
     * @return bridgeData_ Inner payload passed through to the bridge / adapter.
     */
    function decodeOuterBridgeCalldata(bytes calldata _fullCalldata)
        external
        pure
        returns (string memory adapterId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory bridgeData_)
    {
        return TreasuryCalldataDecoder.decodeOuterBridgeCalldata(_fullCalldata);
    }

    /**
     * @notice Decodes the bridge adapter tail struct after synthetic `address(0)` destination-wallet prefix handling.
     * @param _tailAfterDestWalletPlaceholder ABI-encoded tail following the placeholder destination-wallet word.
     * @return decoded_ Structured bridge fields including destination chain and tokens.
     */
    function decodeBridgeAdapterTail(bytes memory _tailAfterDestWalletPlaceholder)
        external
        pure
        returns (TreasuryCalldataDecoder.BridgeAdapterDecoded memory decoded_)
    {
        return TreasuryCalldataDecoder.decodeBridgeAdapterTail(_tailAfterDestWalletPlaceholder);
    }
}
