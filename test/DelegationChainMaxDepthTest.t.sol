// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, Caveat, Delegation } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Counter } from "./utils/Counter.t.sol";

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

        // Sign the first delegation
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

        // Create the chain of delegations - last delegate is Frank
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

        // Create execution calldata to increment the Counter
        Execution memory execution =
            Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem the entire chain via the final delegate (Frank)
        invokeDelegation_UserOp(users.frank, delegations, execution);

        // Confirm the increment was successful
        uint256 finalCount = counter.count();
        assertEq(finalCount, 1, "Counter should be incremented after delegation chain");
    }
}
