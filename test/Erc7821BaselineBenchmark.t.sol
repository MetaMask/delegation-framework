// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution } from "../src/utils/Types.sol";
import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";

import { EIP7702BatchDeleGator } from "../src/EIP7702/EIP7702BatchDeleGator.sol";

/**
 * @title ERC-7821 relay-batch gas baseline (the floor to beat)
 *
 * @notice Benchmarks the ADR Option-1 ERC-7821 signed relay-batch flow on an EIP-7702 account: the relayer submits
 *         `executeBatch(MODE_BATCH_WITH_OPDATA, abi.encode(Execution[], opData))` directly to the user's EOA, which validates
 *         an EIP-712 `BatchAuthorizationWithNonce` signature + an unordered nonce bitmap, then executes the batch. There is no
 *         DelegationManager, no caveat enforcers, and no EntryPoint — this is the lower-gas execution shape the optimized
 *         `SimpleDelegationManager` is being measured against.
 *
 * @dev Same measurement methodology as the other benchmarks: the 7702 designator is installed with `vm.etch` in setUp (so the
 *      upgrade is excluded), and only the `executeBatch` call is bracketed with `gasleft()`. Reports execution gas, calldata
 *      gas (EIP-2028), and the estimated standalone tx gas (21k intrinsic + calldata + execution). Run with `-vv`.
 *
 * @dev Uses the EIP7702BatchDeleGator from branch `cursor/eip7702-batch-delegator-o1-1-o1-2`.
 */
contract Erc7821BaselineBenchmark is BaseTest {
    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    uint256 internal constant INTRINSIC_GAS = 21_000;
    uint256 internal constant SWAP_AMOUNT = 100e18;
    uint256 internal constant SEND_AMOUNT = 50e18;
    uint256 internal constant FEE_AMOUNT = 1e18;

    EIP7702BatchDeleGator internal batchImpl;
    BasicERC20 internal token;

    address internal relayer;
    address internal recipient;
    address internal feeAccount;

    function setUp() public override {
        super.setUp();

        // Deploy the ERC-7821 batch DeleGator implementation and install it on Alice's EOA (the upgrade is excluded).
        batchImpl = new EIP7702BatchDeleGator(delegationManager, entryPoint);
        vm.label(address(batchImpl), "EIP7702BatchDeleGator Impl");
        vm.etch(users.alice.addr, bytes.concat(hex"ef0100", abi.encodePacked(address(batchImpl))));

        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(users.alice.addr, 1_000_000e18);
        vm.label(address(token), "MockUSDC");

        relayer = makeAddr("Relayer");
        recipient = makeAddr("Recipient");
        feeAccount = makeAddr("MetaMaskFeeAccount");
    }

    /// @notice ERC-7821 floor for the gasless swap: a 1-execution signed batch.
    function test_bench_erc7821_swap() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, SWAP_AMOUNT)
        });

        _benchExecuteBatch("ERC-7821 floor | gasless swap | 1-exec signed batch", executions_);
        assertEq(token.balanceOf(recipient), SWAP_AMOUNT, "swap proceeds reached recipient");
    }

    /// @notice ERC-7821 floor for the gasless transaction: a 2-execution signed batch (user action + fee).
    function test_bench_erc7821_gaslessTransaction() public {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, SEND_AMOUNT)
        });
        executions_[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, feeAccount, FEE_AMOUNT)
        });

        _benchExecuteBatch("ERC-7821 floor | gasless transaction | 2-exec signed batch", executions_);
        assertEq(token.balanceOf(recipient), SEND_AMOUNT, "user action reached recipient");
        assertEq(token.balanceOf(feeAccount), FEE_AMOUNT, "fee leg reached fee account");
    }

    ////////////////////////////// Internal //////////////////////////////

    /// @dev Builds a relayer-signed ERC-7821 batch authorization and measures ONLY the executeBatch call.
    function _benchExecuteBatch(string memory _label, Execution[] memory _executions) internal {
        EIP7702BatchDeleGator account_ = EIP7702BatchDeleGator(payable(users.alice.addr));

        uint256 nonce_ = 1;
        uint256 deadline_ = block.timestamp + 1 hours;

        bytes32 digest_ = account_.hashBatchAuthorizationWithNonce(_executions, nonce_, deadline_, relayer);
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, digest_);
        bytes memory opData_ = abi.encode(nonce_, deadline_, relayer, signature_);
        bytes memory executionData_ = abi.encode(_executions, opData_);

        bytes memory cd_ =
            abi.encodeWithSelector(EIP7702BatchDeleGator.executeBatch.selector, account_.MODE_BATCH_WITH_OPDATA(), executionData_);

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool ok_, bytes memory ret_) = address(account_).call(cd_);
        uint256 executionGas_ = gasBefore_ - gasleft();
        if (!ok_) {
            assembly {
                revert(add(ret_, 0x20), mload(ret_))
            }
        }

        uint256 calldataGas_ = _calldataGas(cd_);
        console.log("=====================================================================");
        console.log(_label);
        console.log(string.concat("  executeBatch execution gas ........ ", vm.toString(executionGas_)));
        console.log(string.concat("  calldata size (bytes) ............. ", vm.toString(cd_.length)));
        console.log(string.concat("  calldata gas (EIP-2028) ........... ", vm.toString(calldataGas_)));
        console.log(
            string.concat("  est. standalone tx gas (excl. 7702) ", vm.toString(INTRINSIC_GAS + calldataGas_ + executionGas_))
        );
        console.log("=====================================================================");
    }

    function _calldataGas(bytes memory _data) internal pure returns (uint256 gas_) {
        uint256 len_ = _data.length;
        for (uint256 i; i < len_; ++i) {
            gas_ += _data[i] == 0x00 ? 4 : 16;
        }
    }
}
