// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title GasMeasurementContract
 * @notice Contract to measure gas consumption of HybridDeleGator.isValidSignature calls
 * @dev This contract calls isValidSignature and measures gas, emitting the results in events
 */
contract GasMeasurementContract {
    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when isValidSignature is called with gas measurement
    event GasMeasurement(
        address indexed hybridDeleGator, bytes32 indexed messageHash, bytes4 result, uint256 gasUsed, bool signatureValid
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Measures gas consumption of a single isValidSignature call
     * @param hybridDeleGator The HybridDeleGator contract to test
     * @param messageHash The message hash to verify
     * @param signature The signature to verify
     * @return result The result from isValidSignature (0x1626ba7e for valid, 0xffffffff for invalid)
     * @return gasUsed The gas consumed by the isValidSignature call
     */
    function measureGas(
        address hybridDeleGator,
        bytes32 messageHash,
        bytes calldata signature
    )
        external
        returns (bytes4 result, uint256 gasUsed)
    {
        uint256 gasBefore = gasleft();
        result = IERC1271(hybridDeleGator).isValidSignature(messageHash, signature);
        uint256 gasAfter = gasleft();

        gasUsed = gasBefore - gasAfter;

        bool signatureValid = (result == bytes4(0x1626ba7e));

        emit GasMeasurement(hybridDeleGator, messageHash, result, gasUsed, signatureValid);
    }
}

