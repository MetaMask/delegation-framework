// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Execution } from "../src/utils/Types.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { Counter } from "./utils/Counter.t.sol";

import { DeleGatorBatchRelayCoordinator } from "../src/DeleGatorBatchRelayCoordinator.sol";
import { EIP7702BatchDeleGator } from "../src/EIP7702/EIP7702BatchDeleGator.sol";
import { IDeleGatorBatchRelayCoordinator } from "../src/interfaces/IDeleGatorBatchRelayCoordinator.sol";

/**
 * @title EIP7702 Batch Relay Gas Benchmark
 *
 * @notice Establishes gas baselines for the O1-1/O1-2 batch relay surface on this branch:
 *         `EIP7702BatchDeleGator.executeBatch` and `DeleGatorBatchRelayCoordinator.executeBatches`.
 *
 * @dev The three comparable scenarios below execute the SAME on-chain calls as
 *      `test/OptimizedDelegationManagerBenchmark.t.sol` on `feat/optimized-delegation-manager`
 *      (baseline / gasless swap / gasless transaction). Only the authorization and dispatch model
 *      differs: signed batch relay here vs `DelegationManager.redeemDelegations` + caveat enforcers
 *      there.
 *        1. Baseline: `Counter.increment()` on an account-owned counter (single execution).
 *        2. Gasless swap: `token.transfer(recipient, 100e18)` (single execution).
 *        3. Gasless transaction: `token.transfer(recipient, 50e18)` + `token.transfer(feeAccount, 1e18)`.
 *
 * @dev WHAT IS MEASURED: We measure ONLY the relayer-facing call frame — either a direct
 *      `executeBatch(mode, executionData)` on the 7702 account, or `executeBatches(...)` on the
 *      coordinator — NOT a 4337 UserOp. The EIP-7702 upgrade cost is excluded by construction:
 *      `vm.etch` installs the batch DeleGator code during `setUp()`.
 *      For each scenario we report:
 *        * "execution gas"  — gas consumed by the measured call frame (primary KPI).
 *        * "calldata gas"   — EIP-2028 cost of the relayer calldata.
 *        * "est. tx gas"    — 21_000 intrinsic + calldata gas + execution gas (excl. 7702 auth).
 *
 * @dev MEASUREMENT NOTES
 *      - Gas is measured with a portable `gasleft()` bracket. Run with `-vv` to print reports.
 *      - Each signed scenario uses a fresh nonce so the nonce-bitmap SSTORE is a cold 0->1 write.
 *      - Numbers are a baseline, not a regression gate.
 *      - For strict per-call isolation: `forge test --isolate --match-contract EIP7702BatchRelayBenchmark`.
 */
contract EIP7702BatchRelayBenchmark is BaseTest {
    ////////////////////////////// Constants //////////////////////////////

    /// @dev Base intrinsic gas of an Ethereum transaction (excludes any EIP-7702 authorization-list cost).
    uint256 internal constant INTRINSIC_GAS = 21_000;

    uint256 internal constant DEFAULT_DEADLINE = 1 days;

    uint256 internal constant SWAP_AMOUNT = 100e18;
    uint256 internal constant SEND_AMOUNT = 50e18;
    uint256 internal constant FEE_AMOUNT = 1e18;

    ////////////////////////////// State //////////////////////////////

    EIP7702BatchDeleGator internal implementation;
    EIP7702BatchDeleGator internal account;
    DeleGatorBatchRelayCoordinator internal coordinator;

    BasicERC20 internal token;
    Counter internal counter;

    uint256 internal accountPk = 0xA11CE;
    address internal accountAddress;
    address internal relayer = address(0xBEEF);
    address internal recipient;
    address internal feeAccount;

    bytes32 internal modeBatchSimple;
    bytes32 internal modeBatchWithOpData;
    bytes32 internal modeBatchOfBatches;

    ////////////////////////////// Set Up //////////////////////////////

    function setUp() public override {
        super.setUp();

        accountAddress = vm.addr(accountPk);
        implementation = new EIP7702BatchDeleGator(delegationManager, entryPoint);
        coordinator = new DeleGatorBatchRelayCoordinator();
        vm.etch(accountAddress, address(implementation).code);
        account = EIP7702BatchDeleGator(payable(accountAddress));

        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(accountAddress, 1_000_000e18);
        vm.label(address(token), "MockUSDC");

        counter = new Counter(accountAddress);
        vm.label(address(counter), "Counter");

        recipient = makeAddr("Recipient");
        feeAccount = makeAddr("MetaMaskFeeAccount");

        modeBatchSimple = account.MODE_BATCH_SIMPLE();
        modeBatchWithOpData = account.MODE_BATCH_WITH_OPDATA();
        modeBatchOfBatches = account.MODE_BATCH_OF_BATCHES();
    }

    ////////////////////////////// Benchmarks (comparable to OptimizedDelegationManagerBenchmark) //////////////////////////////

    /// @notice Floor cost: single `Counter.increment()` — same execution as optimized `test_bench_baseline_singleNoCaveats`.
    function test_bench_baseline_singleNoCaveats() public {
        Execution memory exec = _baselineExecution();
        Execution[] memory executions = _asBatch(exec);

        uint256 before = counter.count();
        _benchExecuteBatch(
            "baseline | single execution | no caveats",
            accountAddress,
            accountAddress,
            modeBatchSimple,
            abi.encode(executions)
        );
        assertEq(counter.count(), before + 1, "counter should increment");
    }

    /// @notice Gasless swap: single `token.transfer(recipient, 100e18)` — same execution as optimized
    ///         `test_bench_gaslessSwap_singleExecution`.
    function test_bench_gaslessSwap_singleExecution() public {
        Execution memory exec = _gaslessSwapExecution();
        Execution[] memory executions = _asBatch(exec);
        bytes memory executionData = _signedExecutionData(executions, 1, address(0));

        uint256 before = token.balanceOf(recipient);
        _benchExecuteBatch(
            "gasless swap | single execution | signed batch relay",
            relayer,
            accountAddress,
            modeBatchWithOpData,
            executionData
        );
        assertEq(token.balanceOf(recipient), before + SWAP_AMOUNT, "swap proceeds should reach recipient");
    }

    /// @notice Gasless transaction: 2-exec batch (user transfer + fee leg) — same executions as optimized
    ///         `test_bench_gaslessTransaction_batchTwoExecutions`.
    function test_bench_gaslessTransaction_batchTwoExecutions() public {
        Execution[] memory executions = _gaslessTransactionExecutions();
        bytes memory executionData = _signedExecutionData(executions, 2, address(0));

        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 feeBefore = token.balanceOf(feeAccount);
        _benchExecuteBatch(
            "gasless transaction | 2-exec batch | signed batch relay",
            relayer,
            accountAddress,
            modeBatchWithOpData,
            executionData
        );
        assertEq(token.balanceOf(recipient), recipientBefore + SEND_AMOUNT, "user action should transfer to recipient");
        assertEq(token.balanceOf(feeAccount), feeBefore + FEE_AMOUNT, "fee leg should transfer to fee account");
    }

    /// @notice Nested signed batches: two inner signed rows in one outer relay call.
    function test_bench_signedRelay_batchOfBatches() public {
        Execution[] memory executionsA = _counterIncrements(2);
        Execution[] memory executionsB = _counterIncrements(1);

        bytes memory innerA = abi.encode(
            executionsA, _signedOpData(executionsA, 10, block.timestamp + DEFAULT_DEADLINE, address(0))
        );
        bytes memory innerB = abi.encode(
            executionsB, _signedOpData(executionsB, 11, block.timestamp + DEFAULT_DEADLINE, address(0))
        );

        bytes[] memory innerBatches = new bytes[](2);
        innerBatches[0] = innerA;
        innerBatches[1] = innerB;

        _benchExecuteBatch(
            "signed relay | MODE_BATCH_OF_BATCHES | 2 inner signed batches",
            relayer,
            accountAddress,
            modeBatchOfBatches,
            abi.encode(innerBatches)
        );

        assertEq(counter.count(), 3);
        assertTrue(account.isNonceUsed(10));
        assertTrue(account.isNonceUsed(11));
    }

    /// @notice Coordinator: single signed account row relayed through `executeBatches`.
    function test_bench_coordinator_singleSignedRow() public {
        bytes memory swapCallData = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Execution[] memory executions = _singleExecution(address(token), swapCallData);

        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches =
            _coordinatorBatch(executions, 20, address(coordinator));

        uint256 before = token.balanceOf(recipient);
        _benchExecuteBatches("coordinator | 1 signed row", relayer, batches);
        assertEq(token.balanceOf(recipient), before + SWAP_AMOUNT);
    }

    /// @notice Coordinator: two signed account rows in one permissionless `executeBatches` call.
    function test_bench_coordinator_twoSignedRows() public {
        uint256 accountBPk = 0xB110;
        address accountBAddress = vm.addr(accountBPk);
        vm.etch(accountBAddress, address(implementation).code);
        EIP7702BatchDeleGator accountB = EIP7702BatchDeleGator(payable(accountBAddress));
        token.mint(accountBAddress, 1_000_000e18);

        bytes memory swapCallData = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);

        Execution[] memory executionsA = _singleExecution(address(token), swapCallData);
        Execution[] memory executionsB = _singleExecution(address(token), swapCallData);

        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches =
            new IDeleGatorBatchRelayCoordinator.AccountBatch[](2);
        batches[0] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountAddress,
            mode: modeBatchWithOpData,
            executionData: abi.encode(
                executionsA, _signedOpData(executionsA, 30, block.timestamp + DEFAULT_DEADLINE, address(coordinator))
            )
        });
        batches[1] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountBAddress,
            mode: accountB.MODE_BATCH_WITH_OPDATA(),
            executionData: abi.encode(
                executionsB,
                _signedOpDataFor(accountB, accountBPk, executionsB, 31, block.timestamp + DEFAULT_DEADLINE, address(coordinator))
            )
        });

        uint256 before = token.balanceOf(recipient);
        _benchExecuteBatches("coordinator | 2 signed rows", relayer, batches);
        assertEq(token.balanceOf(recipient), before + SWAP_AMOUNT + SWAP_AMOUNT);
    }

    ////////////////////////////// Internal: execution builders (mirrors OptimizedDelegationManagerBenchmark) //////////////////////////////

    /// @dev Matches optimized `test_bench_baseline_singleNoCaveats`: account-owned counter, `increment()`.
    function _baselineExecution() internal view returns (Execution memory exec) {
        exec = Execution({
            target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
    }

    /// @dev Matches optimized `test_bench_gaslessSwap_singleExecution`: ERC-20 transfer of SWAP_AMOUNT.
    function _gaslessSwapExecution() internal view returns (Execution memory exec) {
        exec = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT)
        });
    }

    /// @dev Matches optimized `test_bench_gaslessTransaction_batchTwoExecutions`: user leg + fee leg.
    function _gaslessTransactionExecutions() internal view returns (Execution[] memory executions) {
        executions = new Execution[](2);
        executions[0] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, SEND_AMOUNT)
        });
        executions[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, feeAccount, FEE_AMOUNT)
        });
    }

    function _asBatch(Execution memory exec) internal pure returns (Execution[] memory executions) {
        executions = new Execution[](1);
        executions[0] = exec;
    }

    function _counterIncrements(uint256 n) internal view returns (Execution[] memory executions) {
        executions = new Execution[](n);
        for (uint256 i = 0; i < n; ++i) {
            executions[i] = Execution({
                target: address(counter), value: 0, callData: abi.encodeCall(Counter.unsafeIncrement, ())
            });
        }
    }

    function _singleExecution(address target, bytes memory callData) internal pure returns (Execution[] memory executions) {
        executions = new Execution[](1);
        executions[0] = Execution({ target: target, value: 0, callData: callData });
    }

    function _signedExecutionData(
        Execution[] memory executions,
        uint256 nonce,
        address pinnedRelayer
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(executions, _signedOpData(executions, nonce, block.timestamp + DEFAULT_DEADLINE, pinnedRelayer));
    }

    function _signedOpData(
        Execution[] memory executions,
        uint256 nonce,
        uint256 deadline,
        address pinnedRelayer
    )
        internal
        view
        returns (bytes memory)
    {
        return _signedOpDataFor(account, accountPk, executions, nonce, deadline, pinnedRelayer);
    }

    function _signedOpDataFor(
        EIP7702BatchDeleGator batchAccount,
        uint256 pk,
        Execution[] memory executions,
        uint256 nonce,
        uint256 deadline,
        address pinnedRelayer
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = batchAccount.hashBatchAuthorizationWithNonce(executions, nonce, deadline, pinnedRelayer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encode(nonce, deadline, pinnedRelayer, abi.encodePacked(r, s, v));
    }

    function _coordinatorBatch(
        Execution[] memory executions,
        uint256 nonce,
        address pinnedRelayer
    )
        internal
        view
        returns (IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches)
    {
        batches = new IDeleGatorBatchRelayCoordinator.AccountBatch[](1);
        batches[0] = IDeleGatorBatchRelayCoordinator.AccountBatch({
            account: accountAddress,
            mode: modeBatchWithOpData,
            executionData: abi.encode(
                executions, _signedOpData(executions, nonce, block.timestamp + DEFAULT_DEADLINE, pinnedRelayer)
            )
        });
    }

    ////////////////////////////// Internal: measurement //////////////////////////////

    function _benchExecuteBatch(
        string memory label,
        address caller,
        address batchAccount,
        bytes32 mode,
        bytes memory executionData
    )
        internal
    {
        bytes memory callData = abi.encodeWithSelector(EIP7702BatchDeleGator.executeBatch.selector, mode, executionData);

        vm.prank(caller);
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = batchAccount.call(callData);
        uint256 executionGas = gasBefore - gasleft();

        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        _report(label, executionGas, callData);
    }

    function _benchExecuteBatches(
        string memory label,
        address caller,
        IDeleGatorBatchRelayCoordinator.AccountBatch[] memory batches
    )
        internal
    {
        bytes memory callData = abi.encodeWithSelector(DeleGatorBatchRelayCoordinator.executeBatches.selector, batches);

        vm.prank(caller);
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = address(coordinator).call(callData);
        uint256 executionGas = gasBefore - gasleft();

        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        _report(label, executionGas, callData);
    }

    function _report(string memory label, uint256 executionGas, bytes memory callData) internal view {
        uint256 calldataGas = _calldataGas(callData);
        uint256 estTxGas = INTRINSIC_GAS + calldataGas + executionGas;

        console.log("=====================================================================");
        console.log(label);
        console.log(string.concat("  execution gas ..................... ", vm.toString(executionGas)));
        console.log(string.concat("  calldata size (bytes) ............. ", vm.toString(callData.length)));
        console.log(string.concat("  calldata gas (EIP-2028) ........... ", vm.toString(calldataGas)));
        console.log(string.concat("  est. standalone tx gas (excl. 7702) ", vm.toString(estTxGas)));
        console.log("=====================================================================");
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 gas_) {
        uint256 len = data.length;
        for (uint256 i; i < len; ++i) {
            gas_ += data[i] == 0x00 ? 4 : 16;
        }
    }
}
