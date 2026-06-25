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
import { HookFlagsLib } from "../src/libraries/HookFlagsLib.sol";
import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { Counter } from "./utils/Counter.t.sol";

import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { SimpleDelegationManager } from "../src/SimpleDelegationManager.sol";
import { EIP7702MultiManagerDeleGator } from "../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { EIP7702MultiManagerDeleGatorCore } from "../src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol";
import { ExactExecutionEnforcer } from "../src/enforcers/ExactExecutionEnforcer.sol";
import { ExactExecutionBatchEnforcer } from "../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { LimitedCallsEnforcer } from "../src/enforcers/LimitedCallsEnforcer.sol";

/**
 * @title SimpleDelegationManager vs DelegationManager — side-by-side gas comparison
 *
 * @notice Benchmarks `redeemDelegations` gas for the gasless flows on an EIP-7702 account, comparing the canonical
 *         `DelegationManager` against the gas-optimized `SimpleDelegationManager` (ADR #0002 Option 3).
 *
 * @dev SETUP that makes the comparison FAIR (only the manager logic differs):
 *      - The delegator is a NEW {EIP7702MultiManagerDeleGator} 7702 account that approves BOTH managers (an EIP-7201
 *        approved-manager set replaces the single immutable manager), so the SAME account can be driven by either.
 *      - Both managers redeem the SAME caveats against the SAME enforcer instances. Those enforcers are deployed at
 *        CREATE2-mined, flag-bearing addresses (low nibble = {HookFlagsLib.BEFORE_HOOK_FLAG}), so `SimpleDelegationManager`
 *        can skip the no-op hook phases via a pure address-bit test (Uniswap-v4-style), while `DelegationManager` ignores
 *        the bits and calls all four phases — exactly the overhead being measured.
 *      - Each manager is measured from an IDENTICAL cold state via `vm.snapshot()` / `vm.revertTo()`, so warm-storage
 *        ordering does not bias the result.
 *      - The 7702 "upgrade" is installed with `vm.etch` in setUp, so its gas is excluded (see
 *        OptimizedDelegationManagerBenchmark.t.sol for the rationale). Gas is measured with the portable `gasleft()` bracket.
 *
 * @dev Run with `-vv` to print the comparison. Use `--isolate` for cold per-call absolute numbers.
 */
contract SimpleDelegationManagerComparison is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    ////////////////////////////// Constants //////////////////////////////

    uint256 internal constant INTRINSIC_GAS = 21_000;
    uint256 internal constant SWAP_AMOUNT = 100e18;
    uint256 internal constant SEND_AMOUNT = 50e18;
    uint256 internal constant FEE_AMOUNT = 1e18;

    /// @dev keccak256(abi.encode(uint256(keccak256("DeleGator.EIP7702MultiManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant EXPECTED_MULTI_MANAGER_SLOT = 0x49e56a63dc56241c65d46138ca3c27c5bf7b4df245f96cb568e8e7ba7c940400;

    ////////////////////////////// State //////////////////////////////

    DelegationManager internal currentManager; // the canonical manager (from BaseTest)
    SimpleDelegationManager internal simpleManager; // the gas-optimized manager
    EIP7702MultiManagerDeleGator internal multiManagerImpl; // the new multi-manager 7702 account implementation

    ExactExecutionEnforcer internal exactExecutionEnforcer;
    ExactExecutionBatchEnforcer internal exactExecutionBatchEnforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;

    BasicERC20 internal token;
    Counter internal counter;

    address internal relayer;
    address internal recipient;
    address internal feeAccount;

    ////////////////////////////// Set Up //////////////////////////////

    function setUp() public override {
        super.setUp();

        currentManager = delegationManager; // BaseTest's canonical DelegationManager
        simpleManager = new SimpleDelegationManager();
        vm.label(address(simpleManager), "SimpleDelegationManager");

        // New multi-manager 7702 account implementation; re-etch Alice (root/executor) and Bob (chain intermediary) onto it.
        multiManagerImpl = new EIP7702MultiManagerDeleGator();
        vm.label(address(multiManagerImpl), "EIP7702MultiManager Impl");
        _etchMultiManager(users.alice.addr);
        _etchMultiManager(users.bob.addr);

        // Alice (the funds-holding root delegator) approves both managers so either can drive her account.
        EIP7702MultiManagerDeleGator aliceAccount_ = EIP7702MultiManagerDeleGator(payable(users.alice.addr));
        vm.startPrank(users.alice.addr);
        aliceAccount_.approveDelegationManager(IDelegationManager(address(currentManager)));
        aliceAccount_.approveDelegationManager(IDelegationManager(address(simpleManager)));
        vm.stopPrank();

        // Deploy the three gasless enforcers at flag-bearing addresses (BEFORE_HOOK_FLAG only) via CREATE2 salt mining.
        exactExecutionEnforcer = ExactExecutionEnforcer(_deployFlagged(type(ExactExecutionEnforcer).creationCode));
        exactExecutionBatchEnforcer = ExactExecutionBatchEnforcer(_deployFlagged(type(ExactExecutionBatchEnforcer).creationCode));
        limitedCallsEnforcer = LimitedCallsEnforcer(_deployFlagged(type(LimitedCallsEnforcer).creationCode));
        vm.label(address(exactExecutionEnforcer), "ExactExecutionEnforcer(flagged)");
        vm.label(address(exactExecutionBatchEnforcer), "ExactExecutionBatchEnforcer(flagged)");
        vm.label(address(limitedCallsEnforcer), "LimitedCallsEnforcer(flagged)");

        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(users.alice.addr, 1_000_000e18);
        vm.label(address(token), "MockUSDC");

        counter = new Counter(users.alice.addr);
        vm.label(address(counter), "Counter");

        relayer = makeAddr("Relayer");
        recipient = makeAddr("Recipient");
        feeAccount = makeAddr("MetaMaskFeeAccount");
    }

    ////////////////////////////// Sanity checks //////////////////////////////

    /// @notice The hardcoded EIP-7201 slot matches the namespace formula.
    function test_multiManager_storageSlotMatchesNamespace() public {
        assertEq(
            StorageUtilsLib.getStorageLocation("DeleGator.EIP7702MultiManager"),
            EXPECTED_MULTI_MANAGER_SLOT,
            "ERC-7201 slot mismatch"
        );
    }

    /// @notice Each gasless enforcer is deployed at an address advertising BEFORE_HOOK_FLAG (and nothing else).
    function test_enforcers_haveBeforeHookFlagOnly() public {
        _assertBeforeHookOnly(address(exactExecutionEnforcer));
        _assertBeforeHookOnly(address(exactExecutionBatchEnforcer));
        _assertBeforeHookOnly(address(limitedCallsEnforcer));
    }

    /// @notice The multi-manager account rejects an unapproved manager trying to drive it.
    function test_multiManager_rejectsUnapprovedManager() public {
        SimpleDelegationManager rogue_ = new SimpleDelegationManager();

        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Caveat[] memory caveats_ = _gaslessSwapCaveats(swapCallData_);
        Delegation memory unsigned_ = _rootDelegation(relayer, users.alice.addr, caveats_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signDelegationFor(IDelegationManager(address(rogue_)), users.alice, unsigned_);

        bytes[] memory pc_ = new bytes[](1);
        pc_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory ecd_ = new bytes[](1);
        ecd_[0] = ExecutionLib.encodeSingle(address(token), 0, swapCallData_);

        vm.prank(relayer);
        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.NotDelegationManager.selector);
        rogue_.redeemDelegations(pc_, modes_, ecd_);
    }

    ////////////////////////////// SimpleDelegationManager functional / negative paths //////////////////////////////

    /// @notice Happy path: a single gasless-swap delegation redeems successfully through SimpleDelegationManager.
    function test_simple_gaslessSwap_succeeds() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Delegation[] memory delegations_ = _signedGaslessSwap(relayer, swapCallData_);

        _redeemSimple(
            relayer, delegations_, ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(address(token), 0, swapCallData_)
        );
        assertEq(token.balanceOf(recipient), SWAP_AMOUNT, "swap proceeds reached recipient");
    }

    /// @notice ANY_DELEGATE lets any account redeem.
    function test_simple_anyDelegate_allowsAnyRedeemer() public {
        address randomRedeemer_ = makeAddr("RandomRedeemer");
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Delegation[] memory delegations_ = _signedGaslessSwap(ANY_DELEGATE, swapCallData_);

        _redeemSimple(
            randomRedeemer_, delegations_, ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(address(token), 0, swapCallData_)
        );
        assertEq(token.balanceOf(recipient), SWAP_AMOUNT, "ANY_DELEGATE redemption succeeded");
    }

    /// @notice A redeemer that is not the leaf delegate is rejected.
    function test_simple_revertsOnWrongDelegate() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Delegation[] memory delegations_ = _signedGaslessSwap(relayer, swapCallData_);
        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) =
            _redeemArgs(delegations_, ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(address(token), 0, swapCallData_));

        vm.prank(makeAddr("NotTheDelegate"));
        vm.expectRevert(IDelegationManager.InvalidDelegate.selector);
        simpleManager.redeemDelegations(pc_, modes_, ecd_);
    }

    /// @notice A broken authority link in a chain is rejected (exercises the combined-loop chain validation).
    function test_simple_revertsOnBrokenAuthorityChain() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);

        Delegation memory root_ = _signDelegationFor(
            IDelegationManager(address(simpleManager)),
            users.alice,
            _rootDelegation(address(users.bob.addr), users.alice.addr, new Caveat[](0))
        );
        // Leaf points to a WRONG authority (not the root's hash) -> InvalidAuthority.
        Delegation memory leaf_ = _signDelegationFor(
            IDelegationManager(address(simpleManager)),
            users.bob,
            Delegation({
                delegate: relayer,
                delegator: users.bob.addr,
                authority: keccak256("not-the-root-hash"),
                caveats: _gaslessSwapCaveats(swapCallData_),
                salt: 0,
                signature: hex""
            })
        );

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;
        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) =
            _redeemArgs(delegations_, ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(address(token), 0, swapCallData_));

        vm.prank(relayer);
        vm.expectRevert(IDelegationManager.InvalidAuthority.selector);
        simpleManager.redeemDelegations(pc_, modes_, ecd_);
    }

    /// @notice A tampered/foreign signature is rejected (ERC-1271 path for the 7702 account).
    function test_simple_revertsOnInvalidSignature() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Delegation memory unsigned_ = _rootDelegation(relayer, users.alice.addr, _gaslessSwapCaveats(swapCallData_));
        // Sign with Bob's key for an Alice-delegator delegation -> recovers to Bob != Alice -> ERC1271 fails.
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signDelegationFor(IDelegationManager(address(simpleManager)), users.bob, unsigned_);

        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) =
            _redeemArgs(delegations_, ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(address(token), 0, swapCallData_));

        vm.prank(relayer);
        vm.expectRevert(IDelegationManager.InvalidERC1271Signature.selector);
        simpleManager.redeemDelegations(pc_, modes_, ecd_);
    }

    /// @notice A disabled delegation cannot be redeemed.
    function test_simple_revertsOnDisabledDelegation() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Delegation[] memory delegations_ = _signedGaslessSwap(relayer, swapCallData_);

        // The delegator (Alice's account) disables the delegation on the manager.
        vm.prank(users.alice.addr);
        simpleManager.disableDelegation(delegations_[0]);

        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) =
            _redeemArgs(delegations_, ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(address(token), 0, swapCallData_));

        vm.prank(relayer);
        vm.expectRevert(IDelegationManager.CannotUseADisabledDelegation.selector);
        simpleManager.redeemDelegations(pc_, modes_, ecd_);
    }

    /// @notice LimitedCallsEnforcer (limit = 1) blocks a second redemption of the same delegation.
    function test_simple_limitedCalls_blocksReplay() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        Delegation[] memory delegations_ = _signedGaslessSwap(relayer, swapCallData_);
        bytes memory execData_ = ExecutionLib.encodeSingle(address(token), 0, swapCallData_);

        _redeemSimple(relayer, delegations_, ModeLib.encodeSimpleSingle(), execData_);

        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) =
            _redeemArgs(delegations_, ModeLib.encodeSimpleSingle(), execData_);
        vm.prank(relayer);
        vm.expectRevert(bytes("LimitedCallsEnforcer:limit-exceeded"));
        simpleManager.redeemDelegations(pc_, modes_, ecd_);
    }

    ////////////////////////////// Comparisons //////////////////////////////

    /// @notice Baseline: single execution, no caveats. Pure manager + executeFromExecutor overhead.
    function test_compare_baseline_singleNoCaveats() public {
        Execution memory exec_ =
            Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });
        bytes memory execData_ = ExecutionLib.encodeSingle(exec_.target, exec_.value, exec_.callData);

        Delegation memory unsigned_ = _rootDelegation(relayer, users.alice.addr, new Caveat[](0));
        _runComparison("baseline | single execution | no caveats", unsigned_, users.alice, ModeLib.encodeSimpleSingle(), execData_);
        assertEq(counter.count(), 1, "counter incremented exactly once (post-revert state)");
    }

    /// @notice Gasless swap: single execution, ExactExecution + LimitedCalls.
    function test_compare_gaslessSwap_singleExecution() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        bytes memory execData_ = ExecutionLib.encodeSingle(address(token), 0, swapCallData_);

        Delegation memory unsigned_ = _rootDelegation(relayer, users.alice.addr, _gaslessSwapCaveats(swapCallData_));
        _runComparison(
            "gasless swap | single execution | ExactExecution + LimitedCalls",
            unsigned_,
            users.alice,
            ModeLib.encodeSimpleSingle(),
            execData_
        );
        assertEq(token.balanceOf(recipient), SWAP_AMOUNT, "swap proceeds reached recipient");
    }

    /// @notice Gasless transaction: 2-execution batch (user transfer + fee transfer), ExactExecutionBatch + LimitedCalls.
    function test_compare_gaslessTransaction_batchTwoExecutions() public {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, SEND_AMOUNT)
        });
        executions_[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, feeAccount, FEE_AMOUNT)
        });
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ enforcer: address(exactExecutionBatchEnforcer), terms: ExecutionLib.encodeBatch(executions_), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });

        Delegation memory unsigned_ = _rootDelegation(relayer, users.alice.addr, caveats_);
        _runComparison(
            "gasless transaction | 2-exec batch | ExactExecutionBatch + LimitedCalls",
            unsigned_,
            users.alice,
            ModeLib.encodeSimpleBatch(),
            execData_
        );
        assertEq(token.balanceOf(recipient), SEND_AMOUNT, "user action reached recipient");
        assertEq(token.balanceOf(feeAccount), FEE_AMOUNT, "fee leg reached fee account");
    }

    /// @notice Gasless swap over a 2-link chain (root Alice->Bob, leaf Bob->relayer): measures leaf-to-root validation cost.
    function test_compare_gaslessSwap_chainedDelegation() public {
        bytes memory swapCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT);
        bytes memory execData_ = ExecutionLib.encodeSingle(address(token), 0, swapCallData_);
        ModeCode mode_ = ModeLib.encodeSimpleSingle();

        // Build the unsigned chain once; sign per-manager domain inside the comparison.
        Delegation memory rootUnsigned_ = _rootDelegation(address(users.bob.addr), users.alice.addr, new Caveat[](0));
        Delegation memory leafUnsigned_ = Delegation({
            delegate: relayer,
            delegator: users.bob.addr,
            authority: bytes32(0), // set after the root is signed (authority excludes signature, so hash is stable)
            caveats: _gaslessSwapCaveats(swapCallData_),
            salt: 0,
            signature: hex""
        });

        bytes memory cd_;
        uint256 currentGas_;
        uint256 simpleGas_;

        uint256 snap_ = vm.snapshot();
        (currentGas_, cd_) =
            _measureChained(IDelegationManager(address(currentManager)), rootUnsigned_, leafUnsigned_, mode_, execData_);
        assertEq(token.balanceOf(recipient), SWAP_AMOUNT, "chained swap (current) reached recipient");
        vm.revertTo(snap_);
        (simpleGas_,) = _measureChained(IDelegationManager(address(simpleManager)), rootUnsigned_, leafUnsigned_, mode_, execData_);
        assertEq(token.balanceOf(recipient), SWAP_AMOUNT, "chained swap (simple) reached recipient");

        _report("gasless swap | chained (root Alice->Bob, leaf Bob->relayer)", currentGas_, simpleGas_, cd_);
        assertLt(simpleGas_, currentGas_, "SimpleDelegationManager should cost less than DelegationManager");
    }

    ////////////////////////////// Internal: comparison drivers //////////////////////////////

    /// @dev Signs `_unsigned` for each manager's domain and measures both from an identical cold state, then reports.
    function _runComparison(
        string memory _label,
        Delegation memory _unsigned,
        TestUser memory _signer,
        ModeCode _mode,
        bytes memory _execData
    )
        internal
    {
        Delegation[] memory forCurrent_ = new Delegation[](1);
        forCurrent_[0] = _signDelegationFor(IDelegationManager(address(currentManager)), _signer, _unsigned);
        Delegation[] memory forSimple_ = new Delegation[](1);
        forSimple_[0] = _signDelegationFor(IDelegationManager(address(simpleManager)), _signer, _unsigned);

        uint256 snap_ = vm.snapshot();
        (uint256 currentGas_, bytes memory cd_) =
            _measureRedeem(IDelegationManager(address(currentManager)), relayer, forCurrent_, _mode, _execData);
        // Capture the canonical manager's observable effect, then revert and run the simple manager from the same cold state.
        (uint256 curRecipient_, uint256 curFee_, uint256 curCounter_) =
            (token.balanceOf(recipient), token.balanceOf(feeAccount), counter.count());

        vm.revertTo(snap_);
        (uint256 simpleGas_,) = _measureRedeem(IDelegationManager(address(simpleManager)), relayer, forSimple_, _mode, _execData);

        // Functional equivalence: both managers must produce byte-identical observable effects on the tracked state.
        assertEq(token.balanceOf(recipient), curRecipient_, "recipient effect must match across managers");
        assertEq(token.balanceOf(feeAccount), curFee_, "fee effect must match across managers");
        assertEq(counter.count(), curCounter_, "counter effect must match across managers");

        _report(_label, currentGas_, simpleGas_, cd_);
        assertLt(simpleGas_, currentGas_, "SimpleDelegationManager should cost less than DelegationManager");
    }

    /// @dev Signs and measures a 2-link chain (root signed by Alice, leaf signed by Bob) for a given manager.
    function _measureChained(
        IDelegationManager _manager,
        Delegation memory _rootUnsigned,
        Delegation memory _leafUnsigned,
        ModeCode _mode,
        bytes memory _execData
    )
        internal
        returns (uint256 executionGas_, bytes memory cd_)
    {
        Delegation memory root_ = _signDelegationFor(_manager, users.alice, _rootUnsigned);
        _leafUnsigned.authority = EncoderLib._getDelegationHash(root_);
        Delegation memory leaf_ = _signDelegationFor(_manager, users.bob, _leafUnsigned);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;

        return _measureRedeem(_manager, relayer, delegations_, _mode, _execData);
    }

    /// @dev Measures ONLY the redeemDelegations call (gasleft bracket, pre-encoded calldata, low-level call from `redeemer`).
    function _measureRedeem(
        IDelegationManager _manager,
        address _redeemer,
        Delegation[] memory _delegations,
        ModeCode _mode,
        bytes memory _execData
    )
        internal
        returns (uint256 executionGas_, bytes memory cd_)
    {
        bytes[] memory pc_ = new bytes[](1);
        pc_[0] = abi.encode(_delegations);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        bytes[] memory ecd_ = new bytes[](1);
        ecd_[0] = _execData;

        cd_ = abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, pc_, modes_, ecd_);

        vm.prank(_redeemer);
        uint256 gasBefore_ = gasleft();
        (bool ok_, bytes memory ret_) = address(_manager).call(cd_);
        executionGas_ = gasBefore_ - gasleft();
        if (!ok_) {
            assembly {
                revert(add(ret_, 0x20), mload(ret_))
            }
        }
    }

    /// @dev Prints the side-by-side gas report for one scenario.
    function _report(string memory _label, uint256 _currentGas, uint256 _simpleGas, bytes memory _cd) internal view {
        uint256 calldataGas_ = _calldataGas(_cd);
        uint256 saved_ = _currentGas > _simpleGas ? _currentGas - _simpleGas : 0;
        uint256 pctBps_ = _currentGas > 0 ? (saved_ * 10_000) / _currentGas : 0;

        console.log("=====================================================================");
        console.log(_label);
        console.log(string.concat("  DelegationManager       exec gas .. ", vm.toString(_currentGas)));
        console.log(string.concat("  SimpleDelegationManager exec gas .. ", vm.toString(_simpleGas)));
        console.log(string.concat("  saved (exec gas) .................. ", vm.toString(saved_)));
        console.log(string.concat("  saved (%, basis points) ........... ", vm.toString(pctBps_)));
        console.log(string.concat("  calldata gas (identical) .......... ", vm.toString(calldataGas_)));
        console.log(
            string.concat(
                "  est. tx gas  current / simple ..... ",
                vm.toString(INTRINSIC_GAS + calldataGas_ + _currentGas),
                " / ",
                vm.toString(INTRINSIC_GAS + calldataGas_ + _simpleGas)
            )
        );
        console.log("=====================================================================");
    }

    ////////////////////////////// Internal: builders //////////////////////////////

    /// @dev Builds + signs (for SimpleDelegationManager's domain) a single gasless-swap root delegation.
    function _signedGaslessSwap(
        address _delegate,
        bytes memory _swapCallData
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Delegation memory unsigned_ = _rootDelegation(_delegate, users.alice.addr, _gaslessSwapCaveats(_swapCallData));
        delegations_ = new Delegation[](1);
        delegations_[0] = _signDelegationFor(IDelegationManager(address(simpleManager)), users.alice, unsigned_);
    }

    /// @dev Redeems through SimpleDelegationManager (no gas measurement); reverts bubble to the test.
    function _redeemSimple(address _redeemer, Delegation[] memory _delegations, ModeCode _mode, bytes memory _execData) internal {
        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) = _redeemArgs(_delegations, _mode, _execData);
        vm.prank(_redeemer);
        simpleManager.redeemDelegations(pc_, modes_, ecd_);
    }

    /// @dev Packs the parallel arrays for a single redemption.
    function _redeemArgs(
        Delegation[] memory _delegations,
        ModeCode _mode,
        bytes memory _execData
    )
        internal
        pure
        returns (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_)
    {
        pc_ = new bytes[](1);
        pc_[0] = abi.encode(_delegations);
        modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        ecd_ = new bytes[](1);
        ecd_[0] = _execData;
    }

    function _gaslessSwapCaveats(bytes memory _swapCallData) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            enforcer: address(exactExecutionEnforcer),
            terms: ExecutionLib.encodeSingle(address(token), 0, _swapCallData),
            args: hex""
        });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
    }

    function _rootDelegation(
        address _delegate,
        address _delegator,
        Caveat[] memory _caveats
    )
        internal
        view
        returns (Delegation memory)
    {
        return Delegation({
            delegate: _delegate, delegator: _delegator, authority: ROOT_AUTHORITY, caveats: _caveats, salt: 0, signature: hex""
        });
    }

    /// @dev Signs a delegation against a specific manager's EIP-712 domain (verifyingContract = manager).
    function _signDelegationFor(
        IDelegationManager _manager,
        TestUser memory _signer,
        Delegation memory _delegation
    )
        internal
        view
        returns (Delegation memory signed_)
    {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(_manager.getDomainHash(), delegationHash_);
        // Construct a fresh struct (do NOT alias `_delegation`, or signing twice would overwrite the shared signature field).
        signed_ = Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: SigningUtilsLib.signHash_EOA(_signer.privateKey, typedDataHash_)
        });
    }

    ////////////////////////////// Internal: helpers //////////////////////////////

    /// @dev Installs the EIP-7702 delegation designator (0xef0100 || impl) onto an EOA — the upgrade, excluded from measurement.
    function _etchMultiManager(address _eoa) internal {
        vm.etch(_eoa, bytes.concat(hex"ef0100", abi.encodePacked(address(multiManagerImpl))));
    }

    /// @dev Mines a CREATE2 salt until the deployed address's low nibble equals BEFORE_HOOK_FLAG, then deploys via SimpleFactory.
    function _deployFlagged(bytes memory _creationCode) internal returns (address addr_) {
        bytes32 codeHash_ = keccak256(_creationCode);
        for (uint256 salt_;; ++salt_) {
            address predicted_ = simpleFactory.computeAddress(codeHash_, bytes32(salt_));
            if (uint160(predicted_) & HookFlagsLib.HOOK_FLAG_MASK == HookFlagsLib.BEFORE_HOOK_FLAG) {
                return simpleFactory.deploy(_creationCode, bytes32(salt_));
            }
        }
    }

    function _assertBeforeHookOnly(address _enforcer) internal {
        assertTrue(HookFlagsLib.hasFlag(_enforcer, HookFlagsLib.BEFORE_HOOK_FLAG), "missing BEFORE_HOOK_FLAG");
        assertFalse(HookFlagsLib.hasFlag(_enforcer, HookFlagsLib.AFTER_HOOK_FLAG), "unexpected AFTER_HOOK_FLAG");
        assertFalse(HookFlagsLib.hasFlag(_enforcer, HookFlagsLib.BEFORE_ALL_HOOK_FLAG), "unexpected BEFORE_ALL_HOOK_FLAG");
        assertFalse(HookFlagsLib.hasFlag(_enforcer, HookFlagsLib.AFTER_ALL_HOOK_FLAG), "unexpected AFTER_ALL_HOOK_FLAG");
    }

    /// @dev EIP-2028 calldata cost: 4 gas per zero byte, 16 per non-zero byte.
    function _calldataGas(bytes memory _data) internal pure returns (uint256 gas_) {
        uint256 len_ = _data.length;
        for (uint256 i; i < len_; ++i) {
            gas_ += _data[i] == 0x00 ? 4 : 16;
        }
    }
}
