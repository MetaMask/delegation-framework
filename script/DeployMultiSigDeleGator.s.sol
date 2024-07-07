// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";

/**
 * @title DeployMultiSigDeleGator
 * @notice Deploying a DeleGator account requires the deployment of the set up contracts. Ensure you've run `DeploySetUp` or are
 * interacting with a chain where the required contracts have already been deployed.
 * @notice This script will deploy a MultiSigDeleGator with a threshold of 1 and the owner as the wallet from the PRIVATE_KEY
 * environment variable.
 * @dev run the script with `forge script script/DeployMultiSigDeleGator.s.sol --ffi --rpc-url <your_rpc_url>`
 */
contract DeployMultiSigDeleGator is Script {
    bytes32 salt;
    MultiSigDeleGator multiSigDeleGatorImplementation;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        multiSigDeleGatorImplementation = MultiSigDeleGator(payable(vm.envAddress("MULTISIG_DELEGATOR_IMPLEMENTATION_ADDRESS")));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("DeleGator Implementation: %s", address(multiSigDeleGatorImplementation));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address[] memory signers_ = new address[](1);
        signers_[0] = msg.sender;
        uint256 threshold = 1;

        address multiSigDeleGator_ = address(
            new ERC1967Proxy(
                address(multiSigDeleGatorImplementation),
                abi.encodeWithSelector(MultiSigDeleGator.initialize.selector, signers_, threshold)
            )
        );
        console2.log("MultiSigDeleGator: %s", address(multiSigDeleGator_));

        vm.stopBroadcast();
    }
}
