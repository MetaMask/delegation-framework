// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

import { AllowedCalldataEnforcer } from "../src/enforcers/AllowedCalldataEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { BlockNumberEnforcer } from "../src/enforcers/BlockNumberEnforcer.sol";
import { DeployedEnforcer } from "../src/enforcers/DeployedEnforcer.sol";
import { ERC20BalanceGteEnforcer } from "../src/enforcers/ERC20BalanceGteEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { ERC20StreamingEnforcer } from "../src/enforcers/ERC20StreamingEnforcer.sol";
import { ERC20PeriodTransferEnforcer } from "../src/enforcers/ERC20PeriodTransferEnforcer.sol";
import { ERC721BalanceGteEnforcer } from "../src/enforcers/ERC721BalanceGteEnforcer.sol";
import { ERC721TransferEnforcer } from "../src/enforcers/ERC721TransferEnforcer.sol";
import { ERC1155BalanceGteEnforcer } from "../src/enforcers/ERC1155BalanceGteEnforcer.sol";
import { ExactCalldataEnforcer } from "../src/enforcers/ExactCalldataEnforcer.sol";
import { ExactExecutionBatchEnforcer } from "../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { ExactExecutionEnforcer } from "../src/enforcers/ExactExecutionEnforcer.sol";
import { IdEnforcer } from "../src/enforcers/IdEnforcer.sol";
import { LimitedCallsEnforcer } from "../src/enforcers/LimitedCallsEnforcer.sol";
import { MultiTokenPeriodEnforcer } from "../src/enforcers/MultiTokenPeriodEnforcer.sol";
import { NativeBalanceGteEnforcer } from "../src/enforcers/NativeBalanceGteEnforcer.sol";
import { NativeTokenPaymentEnforcer } from "../src/enforcers/NativeTokenPaymentEnforcer.sol";
import { NativeTokenPeriodTransferEnforcer } from "../src/enforcers/NativeTokenPeriodTransferEnforcer.sol";
import { NativeTokenStreamingEnforcer } from "../src/enforcers/NativeTokenStreamingEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { NonceEnforcer } from "../src/enforcers/NonceEnforcer.sol";
import { OwnershipTransferEnforcer } from "../src/enforcers/OwnershipTransferEnforcer.sol";
import { RedeemerEnforcer } from "../src/enforcers/RedeemerEnforcer.sol";
import { SpecificActionERC20TransferBatchEnforcer } from "../src/enforcers/SpecificActionERC20TransferBatchEnforcer.sol";
import { TimestampEnforcer } from "../src/enforcers/TimestampEnforcer.sol";
import { ValueLteEnforcer } from "../src/enforcers/ValueLteEnforcer.sol";

/**
 * @title DeployCaveatEnforcers
 * @notice Deploys the suite of caveat enforcers to be used with the Delegation Framework.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev run the script with:
 * forge script script/DeployCaveatEnforcers.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployCaveatEnforcers is Script {
    bytes32 salt;
    IDelegationManager delegationManager;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));

        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Delegation Manager: %s", address(delegationManager));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress;

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

        deployedAddress = address(new ERC20PeriodTransferEnforcer{ salt: salt }());
        console2.log("ERC20PeriodTransferEnforcer: %s", deployedAddress);

        deployedAddress = address(new ERC20StreamingEnforcer{ salt: salt }());
        console2.log("ERC20StreamingEnforcer: %s", deployedAddress);

        deployedAddress = address(new ERC721BalanceGteEnforcer{ salt: salt }());
        console2.log("ERC721BalanceGteEnforcer: %s", deployedAddress);

        deployedAddress = address(new ERC721TransferEnforcer{ salt: salt }());
        console2.log("ERC721TransferEnforcer: %s", deployedAddress);

        deployedAddress = address(new ERC1155BalanceGteEnforcer{ salt: salt }());
        console2.log("ERC1155BalanceGteEnforcer: %s", deployedAddress);

        deployedAddress = address(new ExactCalldataEnforcer{ salt: salt }());
        console2.log("ExactCalldataEnforcer: %s", deployedAddress);

        deployedAddress = address(new ExactExecutionBatchEnforcer{ salt: salt }());
        console2.log("ExactExecutionBatchEnforcer: %s", deployedAddress);

        deployedAddress = address(new ExactExecutionEnforcer{ salt: salt }());
        console2.log("ExactExecutionEnforcer: %s", deployedAddress);

        deployedAddress = address(new IdEnforcer{ salt: salt }());
        console2.log("IdEnforcer: %s", deployedAddress);

        deployedAddress = address(new LimitedCallsEnforcer{ salt: salt }());
        console2.log("LimitedCallsEnforcer: %s", deployedAddress);

        deployedAddress = address(new MultiTokenPeriodEnforcer{ salt: salt }());
        console2.log("MultiTokenPeriodEnforcer: %s", deployedAddress);

        deployedAddress = address(new NativeBalanceGteEnforcer{ salt: salt }());
        console2.log("NativeBalanceGteEnforcer: %s", deployedAddress);

        address argsEqualityCheckEnforcer = address(new ArgsEqualityCheckEnforcer{ salt: salt }());
        console2.log("ArgsEqualityCheckEnforcer: %s", argsEqualityCheckEnforcer);

        deployedAddress =
            address(new NativeTokenPaymentEnforcer{ salt: salt }(IDelegationManager(delegationManager), argsEqualityCheckEnforcer));
        console2.log("NativeTokenPaymentEnforcer: %s", deployedAddress);

        deployedAddress = address(new NativeTokenTransferAmountEnforcer{ salt: salt }());
        console2.log("NativeTokenTransferAmountEnforcer: %s", deployedAddress);

        deployedAddress = address(new NativeTokenStreamingEnforcer{ salt: salt }());
        console2.log("NativeTokenStreamingEnforcer: %s", deployedAddress);

        deployedAddress = address(new NativeTokenPeriodTransferEnforcer{ salt: salt }());
        console2.log("NativeTokenPeriodTransferEnforcer: %s", deployedAddress);

        deployedAddress = address(new NonceEnforcer{ salt: salt }());
        console2.log("NonceEnforcer: %s", deployedAddress);

        deployedAddress = address(new OwnershipTransferEnforcer{ salt: salt }());
        console2.log("OwnershipTransferEnforcer: %s", deployedAddress);

        deployedAddress = address(new RedeemerEnforcer{ salt: salt }());
        console2.log("RedeemerEnforcer: %s", deployedAddress);

        deployedAddress = address(new SpecificActionERC20TransferBatchEnforcer{ salt: salt }());
        console2.log("SpecificActionERC20TransferBatchEnforcer: %s", deployedAddress);

        deployedAddress = address(new TimestampEnforcer{ salt: salt }());
        console2.log("TimestampEnforcer: %s", deployedAddress);

        deployedAddress = address(new ValueLteEnforcer{ salt: salt }());
        console2.log("ValueLteEnforcer: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
