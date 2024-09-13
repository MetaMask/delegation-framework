// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { DelegationManager } from "../src/DelegationManager.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

import { AllowedCalldataEnforcer } from "../src/enforcers/AllowedCalldataEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { BlockNumberEnforcer } from "../src/enforcers/BlockNumberEnforcer.sol";
import { DeployedEnforcer } from "../src/enforcers/DeployedEnforcer.sol";
import { ERC20BalanceGteEnforcer } from "../src/enforcers/ERC20BalanceGteEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { IdEnforcer } from "../src/enforcers/IdEnforcer.sol";
import { LimitedCallsEnforcer } from "../src/enforcers/LimitedCallsEnforcer.sol";
import { NonceEnforcer } from "../src/enforcers/NonceEnforcer.sol";
import { TimestampEnforcer } from "../src/enforcers/TimestampEnforcer.sol";
import { ValueLteEnforcer } from "../src/enforcers/ValueLteEnforcer.sol";
import { NativeBalanceGteEnforcer } from "../src/enforcers/NativeBalanceGteEnforcer.sol";
import { NativeTokenPaymentEnforcer } from "../src/enforcers/NativeTokenPaymentEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../src/enforcers/ArgsEqualityCheckEnforcer.sol";

/**
 * @title DeployEnvironmentSetUp
 * @notice Deploys the required contracts for the delegation system to function.
 * interacting with a chain where the required contracts have already been deployed.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev run the script with:
 * forge script script/DeployEnvironmentSetUp.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployEnvironmentSetUp is Script {
    bytes32 salt;
    IEntryPoint entryPoint;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        entryPoint = IEntryPoint(vm.envAddress("ENTRYPOINT_ADDRESS"));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Entry Point: %s", address(entryPoint));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress;

        // Deploy Delegation Environment Contracts
        address delegationManager = address(new DelegationManager{ salt: salt }(deployer));
        console2.log("DelegationManager: %s", address(delegationManager));
        deployedAddress = address(new MultiSigDeleGator{ salt: salt }(IDelegationManager(delegationManager), entryPoint));
        console2.log("MultiSigDeleGatorImpl: %s", deployedAddress);

        deployedAddress = address(new HybridDeleGator{ salt: salt }(IDelegationManager(delegationManager), entryPoint));
        console2.log("HybridDeleGatorImpl: %s", address(deployedAddress));
        console2.log("~~~");

        // Caveat Enforcers
        deployedAddress = address(new AllowedCalldataEnforcer{ salt: salt }());
        console2.log("AllowedCalldataEnforcer: %s", deployedAddress);

        deployedAddress = address(new AllowedMethodsEnforcer{ salt: salt }());
        console2.log("AllowedMethodsEnforcer: %s", deployedAddress);

        deployedAddress = address(new AllowedTargetsEnforcer{ salt: salt }());
        console2.log("AllowedTargetsEnforcer: %s", deployedAddress);

        deployedAddress = address(new BlockNumberEnforcer{ salt: salt }());
        console2.log("BlockNumberEnforcer: %s", deployedAddress);

        deployedAddress = address(new DeployedEnforcer{ salt: salt }());
        console2.log("DeployedEnforcer: %s", deployedAddress);

        deployedAddress = address(new ERC20BalanceGteEnforcer{ salt: salt }());
        console2.log("ERC20BalanceGteEnforcer: %s", deployedAddress);

        deployedAddress = address(new ERC20TransferAmountEnforcer{ salt: salt }());
        console2.log("ERC20TransferAmountEnforcer: %s", deployedAddress);

        deployedAddress = address(new IdEnforcer{ salt: salt }());
        console2.log("IdEnforcer: %s", deployedAddress);

        deployedAddress = address(new LimitedCallsEnforcer{ salt: salt }());
        console2.log("LimitedCallsEnforcer: %s", deployedAddress);

        deployedAddress = address(new NonceEnforcer{ salt: salt }());
        console2.log("NonceEnforcer: %s", deployedAddress);

        deployedAddress = address(new TimestampEnforcer{ salt: salt }());
        console2.log("TimestampEnforcer: %s", deployedAddress);

        deployedAddress = address(new ValueLteEnforcer{ salt: salt }());
        console2.log("ValueLteEnforcer: %s", deployedAddress);

        deployedAddress = address(new NativeTokenTransferAmountEnforcer{ salt: salt }());
        console2.log("NativeTokenTransferAmountEnforcer: %s", deployedAddress);

        deployedAddress = address(new NativeBalanceGteEnforcer{ salt: salt }());
        console2.log("NativeBalanceGteEnforcer: %s", deployedAddress);

        deployedAddress = address(new ArgsEqualityCheckEnforcer{ salt: salt }());
        console2.log("ArgsEqualityCheckEnforcer: %s", deployedAddress);

        deployedAddress =
            address(new NativeTokenPaymentEnforcer{ salt: salt }(IDelegationManager(delegationManager), deployedAddress));
        console2.log("NativeTokenPaymentEnforcer: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
