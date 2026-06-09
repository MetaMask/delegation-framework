// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IDeleGatorBatchRelayCoordinator } from "./interfaces/IDeleGatorBatchRelayCoordinator.sol";
import { IEIP7702BatchDeleGator } from "./interfaces/IEIP7702BatchDeleGator.sol";

/**
 * @title DeleGatorBatchRelayCoordinator
 * @notice Owner-gated multi-account coordinator for signed batch DeleGator relay execution.
 * @dev Non-atomic by default: a failed account row is recorded and later rows still execute.
 * @dev Does not forward ETH and does not authorize child account execution by itself.
 */
contract DeleGatorBatchRelayCoordinator is Ownable, IDeleGatorBatchRelayCoordinator {
    uint256 internal constant MAX_REVERT_DATA = 256;

    /// @dev Emitted for each coordinator row after execution attempt.
    event BatchRowExecuted(uint256 indexed index, address indexed account, bool success, bytes revertData);

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @inheritdoc IDeleGatorBatchRelayCoordinator
    function executeBatches(AccountBatch[] calldata batches) external onlyOwner {
        uint256 len = batches.length;
        for (uint256 i = 0; i < len;) {
            AccountBatch calldata batch = batches[i];

            (bool success, bytes memory revertData) = address(batch.account).call(
                abi.encodeWithSelector(IEIP7702BatchDeleGator.executeBatch.selector, batch.mode, batch.executionData)
            );

            if (!success && revertData.length > MAX_REVERT_DATA) {
                revertData = abi.encodePacked(keccak256(revertData));
            }

            emit BatchRowExecuted(i, batch.account, success, success ? bytes("") : revertData);

            unchecked {
                ++i;
            }
        }
    }
}
