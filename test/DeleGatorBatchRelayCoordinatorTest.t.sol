// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, Vm } from "forge-std/Test.sol";

import { DeleGatorBatchRelayCoordinator } from "../src/DeleGatorBatchRelayCoordinator.sol";
import { EIP7702BatchDeleGator } from "../src/EIP7702/EIP7702BatchDeleGator.sol";
import { IDeleGatorBatchRelayCoordinator } from "../src/interfaces/IDeleGatorBatchRelayCoordinator.sol";
import { Execution } from "../src/utils/Types.sol";
import { Counter } from "./utils/Counter.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";

contract DeleGatorBatchRelayCoordinatorTest is BaseTest {
    DeleGatorBatchRelayCoordinator internal coordinator;
    EIP7702BatchDeleGator internal implementation;

    uint256 internal accountAPk = 0xA110;
    uint256 internal accountBPk = 0xB110;
    address internal accountAAddress;
    address internal accountBAddress;

    EIP7702BatchDeleGator internal accountA;
    EIP7702BatchDeleGator internal accountB;

    Counter internal counterA;
    Counter internal counterB;

    uint256 internal constant DEFAULT_DEADLINE = 1 days;

    function setUp() public override {
        super.setUp();

        coordinator = new DeleGatorBatchRelayCoordinator();
        implementation = new EIP7702BatchDeleGator(delegationManager, entryPoint);

        accountAAddress = vm.addr(accountAPk);
        accountBAddress = vm.addr(accountBPk);
        vm.etch(accountAAddress, address(implementation).code);
        vm.etch(accountBAddress, address(implementation).code);

        accountA = EIP7702BatchDeleGator(payable(accountAAddress));
        accountB = EIP7702BatchDeleGator(payable(accountBAddress));

        counterA = new Counter(accountAAddress);
        counterB = new Counter(accountBAddress);
    }

    function test_executeBatches_anyCaller() public {
        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches =
            _singleSignedBatch(accountA, accountAPk, counterA, 1, address(coordinator));

        vm.prank(address(0xBEEF));
        coordinator.executeBatches(batches);

        assertEq(counterA.count(), 1);
    }

    function test_executeBatches_unsignedChildRow_recordsFailureAndContinues() public {
        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches = new IDeleGatorBatchRelayCoordinator.AccountBatch[](2);

        Execution[] memory unsignedCalls = _incrementsFor(counterA, 1);
        batches[0] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountAAddress,
            mode: accountA.MODE_BATCH_SIMPLE(),
            executionData: abi.encode(unsignedCalls)
        });

        Execution[] memory signedCalls = _incrementsFor(counterB, 2);
        batches[1] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountBAddress,
            mode: accountB.MODE_BATCH_WITH_OPDATA(),
            executionData: abi.encode(
                signedCalls,
                _signedOpData(accountB, accountBPk, signedCalls, 1, address(coordinator))
            )
        });

        vm.recordLogs();
        coordinator.executeBatches(batches);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[1], bytes32(uint256(0)));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), accountAAddress);
        assertFalse(abi.decode(logs[0].data, (bool)));
        assertEq(logs[1].topics[1], bytes32(uint256(1)));
        assertTrue(abi.decode(logs[1].data, (bool)));

        assertEq(counterA.count(), 0);
        assertEq(counterB.count(), 2);
    }

    function test_executeBatches_signedRows() public {
        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches = new IDeleGatorBatchRelayCoordinator.AccountBatch[](2);

        Execution[] memory callsA = _incrementsFor(counterA, 1);
        batches[0] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountAAddress,
            mode: accountA.MODE_BATCH_WITH_OPDATA(),
            executionData: abi.encode(
                callsA, _signedOpData(accountA, accountAPk, callsA, 10, address(coordinator))
            )
        });

        Execution[] memory callsB = _incrementsFor(counterB, 3);
        batches[1] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountBAddress,
            mode: accountB.MODE_BATCH_WITH_OPDATA(),
            executionData: abi.encode(
                callsB, _signedOpData(accountB, accountBPk, callsB, 20, address(coordinator))
            )
        });

        coordinator.executeBatches(batches);

        assertEq(counterA.count(), 1);
        assertEq(counterB.count(), 3);
    }

    function test_executeBatches_wrongPinnedRelayer_recordsFailure() public {
        Execution[] memory calls = _incrementsFor(counterA, 1);
        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches = new IDeleGatorBatchRelayCoordinator.AccountBatch[](1);
        batches[0] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountAAddress,
            mode: accountA.MODE_BATCH_WITH_OPDATA(),
            executionData: abi.encode(calls, _signedOpData(accountA, accountAPk, calls, 5, address(0xCAFE)))
        });

        vm.recordLogs();
        coordinator.executeBatches(batches);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertFalse(abi.decode(logs[0].data, (bool)));

        assertEq(counterA.count(), 0);
    }

    function _singleSignedBatch(
        EIP7702BatchDeleGator account,
        uint256 pk,
        Counter counter,
        uint256 nonce,
        address pinnedRelayer
    )
        internal
        view
        returns (IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches)
    {
        Execution[] memory calls = _incrementsFor(counter, 1);
        batches = new IDeleGatorBatchRelayCoordinator.AccountBatch[](1);
        batches[0] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: address(account),
            mode: account.MODE_BATCH_WITH_OPDATA(),
            executionData: abi.encode(calls, _signedOpData(account, pk, calls, nonce, pinnedRelayer))
        });
    }

    function _incrementsFor(Counter counter, uint256 n) internal pure returns (Execution[] memory executions) {
        executions = new Execution[](n);
        for (uint256 i = 0; i < n; ++i) {
            executions[i] = Execution({
                target: address(counter), value: 0, callData: abi.encodeCall(Counter.unsafeIncrement, ())
            });
        }
    }

    function _signedOpData(
        EIP7702BatchDeleGator account,
        uint256 pk,
        Execution[] memory executions,
        uint256 nonce,
        address pinnedRelayer
    )
        internal
        view
        returns (bytes memory)
    {
        uint256 deadline = block.timestamp + DEFAULT_DEADLINE;
        bytes32 digest = account.hashBatchAuthorizationWithNonce(executions, nonce, deadline, pinnedRelayer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encode(nonce, deadline, pinnedRelayer, abi.encodePacked(r, s, v));
    }
}
