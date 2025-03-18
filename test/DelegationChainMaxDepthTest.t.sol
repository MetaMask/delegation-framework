// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ERC1967Proxy as DeleGatorProxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation, ModeCode } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { AccountSorterLib } from "./utils/AccountSorterLib.t.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Counter } from "./utils/Counter.t.sol";
import { UserOperationLib } from "./utils/UserOperationLib.t.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { ERC1271Lib } from "../src/libraries/ERC1271Lib.sol";
import { EIP7702DeleGatorCore } from "../src/EIP7702/EIP7702DeleGatorCore.sol";
import {
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    MODE_DEFAULT,
    ModeLib,
    ExecType,
    ModeSelector,
    ModePayload
} from "@erc7579/lib/ModeLib.sol";

import { CallType, ExecType, ModeSelector } from "../src/utils/Types.sol";
import { console } from "forge-std/console.sol";

/**
 * @title EIP7702 Stateless DeleGator Implementation Test
 * @dev Test creates a Delegation chain with depth 100 - purpose is to check if the gas limit is reached
 * @dev NOTE: All Smart Account interactions flow through ERC4337 UserOps.
 */
contract DelegationChainMaxDepthTest is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
        CHAIN_LENGTH = 100;
    }

    ////////////////////////////// State //////////////////////////////

    uint256 public immutable CHAIN_LENGTH = 100;
    Counter public counter;

    function setUp() public override {
        super.setUp();

        counter = new Counter(address(users.alice.deleGator));
    }

    function test_delegationChainDepthLimitedByGas() public {
        // Create an array to store all the delegations
        Delegation[] memory delegations = new Delegation[](CHAIN_LENGTH);

        // First delegation from Alice to Bob
        delegations[CHAIN_LENGTH - 1] = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign first delegation
        delegations[CHAIN_LENGTH - 1] = signDelegation(users.alice, delegations[CHAIN_LENGTH - 1]);
        bytes32 previousDelegationHash = EncoderLib._getDelegationHash(delegations[CHAIN_LENGTH - 1]);

        // Create a chain of delegations: Bob -> Carol -> Dave -> Eve -> Frank and so on
        address[] memory delegators = new address[](CHAIN_LENGTH);
        delegators[0] = address(users.bob.deleGator);
        delegators[1] = address(users.carol.deleGator);
        delegators[2] = address(users.dave.deleGator);
        delegators[3] = address(users.eve.deleGator);

        // Create remaining test users for the chain
        for (uint256 i = 4; i < CHAIN_LENGTH - 1; i++) {
            (address addr,) = makeAddrAndKey(string(abi.encodePacked("user", i)));
            delegators[i] = addr;
        }

        // Create the chain of delegations - last delegae is frank
        for (uint256 i = 1; i < CHAIN_LENGTH; i++) {
            address currentDelegate = (i == CHAIN_LENGTH - 1) ? address(users.frank.deleGator) : delegators[i];
            address currentDelegator = delegators[i - 1];
            delegations[CHAIN_LENGTH - 1 - i] = Delegation({
                delegate: currentDelegate,
                delegator: currentDelegator,
                authority: previousDelegationHash,
                caveats: new Caveat[](0),
                salt: 0,
                signature: hex""
            });

            // Sign the delegation using the delegator's key
            bytes32 delegationHash = EncoderLib._getDelegationHash(delegations[CHAIN_LENGTH - 1 - i]);
            bytes32 domainHash = delegationManager.getDomainHash();
            bytes32 typedDataHash = MessageHashUtils.toTypedDataHash(domainHash, delegationHash);
            if (i == 1) {
                delegations[CHAIN_LENGTH - 1 - i].signature = signHash(users.bob, typedDataHash);
            } else if (i == 2) {
                delegations[CHAIN_LENGTH - 1 - i].signature = signHash(users.carol, typedDataHash);
            } else if (i == 3) {
                delegations[CHAIN_LENGTH - 1 - i].signature = signHash(users.dave, typedDataHash);
            } else if (i == 4) {
                delegations[CHAIN_LENGTH - 1 - i].signature = signHash(users.eve, typedDataHash);
            } else {
                // For additional users, create a new private key and sign
                (, uint256 privateKey) = makeAddrAndKey(string(abi.encodePacked("user", i - 1)));
                delegations[CHAIN_LENGTH - 1 - i].signature = SigningUtilsLib.signHash_EOA(privateKey, typedDataHash);
            }

            previousDelegationHash = delegationHash;
        }

        // Create execution calldata to increment counter
        Execution memory execution =
            Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        // Now try to redeem the entire chain
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        invokeDelegation_UserOp(users.frank, delegations, execution);

        // If we get here, the operation succeeded
        uint256 finalCount = counter.count();
        assertEq(finalCount, 1, "Counter should be incremented after delegation chain");
    }
}
