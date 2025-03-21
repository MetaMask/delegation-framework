// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title DeployedEnforcer
 * @dev This contract enforces the deployment of a contract if it hasn't been deployed yet.
 * @dev This enforcer operates only in default execution mode.
 */
contract DeployedEnforcer is CaveatEnforcer {
    ////////////////////////////// Errors //////////////////////////////
    /**
     * @dev The contract deployed is empty
     */
    error DeployedEmptyContract(address contractAddress);

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when a contract is deployed
    event DeployedContract(address contractAddress);

    /// @dev Emitted if the contract was already deployed
    event SkippedDeployment(address contractAddress);

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Deploys a contract using create2
     * @param _bytecode the bytecode of the contract to deploy
     * @param _salt the salt to use for create2
     */
    function _deploy(bytes memory _bytecode, bytes32 _salt) internal returns (address addr_) {
        addr_ = Create2.deploy(0, _salt, _bytecode);
        if (addr_.code.length == 0) revert DeployedEmptyContract(addr_);
        emit DeployedContract(addr_);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to make sure the contract is deployed, and if not then deploys the contract
     * @dev This function enforces the deployment of a contract before the transaction is performed.
     * @param _terms This is packed bytes where:
     *    the first 20 bytes are the expected address of the deployed contract
     *    the next 32 bytes are the salt to use for create2
     *    the remaining bytes are the bytecode of the contract to deploy
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (address expectedAddress_, bytes32 salt_, bytes memory bytecode_) = getTermsInfo(_terms);

        // check if this contract has been deployed yet
        if (expectedAddress_.code.length > 0) {
            // if it has been deployed, then we don't need to do anything
            emit SkippedDeployment(expectedAddress_);
            return;
        }

        address deployedAddress_ = _deploy(bytecode_, salt_);
        require(deployedAddress_ == expectedAddress_, "DeployedEnforcer:deployed-address-mismatch");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return expectedAddress_ The address of the contract to deploy.
     * @return salt_ The salt to use for create2.
     * @return bytecode_ The bytecode of the contract to deploy.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (address expectedAddress_, bytes32 salt_, bytes memory bytecode_)
    {
        require(_terms.length > 52, "DeployedEnforcer:invalid-terms-length");
        expectedAddress_ = address(bytes20(_terms[:20]));
        salt_ = bytes32(_terms[20:52]);
        bytecode_ = _terms[52:];
    }

    /**
     * @dev Returns the address where a contract will be stored if deployed via {deploy}. Any change in the
     * `bytecodeHash` or `salt` will result in a new destination address.
     */
    function computeAddress(bytes32 _bytecodeHash, bytes32 _salt) external view returns (address addr_) {
        return Create2.computeAddress(_salt, _bytecodeHash);
    }
}
