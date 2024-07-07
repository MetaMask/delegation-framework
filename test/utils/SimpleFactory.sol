// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

contract SimpleFactory {
    ////////////////////////////// Events //////////////////////////////

    event Deployed(address indexed addr);

    ////////////////////////////// Custom Errors //////////////////////////////

    /**
     * @dev The contract deployed is empty
     */
    error SimpleFactoryEmptyContract(address deployed);

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Deploys a contract using create2
     * @param _bytecode the bytecode of the contract to deploy
     * @param _salt the salt to use for create2
     */
    function deploy(bytes memory _bytecode, bytes32 _salt) external returns (address addr_) {
        addr_ = Create2.deploy(0, _salt, _bytecode);
        if (addr_.code.length == 0) revert SimpleFactoryEmptyContract(addr_);
        emit Deployed(addr_);
    }

    /**
     * @dev Returns the address where a contract will be stored if deployed via {deploy}. Any change in the
     * `bytecodeHash` or `salt` will result in a new destination address.
     */
    function computeAddress(bytes32 _bytecodeHash, bytes32 _salt) external view returns (address addr_) {
        return Create2.computeAddress(_salt, _bytecodeHash);
    }
}
