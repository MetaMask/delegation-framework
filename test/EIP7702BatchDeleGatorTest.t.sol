// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { EIP7702BatchDeleGator } from "../src/EIP7702/EIP7702BatchDeleGator.sol";
import { EIP7702BatchDeleGatorBeacon } from "../src/EIP7702/EIP7702BatchDeleGatorBeacon.sol";
import { EIP7702BatchDeleGatorProxy } from "../src/EIP7702/EIP7702BatchDeleGatorProxy.sol";
import { EIP7702DeleGatorCore } from "../src/EIP7702/EIP7702DeleGatorCore.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { BatchAuthorizationLib } from "../src/libraries/BatchAuthorizationLib.sol";
import { Execution, ModeCode } from "../src/utils/Types.sol";
import { Counter } from "./utils/Counter.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";

interface IVersionedBatchDeleGator {
    function version() external view returns (uint256);
}

contract RevertingTarget {
    error AlwaysReverts();

    function boom() external pure {
        revert AlwaysReverts();
    }
}

contract EIP7702BatchDeleGatorTest is BaseTest {
    using ModeLib for ModeCode;

    EIP7702BatchDeleGator internal implementation;
    EIP7702BatchDeleGator internal account;
    Counter internal counter;

    uint256 internal accountPk = 0xA11CE;
    address internal accountAddress;
    address internal relayer = address(0xBEEF);

    uint256 internal constant DEFAULT_DEADLINE = 1 days;
    uint256 internal constant DEFAULT_NONCE = 42;

    bytes32 internal modeBatchSimple;
    bytes32 internal modeBatchWithOpData;
    bytes32 internal modeBatchOfBatches;

    function setUp() public override {
        super.setUp();

        accountAddress = vm.addr(accountPk);
        implementation = new EIP7702BatchDeleGator(delegationManager, entryPoint);
        vm.etch(accountAddress, address(implementation).code);
        account = EIP7702BatchDeleGator(payable(accountAddress));
        counter = new Counter(accountAddress);

        modeBatchSimple = implementation.MODE_BATCH_SIMPLE();
        modeBatchWithOpData = implementation.MODE_BATCH_WITH_OPDATA();
        modeBatchOfBatches = implementation.MODE_BATCH_OF_BATCHES();
    }

    function test_supportsBatchExecutionModes() public {
        assertTrue(account.supportsBatchExecutionMode(account.MODE_BATCH_SIMPLE()));
        assertTrue(account.supportsBatchExecutionMode(account.MODE_BATCH_WITH_OPDATA()));
        assertTrue(account.supportsBatchExecutionMode(account.MODE_BATCH_OF_BATCHES()));
    }

    function test_inheritedSupportsExecutionMode_excludesRelayOnlyModes() public {
        assertFalse(account.supportsExecutionMode(ModeCode.wrap(account.MODE_BATCH_WITH_OPDATA())));
        assertFalse(account.supportsExecutionMode(ModeCode.wrap(account.MODE_BATCH_OF_BATCHES())));
    }

    function test_executeBatch_unsigned_selfBatch() public {
        Execution[] memory executions = _twoIncrements();
        vm.prank(accountAddress);
        account.executeBatch(modeBatchSimple, abi.encode(executions));
        assertEq(counter.count(), 2);
    }

    function test_executeBatch_unsigned_externalCaller_reverts() public {
        Execution[] memory executions = _twoIncrements();
        vm.prank(relayer);
        vm.expectRevert(EIP7702BatchDeleGator.UnauthorizedBatchExecuteCaller.selector);
        account.executeBatch(modeBatchSimple, abi.encode(executions));
    }

    function test_executeBatch_signed_relay() public {
        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));

        vm.prank(relayer);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
        assertEq(counter.count(), 2);
        assertTrue(account.isNonceUsed(DEFAULT_NONCE));
    }

    function test_executeBatch_signed_throughInheritedExecute_revertsForRelayer() public {
        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));
        bytes memory executionData = abi.encode(executions, opData);

        vm.prank(relayer);
        vm.expectRevert(EIP7702DeleGatorCore.NotEntryPointOrSelf.selector);
        account.execute(ModeCode.wrap(modeBatchWithOpData), executionData);
    }

    function test_executeBatch_signed_wrongSigner_reverts() public {
        Execution[] memory executions = _twoIncrements();
        bytes32 digest = account.hashBatchAuthorizationWithNonce(
            executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);
        bytes memory opData = abi.encode(DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0), abi.encodePacked(r, s, v));

        vm.prank(relayer);
        vm.expectRevert(EIP7702BatchDeleGator.InvalidBatchSignature.selector);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
    }

    function test_executeBatch_signed_expiredDeadline_reverts() public {
        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp - 1, address(0));

        vm.prank(relayer);
        vm.expectRevert(EIP7702BatchDeleGator.BatchAuthorizationExpired.selector);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
    }

    function test_executeBatch_signed_wrongRelayer_reverts() public {
        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, relayer);

        vm.prank(address(0xCAFE));
        vm.expectRevert(EIP7702BatchDeleGator.UnauthorizedRelayer.selector);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
    }

    function test_executeBatch_signed_replay_reverts() public {
        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));
        bytes memory executionData = abi.encode(executions, opData);

        vm.startPrank(relayer);
        account.executeBatch(modeBatchWithOpData, executionData);
        vm.expectRevert(EIP7702BatchDeleGator.NonceAlreadyUsed.selector);
        account.executeBatch(modeBatchWithOpData, executionData);
        vm.stopPrank();
    }

    function test_executeBatch_failedExecution_revertsNonceConsumption() public {
        RevertingTarget revertingTarget = new RevertingTarget();
        Execution[] memory executions = new Execution[](1);
        executions[0] = Execution({
            target: address(revertingTarget), value: 0, callData: abi.encodeCall(RevertingTarget.boom, ())
        });
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));

        vm.prank(relayer);
        vm.expectRevert(RevertingTarget.AlwaysReverts.selector);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));

        assertFalse(account.isNonceUsed(DEFAULT_NONCE));
    }

    function test_invalidateNonce_blocksLaterUse() public {
        vm.prank(accountAddress);
        account.invalidateNonce(DEFAULT_NONCE);

        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));

        vm.prank(relayer);
        vm.expectRevert(EIP7702BatchDeleGator.NonceAlreadyUsed.selector);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
    }

    function test_invalidateNonces_blocksMaskedNonces() public {
        uint256 word = DEFAULT_NONCE >> 8;
        uint256 mask = 1 << uint8(DEFAULT_NONCE);

        vm.prank(accountAddress);
        account.invalidateNonces(word, mask);

        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));

        vm.prank(relayer);
        vm.expectRevert(EIP7702BatchDeleGator.NonceAlreadyUsed.selector);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
    }

    function test_executeBatch_ofBatches() public {
        Execution[] memory executionsA = _twoIncrements();
        Execution[] memory executionsB = _oneIncrement();

        bytes memory innerA = abi.encode(executionsA, _signedOpData(executionsA, 1, block.timestamp + DEFAULT_DEADLINE, address(0)));
        bytes memory innerB = abi.encode(executionsB, _signedOpData(executionsB, 2, block.timestamp + DEFAULT_DEADLINE, address(0)));

        bytes[] memory innerBatches = new bytes[](2);
        innerBatches[0] = innerA;
        innerBatches[1] = innerB;

        vm.prank(relayer);
        account.executeBatch(modeBatchOfBatches, abi.encode(innerBatches));

        assertEq(counter.count(), 3);
        assertTrue(account.isNonceUsed(1));
        assertTrue(account.isNonceUsed(2));
    }

    function test_hashBatchAuthorizationWithNonce_matchesManualDigest() public {
        Execution[] memory executions = _twoIncrements();
        uint256 nonce = 7;
        uint256 deadline = block.timestamp + DEFAULT_DEADLINE;

        bytes32 callsDigest = BatchAuthorizationLib.executionsDigest(executions);
        bytes32 structHash =
            BatchAuthorizationLib.batchAuthorizationWithNonceStructHash(callsDigest, nonce, deadline, relayer);
        bytes32 expected = MessageHashUtils.toTypedDataHash(account.getDomainHash(), structHash);

        assertEq(account.hashBatchAuthorizationWithNonce(executions, nonce, deadline, relayer), expected);
    }

    function test_beaconProxyUpgrade_preservesNonceBitmap() public {
        EIP7702BatchDeleGator implementationV1 = new EIP7702BatchDeleGator(delegationManager, entryPoint);
        EIP7702BatchDeleGatorV2Mock implementationV2 = new EIP7702BatchDeleGatorV2Mock(delegationManager, entryPoint);
        EIP7702BatchDeleGatorBeacon beacon = new EIP7702BatchDeleGatorBeacon(address(implementationV1), address(this));
        EIP7702BatchDeleGatorProxy proxy = new EIP7702BatchDeleGatorProxy(address(beacon));

        vm.etch(accountAddress, address(proxy).code);
        account = EIP7702BatchDeleGator(payable(accountAddress));

        Execution[] memory executions = _twoIncrements();
        bytes memory opData = _signedOpData(executions, DEFAULT_NONCE, block.timestamp + DEFAULT_DEADLINE, address(0));
        vm.prank(relayer);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, opData));
        assertTrue(account.isNonceUsed(DEFAULT_NONCE));

        bytes32 nonceSlot = StorageUtilsLib.getStorageLocation("DeleGator.EIP7702BatchDeleGator.nonce");
        uint256 word = DEFAULT_NONCE >> 8;
        bytes32 bitmapSlot = keccak256(abi.encode(word, nonceSlot));
        bytes32 bitmapBefore = vm.load(accountAddress, bitmapSlot);

        beacon.upgradeTo(address(implementationV2));
        assertEq(IVersionedBatchDeleGator(accountAddress).version(), 2);
        assertEq(vm.load(accountAddress, bitmapSlot), bitmapBefore);

        uint256 nextNonce = DEFAULT_NONCE + 1;
        bytes memory nextOpData =
            _signedOpData(executions, nextNonce, block.timestamp + DEFAULT_DEADLINE, address(0));
        vm.prank(relayer);
        account.executeBatch(modeBatchWithOpData, abi.encode(executions, nextOpData));
        assertEq(counter.count(), 4);
    }

    function test_inheritedStandardBatchMode_stillWorks() public {
        Execution memory execution = Execution({
            target: address(counter),
            value: 0,
            callData: abi.encodeCall(Counter.unsafeIncrement, ())
        });
        Execution[] memory executions = new Execution[](1);
        executions[0] = execution;

        vm.prank(accountAddress);
        account.execute(ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions));
        assertEq(counter.count(), 1);
    }

    function _twoIncrements() internal view returns (Execution[] memory executions) {
        executions = new Execution[](2);
        executions[0] = Execution({
            target: address(counter), value: 0, callData: abi.encodeCall(Counter.unsafeIncrement, ())
        });
        executions[1] = Execution({
            target: address(counter), value: 0, callData: abi.encodeCall(Counter.unsafeIncrement, ())
        });
    }

    function _oneIncrement() internal view returns (Execution[] memory executions) {
        executions = new Execution[](1);
        executions[0] = Execution({
            target: address(counter), value: 0, callData: abi.encodeCall(Counter.unsafeIncrement, ())
        });
    }

    function _signedOpData(
        Execution[] memory executions,
        uint256 nonce,
        uint256 deadline,
        address authorizedRelayer
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = account.hashBatchAuthorizationWithNonce(executions, nonce, deadline, authorizedRelayer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountPk, digest);
        return abi.encode(nonce, deadline, authorizedRelayer, abi.encodePacked(r, s, v));
    }
}

contract EIP7702BatchDeleGatorV2Mock is EIP7702BatchDeleGator {
    constructor(IDelegationManager delegationManager_, IEntryPoint entryPoint_)
        EIP7702BatchDeleGator(delegationManager_, entryPoint_)
    { }

    function version() external pure returns (uint256) {
        return 2;
    }
}
