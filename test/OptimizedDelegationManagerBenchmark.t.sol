// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console } from "forge-std/console.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "./utils/Types.t.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../src/utils/Types.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { Counter } from "./utils/Counter.t.sol";

import { ExactExecutionEnforcer } from "../src/enforcers/ExactExecutionEnforcer.sol";
import { ExactExecutionBatchEnforcer } from "../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { LimitedCallsEnforcer } from "../src/enforcers/LimitedCallsEnforcer.sol";

/**
 * @title Optimized DelegationManager Gas Benchmark
 *
 * @notice Establishes a gas baseline for `redeemDelegations` on an EIP-7702 account, as groundwork for a dedicated, gas-optimized
 *         "GaslessDelegationManager". The two gasless product flows Option 3 targets are benchmarked here against the CURRENT
 *         `DelegationManager` so that, once the optimized manager exists, we can measure the delta apples-to-apples.
 *
 * @dev The gasless flows:
 *        1. Gasless transaction: a 2-execution batch (user action + ERC-20 fee transfer), gated by `ExactExecutionBatchEnforcer` +
 *           `LimitedCallsEnforcer`.
 *        2. Gasless swap: a single execution, gated by `ExactExecutionEnforcer` + `LimitedCallsEnforcer`.
 *
 * @dev WHAT IS MEASURED: We measure ONLY the `redeemDelegations(...)` call, as a relayer would submit it (direct call to the
 * manager,
 *      NOT a 4337 UserOp — the EntryPoint path would swamp the number). The EIP-7702 "upgrade" cost is EXCLUDED by construction:
 *      `BaseTest.deployDeleGator_EIP7702Stateless` installs the 7702 delegation designator (`0xef0100 || impl`) via `vm.etch`
 *      during `setUp()`. There is no type-4 authorization transaction in the measured region, so its gas never lands in these
 * numbers.
 *      - For each scenario we report three numbers:
 *          * "execution gas"  — gas consumed by the `redeemDelegations` call frame (the primary KPI to iterate against).
 *          * "calldata gas"   — EIP-2028 cost (4 gas / zero byte, 16 / non-zero byte) of the redeem calldata.
 *          * "est. tx gas"    — 21_000 intrinsic + calldata gas + execution gas: a realistic estimate of the standalone relayer
 *                               transaction (still excluding any 7702 authorization).
 *
 * @dev MEASUREMENT NOTES
 *      - Gas is measured with the portable `gasleft()` bracket (forge-std v1.7.6 here has no `vm.startSnapshotGas` /
 *        `vm.lastCallGas`). Run with `-vv` to print the per-scenario report.
 *      - Each test redeems a fresh, single-use delegation (`LimitedCallsEnforcer` limit = 1), so the enforcer's counter SSTORE
 *        is a cold 0->1 write — the realistic one-shot gasless cost. Cross-address access (token, target, account) is also cold
 *        on first touch within the test body, approximating a standalone transaction. For strict per-call isolation use
 *        `forge test --isolate --match-contract OptimizedDelegationManagerBenchmark`.
 *      - Numbers are a baseline, not a regression gate; no upper-bound asserts (gas will move as the optimized manager lands).
 *
 * @dev HOW TO REPOINT AT THE FUTURE GaslessDelegationManager
 *      These tests call `delegationManager` (the current manager wired into the 7702 accounts by `BaseTest`). Once a
 *      `GaslessDelegationManager` exists and the 7702 account approves it, override `_manager()` (or swap the deployment in
 *      `setUp`) and re-run to get the optimized numbers side-by-side.
 */
contract OptimizedDelegationManagerBenchmark is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    ////////////////////////////// Constants //////////////////////////////

    /// @dev Base intrinsic gas of an Ethereum transaction (excludes any EIP-7702 authorization-list cost).
    uint256 internal constant INTRINSIC_GAS = 21_000;

    uint256 internal constant SWAP_AMOUNT = 100e18; // gasless swap: tokens moved by the "swap"
    uint256 internal constant SEND_AMOUNT = 50e18; // gasless tx: user-intended transfer
    uint256 internal constant FEE_AMOUNT = 1e18; // gasless tx: gas-payment leg to the MetaMask fee account

    ////////////////////////////// State //////////////////////////////

    ExactExecutionEnforcer internal exactExecutionEnforcer;
    ExactExecutionBatchEnforcer internal exactExecutionBatchEnforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;

    BasicERC20 internal token; // stand-in for USDC (swap proceeds / fee token)
    Counter internal counter; // baseline target, owned by Alice's 7702 account

    address internal relayer; // the gasless relayer == leaf delegate == redeemer (msg.sender)
    address internal recipient; // recipient of the user-intended action
    address internal feeAccount; // MetaMask fee account (gasless-transaction fee leg)

    ////////////////////////////// Set Up //////////////////////////////

    function setUp() public override {
        super.setUp();

        // Enforcers used by the two gasless flows.
        exactExecutionEnforcer = new ExactExecutionEnforcer();
        exactExecutionBatchEnforcer = new ExactExecutionBatchEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        vm.label(address(exactExecutionEnforcer), "ExactExecutionEnforcer");
        vm.label(address(exactExecutionBatchEnforcer), "ExactExecutionBatchEnforcer");
        vm.label(address(limitedCallsEnforcer), "LimitedCallsEnforcer");

        // Token held by Alice's 7702 account (the delegator/root).
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);
        vm.label(address(token), "MockUSDC");

        // Baseline target owned by Alice's account so executeFromExecutor passes its onlyOwner check.
        counter = new Counter(address(users.alice.deleGator));
        vm.label(address(counter), "Counter");

        relayer = makeAddr("Relayer");
        recipient = makeAddr("Recipient");
        feeAccount = makeAddr("MetaMaskFeeAccount");
    }

    /// @dev The manager under benchmark. Override / repoint when the GaslessDelegationManager exists.
    function _manager() internal view returns (address) {
        return address(delegationManager);
    }

    ////////////////////////////// Benchmarks //////////////////////////////

    /// @notice Floor cost: single execution, no caveats. Pure redeemDelegations + executeFromExecutor overhead.
    function test_bench_baseline_singleNoCaveats() public {
        Execution memory exec_ =
            Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signedRootDelegation(relayer, users.alice, new Caveat[](0));

        uint256 before_ = counter.count();
        _benchRedeem(
            "baseline | single execution | no caveats",
            relayer,
            delegations_,
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(exec_.target, exec_.value, exec_.callData)
        );
        assertEq(counter.count(), before_ + 1, "counter should increment");
    }

    /// @notice Gasless swap shape: single execution gated by ExactExecutionEnforcer + LimitedCallsEnforcer.
    /// @dev The swap is modeled as an ERC-20 transfer from Alice's account (stand-in for the swap-router call); the swap fee is
    ///      raised on the swap itself, so there is no separate fee leg (per ADR Option 3).
    function test_bench_gaslessSwap_singleExecution() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        address target_ = address(token);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionSingleCaveat(target_, 0, swapCallData_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signedRootDelegation(relayer, users.alice, caveats_);

        uint256 before_ = token.balanceOf(recipient);
        _benchRedeem(
            "gasless swap | single execution | ExactExecution + LimitedCalls",
            relayer,
            delegations_,
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(target_, 0, swapCallData_)
        );
        assertEq(token.balanceOf(recipient), before_ + SWAP_AMOUNT, "swap proceeds should reach recipient");
    }

    /// @notice Gasless transaction shape: 2-execution batch (user action + ERC-20 gas-fee transfer) gated by
    ///         ExactExecutionBatchEnforcer + LimitedCallsEnforcer.
    function test_bench_gaslessTransaction_batchTwoExecutions() public {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, SEND_AMOUNT)
        });
        executions_[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, feeAccount, FEE_AMOUNT)
        });

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionBatchCaveat(executions_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signedRootDelegation(relayer, users.alice, caveats_);

        uint256 recipientBefore_ = token.balanceOf(recipient);
        uint256 feeBefore_ = token.balanceOf(feeAccount);
        _benchRedeem(
            "gasless transaction | 2-exec batch | ExactExecutionBatch + LimitedCalls",
            relayer,
            delegations_,
            ModeLib.encodeSimpleBatch(),
            ExecutionLib.encodeBatch(executions_)
        );
        assertEq(token.balanceOf(recipient), recipientBefore_ + SEND_AMOUNT, "user action should transfer to recipient");
        assertEq(token.balanceOf(feeAccount), feeBefore_ + FEE_AMOUNT, "fee leg should transfer to fee account");
    }

    /// @notice Gasless swap over a 2-link delegation chain (root: Alice->Bob, leaf: Bob->relayer). Measures the leaf-to-root
    ///         validation cost (2 signatures, 2 authority checks, 2 hook sets, 2 events) that Option 3 explicitly preserves.
    function test_bench_gaslessSwap_chainedDelegation() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        address target_ = address(token);

        // Root delegation: Alice (7702 account, the funds-holder) delegates full authority to Bob.
        Delegation memory root_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        root_ = signDelegation(users.alice, root_);

        // Leaf delegation: Bob delegates to the relayer, scoped to the exact swap + one-shot replay protection.
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionSingleCaveat(target_, 0, swapCallData_);
        caveats_[1] = _limitedCallsCaveat(1);
        Delegation memory leaf_ = Delegation({
            delegate: relayer,
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(root_),
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        leaf_ = signDelegation(users.bob, leaf_);

        // Ordered leaf -> root.
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;

        uint256 before_ = token.balanceOf(recipient);
        _benchRedeem(
            "gasless swap | chained (root Alice->Bob, leaf Bob->relayer) | ExactExecution + LimitedCalls",
            relayer,
            delegations_,
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(target_, 0, swapCallData_)
        );
        assertEq(token.balanceOf(recipient), before_ + SWAP_AMOUNT, "chained swap proceeds should reach recipient");
    }

    /// @notice Decomposition variant: gasless swap with ExactExecution only (no LimitedCalls). Isolates the cold SSTORE cost of
    ///         the replay counter so the future GaslessDelegationManager comparison can separate manager overhead from caveat
    ///         state writes. NOTE: not a production shape — it has no replay protection.
    function test_bench_gaslessSwap_exactExecutionOnly() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        address target_ = address(token);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = _exactExecutionSingleCaveat(target_, 0, swapCallData_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signedRootDelegation(relayer, users.alice, caveats_);

        uint256 before_ = token.balanceOf(recipient);
        _benchRedeem(
            "gasless swap | single execution | ExactExecution only (no LimitedCalls)",
            relayer,
            delegations_,
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(target_, 0, swapCallData_)
        );
        assertEq(token.balanceOf(recipient), before_ + SWAP_AMOUNT, "swap proceeds should reach recipient");
    }

    ////////////////////////////// Internal: builders //////////////////////////////

    /// @dev Builds a single root delegation (authority = ROOT_AUTHORITY) from `signer`'s 7702 account to `delegate`, signed by
    ///      `signer`. For an EIP-7702 account the delegator address equals the EOA address, and the DelegationManager validates
    ///      the signature via ERC-1271 (the account has code), recovering to the EOA key.
    function _signedRootDelegation(
        address delegate,
        TestUser memory signer,
        Caveat[] memory caveats
    )
        internal
        view
        returns (Delegation memory delegation_)
    {
        delegation_ = Delegation({
            delegate: delegate,
            delegator: address(signer.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(signer, delegation_);
    }

    function _exactExecutionSingleCaveat(
        address target,
        uint256 value,
        bytes memory callData
    )
        internal
        view
        returns (Caveat memory)
    {
        // ExactExecutionEnforcer terms MUST be byte-identical to the single execution calldata (packed encoding).
        return Caveat({
            enforcer: address(exactExecutionEnforcer), terms: ExecutionLib.encodeSingle(target, value, callData), args: hex""
        });
    }

    function _exactExecutionBatchCaveat(Execution[] memory executions) internal view returns (Caveat memory) {
        // ExactExecutionBatchEnforcer terms MUST be the batch encoding (abi.encode(Execution[])) of the same executions.
        return Caveat({ enforcer: address(exactExecutionBatchEnforcer), terms: ExecutionLib.encodeBatch(executions), args: hex"" });
    }

    function _limitedCallsCaveat(uint256 limit) internal view returns (Caveat memory) {
        // LimitedCallsEnforcer terms = abi.encode(uint256 limit) (exactly 32 bytes).
        return Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(limit), args: hex"" });
    }

    ////////////////////////////// Internal: measurement //////////////////////////////

    /**
     * @dev Measures ONLY the `redeemDelegations` call and logs the gas report. All calldata is pre-encoded before the
     *      `gasleft()` bracket so struct/array ABI encoding is excluded from the measured region. The call is made via a
     *      pre-encoded low-level call (calldata is bytes already), so the bracket captures the call dispatch + full execution
     *      — closely matching the on-chain `redeemDelegations` frame.
     */
    function _benchRedeem(
        string memory label,
        address redeemer,
        Delegation[] memory delegations,
        ModeCode mode,
        bytes memory executionCallData
    )
        internal
    {
        bytes memory redeemCalldata_ = _encodeRedeem(delegations, mode, executionCallData);

        vm.prank(redeemer);
        uint256 gasBefore_ = gasleft();
        (bool ok_, bytes memory ret_) = _manager().call(redeemCalldata_);
        uint256 executionGas_ = gasBefore_ - gasleft();

        if (!ok_) {
            // Bubble up the revert reason so a misconfigured benchmark fails loudly.
            assembly {
                revert(add(ret_, 0x20), mload(ret_))
            }
        }

        _report(label, executionGas_, redeemCalldata_);
    }

    /// @dev Encodes the single-redemption `redeemDelegations` calldata exactly as a relayer would submit it.
    function _encodeRedeem(
        Delegation[] memory delegations,
        ModeCode mode,
        bytes memory executionCallData
    )
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = mode;

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = executionCallData;

        return
            abi.encodeWithSelector(delegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
    }

    /// @dev Logs the three-number gas report for one scenario. Uses string.concat + vm.toString so a single console.log(string)
    ///      overload renders every line reliably under `-vv`.
    function _report(string memory label, uint256 executionGas, bytes memory redeemCalldata) internal view {
        uint256 calldataGas_ = _calldataGas(redeemCalldata);
        uint256 estTxGas_ = INTRINSIC_GAS + calldataGas_ + executionGas;

        console.log("=====================================================================");
        console.log(label);
        console.log(string.concat("  redeemDelegations execution gas .... ", vm.toString(executionGas)));
        console.log(string.concat("  calldata size (bytes) .............. ", vm.toString(redeemCalldata.length)));
        console.log(string.concat("  calldata gas (EIP-2028) ............ ", vm.toString(calldataGas_)));
        console.log(string.concat("  est. standalone tx gas (excl. 7702)  ", vm.toString(estTxGas_)));
        console.log("=====================================================================");
    }

    /// @dev EIP-2028 calldata cost: 4 gas per zero byte, 16 gas per non-zero byte (London rules; matches foundry.toml).
    function _calldataGas(bytes memory data) internal pure returns (uint256 gas_) {
        uint256 len_ = data.length;
        for (uint256 i; i < len_; ++i) {
            gas_ += data[i] == 0x00 ? 4 : 16;
        }
    }
}
