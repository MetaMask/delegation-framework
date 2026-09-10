// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "../../src/enforcers/CaveatEnforcer.sol";
import { MetaSwapBatchCalldataEnforcer } from "../../src/enforcers/MetaSwapBatchCalldataEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { MockLimitOrderRouter } from "../utils/MockLimitOrderRouter.sol";

abstract contract MetaSwapHashEnforcerBase is CaveatEnforcer {
    using ExecutionLib for bytes;

    bytes32 internal constant APPROVAL_TYPEHASH = keccak256("MetaSwapApproval(address target,uint256 value,bytes32 callDataHash)");
    bytes32 internal constant SWAP_TYPEHASH =
        keccak256("MetaSwapSwap(address target,uint256 value,bytes4 selector,address tokenFrom,uint256 amount)");
    bytes32 internal constant APPROVAL_SEQUENCE_TYPEHASH =
        keccak256("MetaSwapApprovalSequence(bytes32 firstApproval,bytes32 secondApproval)");
    bytes32 internal constant BATCH_TYPEHASH =
        keccak256("MetaSwapBatch(uint8 executionCount,bytes32 approvalSequenceHash,bytes32 swapHash)");

    uint256 internal constant SWAP_CALL_MIN_LENGTH = 132;

    function _approvalHash(Execution calldata execution_) internal pure returns (bytes32) {
        return keccak256(abi.encode(APPROVAL_TYPEHASH, execution_.target, execution_.value, keccak256(execution_.callData)));
    }

    function _swapHash(Execution calldata execution_) internal pure returns (bytes32) {
        bytes calldata callData_ = execution_.callData;
        require(callData_.length >= SWAP_CALL_MIN_LENGTH, "MetaSwapHashEnforcer:invalid-swap");
        return keccak256(
            abi.encode(
                SWAP_TYPEHASH,
                execution_.target,
                execution_.value,
                bytes4(callData_[0:4]),
                address(uint160(uint256(bytes32(callData_[36:68])))),
                uint256(bytes32(callData_[68:100]))
            )
        );
    }

    function _approvalSequenceAndSwap(Execution[] calldata executions_)
        internal
        pure
        returns (bytes32 approvalSequenceHash_, bytes32 swapHash_)
    {
        uint256 length_ = executions_.length;
        require(length_ >= 1 && length_ <= 3, "MetaSwapHashEnforcer:invalid-batch-length");

        if (length_ == 1) {
            swapHash_ = _swapHash(executions_[0]);
        } else if (length_ == 2) {
            approvalSequenceHash_ = _approvalHash(executions_[0]);
            swapHash_ = _swapHash(executions_[1]);
        } else {
            approvalSequenceHash_ =
                keccak256(abi.encode(APPROVAL_SEQUENCE_TYPEHASH, _approvalHash(executions_[0]), _approvalHash(executions_[1])));
            swapHash_ = _swapHash(executions_[2]);
        }
    }
}

/// @notice Compares every approval hash independently and compares one partial swap hash.
contract IndividualExecutionHashEnforcer is MetaSwapHashEnforcerBase {
    using ExecutionLib for bytes;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        uint256 length_ = executions_.length;
        require(length_ >= 1 && length_ <= 3, "IndividualExecutionHashEnforcer:invalid-batch-length");
        require(terms_.length == length_ * 32, "IndividualExecutionHashEnforcer:invalid-terms");

        if (length_ == 1) {
            require(_swapHash(executions_[0]) == bytes32(terms_[0:32]), "IndividualExecutionHashEnforcer:invalid-swap");
        } else if (length_ == 2) {
            require(_approvalHash(executions_[0]) == bytes32(terms_[0:32]), "IndividualExecutionHashEnforcer:invalid-approval");
            require(_swapHash(executions_[1]) == bytes32(terms_[32:64]), "IndividualExecutionHashEnforcer:invalid-swap");
        } else {
            require(_approvalHash(executions_[0]) == bytes32(terms_[0:32]), "IndividualExecutionHashEnforcer:invalid-approval");
            require(_approvalHash(executions_[1]) == bytes32(terms_[32:64]), "IndividualExecutionHashEnforcer:invalid-approval");
            require(_swapHash(executions_[2]) == bytes32(terms_[64:96]), "IndividualExecutionHashEnforcer:invalid-swap");
        }
    }
}

/// @notice Compares one approval-sequence hash and one partial swap hash.
contract ApprovalSequenceHashEnforcer is MetaSwapHashEnforcerBase {
    using ExecutionLib for bytes;

    uint256 private constant TERMS_LENGTH = 64;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        require(terms_.length == TERMS_LENGTH, "ApprovalSequenceHashEnforcer:invalid-terms");
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        (bytes32 approvalSequenceHash_, bytes32 swapHash_) = _approvalSequenceAndSwap(executions_);
        require(approvalSequenceHash_ == bytes32(terms_[0:32]), "ApprovalSequenceHashEnforcer:invalid-approval-sequence");
        require(swapHash_ == bytes32(terms_[32:64]), "ApprovalSequenceHashEnforcer:invalid-swap");
    }
}

/// @notice Compares one hash committing to the execution count, approval sequence, and partial swap hash.
contract CombinedConstraintHashEnforcer is MetaSwapHashEnforcerBase {
    using ExecutionLib for bytes;

    uint256 private constant TERMS_LENGTH = 32;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        require(terms_.length == TERMS_LENGTH, "CombinedConstraintHashEnforcer:invalid-terms");
        bytes32 constraintHash_ = _constraintHash(executionCallData_);
        require(constraintHash_ == bytes32(terms_[0:32]), "CombinedConstraintHashEnforcer:invalid-constraints");
    }

    function _constraintHash(bytes calldata executionCallData_) private pure returns (bytes32) {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        (bytes32 approvalSequenceHash_, bytes32 swapHash_) = _approvalSequenceAndSwap(executions_);
        return keccak256(abi.encode(BATCH_TYPEHASH, uint8(executions_.length), approvalSequenceHash_, swapHash_));
    }
}

/// @notice Uses the swap hash directly for native and one combined constraint hash for ERC-20 batches.
contract HybridConstraintHashEnforcer is MetaSwapHashEnforcerBase {
    using ExecutionLib for bytes;

    uint256 private constant TERMS_LENGTH = 32;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        require(terms_.length == TERMS_LENGTH, "HybridConstraintHashEnforcer:invalid-terms");
        bytes32 constraintHash_ = _constraintHash(executionCallData_);
        require(constraintHash_ == bytes32(terms_[0:32]), "HybridConstraintHashEnforcer:invalid-constraints");
    }

    function _constraintHash(bytes calldata executionCallData_) private pure returns (bytes32) {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        (bytes32 approvalSequenceHash_, bytes32 swapHash_) = _approvalSequenceAndSwap(executions_);
        return executions_.length == 1
            ? swapHash_
            : keccak256(abi.encode(BATCH_TYPEHASH, uint8(executions_.length), approvalSequenceHash_, swapHash_));
    }
}

/// @notice Uses one fixed-field hash per approval instead of hashing approval calldata separately.
contract CombinedFieldHashEnforcer is MetaSwapHashEnforcerBase {
    using ExecutionLib for bytes;

    bytes32 private constant APPROVAL_FIELDS_TYPEHASH = keccak256(
        "MetaSwapApprovalFields(address target,uint256 value,bytes4 selector,address spender,uint256 amount)"
    );
    uint256 private constant TERMS_LENGTH = 32;
    uint256 private constant APPROVAL_CALL_LENGTH = 68;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        require(terms_.length == TERMS_LENGTH, "CombinedFieldHashEnforcer:invalid-terms");
        bytes32 constraintHash_ = _constraintHash(executionCallData_);
        require(constraintHash_ == bytes32(terms_[0:32]), "CombinedFieldHashEnforcer:invalid-constraints");
    }

    function _constraintHash(bytes calldata executionCallData_) private pure returns (bytes32) {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        uint256 length_ = executions_.length;
        require(length_ >= 1 && length_ <= 3, "CombinedFieldHashEnforcer:invalid-batch-length");

        bytes32 approvalSequenceHash_;
        bytes32 swapHash_;
        if (length_ == 1) {
            swapHash_ = _swapHash(executions_[0]);
        } else if (length_ == 2) {
            approvalSequenceHash_ = _approvalFieldsHash(executions_[0]);
            swapHash_ = _swapHash(executions_[1]);
        } else {
            approvalSequenceHash_ = keccak256(
                abi.encode(
                    APPROVAL_SEQUENCE_TYPEHASH,
                    _approvalFieldsHash(executions_[0]),
                    _approvalFieldsHash(executions_[1])
                )
            );
            swapHash_ = _swapHash(executions_[2]);
        }
        return keccak256(abi.encode(BATCH_TYPEHASH, uint8(length_), approvalSequenceHash_, swapHash_));
    }

    function _approvalFieldsHash(Execution calldata execution_) private pure returns (bytes32) {
        bytes calldata callData_ = execution_.callData;
        require(callData_.length == APPROVAL_CALL_LENGTH, "CombinedFieldHashEnforcer:invalid-approval");
        return keccak256(
            abi.encode(
                APPROVAL_FIELDS_TYPEHASH,
                execution_.target,
                execution_.value,
                bytes4(callData_[0:4]),
                address(uint160(uint256(bytes32(callData_[4:36])))),
                uint256(bytes32(callData_[36:68]))
            )
        );
    }
}

/// @notice Keeps domain separation only on the final signed constraint commitment.
contract OuterTypehashConstraintEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    bytes32 private constant BATCH_TYPEHASH =
        keccak256("MetaSwapBatch(uint8 executionCount,bytes32 approvalSequenceHash,bytes32 swapHash)");
    uint256 private constant TERMS_LENGTH = 32;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 132;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        require(terms_.length == TERMS_LENGTH, "OuterTypehashConstraintEnforcer:invalid-terms");
        bytes32 constraintHash_ = _constraintHash(executionCallData_);
        require(constraintHash_ == bytes32(terms_[0:32]), "OuterTypehashConstraintEnforcer:invalid-constraints");
    }

    function _constraintHash(bytes calldata executionCallData_) private pure returns (bytes32) {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        uint256 length_ = executions_.length;
        require(length_ >= 1 && length_ <= 3, "OuterTypehashConstraintEnforcer:invalid-batch-length");

        bytes32 approvalSequenceHash_;
        bytes32 swapHash_;
        if (length_ == 1) {
            swapHash_ = _swapHash(executions_[0]);
        } else if (length_ == 2) {
            approvalSequenceHash_ = _approvalHash(executions_[0]);
            swapHash_ = _swapHash(executions_[1]);
        } else {
            approvalSequenceHash_ =
                keccak256(abi.encode(_approvalHash(executions_[0]), _approvalHash(executions_[1])));
            swapHash_ = _swapHash(executions_[2]);
        }
        return keccak256(abi.encode(BATCH_TYPEHASH, uint8(length_), approvalSequenceHash_, swapHash_));
    }

    function _approvalHash(Execution calldata execution_) private pure returns (bytes32) {
        return keccak256(abi.encode(execution_.target, execution_.value, keccak256(execution_.callData)));
    }

    function _swapHash(Execution calldata execution_) private pure returns (bytes32) {
        bytes calldata callData_ = execution_.callData;
        require(callData_.length >= SWAP_CALL_MIN_LENGTH, "OuterTypehashConstraintEnforcer:invalid-swap");
        return keccak256(
            abi.encode(
                execution_.target,
                execution_.value,
                bytes4(callData_[0:4]),
                address(uint160(uint256(bytes32(callData_[36:68])))),
                uint256(bytes32(callData_[68:100]))
            )
        );
    }
}

contract MetaSwapBatchHashGasComparisonTest is BaseTest {
    uint256 private constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 private constant TOKEN_OUT_AMOUNT = 200 ether;
    uint256 private constant INTRINSIC_GAS = 21_000;

    bytes32 private constant APPROVAL_TYPEHASH = keccak256("MetaSwapApproval(address target,uint256 value,bytes32 callDataHash)");
    bytes32 private constant SWAP_TYPEHASH =
        keccak256("MetaSwapSwap(address target,uint256 value,bytes4 selector,address tokenFrom,uint256 amount)");
    bytes32 private constant APPROVAL_SEQUENCE_TYPEHASH =
        keccak256("MetaSwapApprovalSequence(bytes32 firstApproval,bytes32 secondApproval)");
    bytes32 private constant APPROVAL_FIELDS_TYPEHASH = keccak256(
        "MetaSwapApprovalFields(address target,uint256 value,bytes4 selector,address spender,uint256 amount)"
    );
    bytes32 private constant BATCH_TYPEHASH =
        keccak256("MetaSwapBatch(uint8 executionCount,bytes32 approvalSequenceHash,bytes32 swapHash)");

    struct GasMeasurement {
        uint256 executionGas;
        uint256 calldataBytes;
        uint256 calldataGas;
        uint256 estimatedTransactionGas;
    }

    MetaSwapBatchCalldataEnforcer private baseline;
    IndividualExecutionHashEnforcer private individualHashes;
    ApprovalSequenceHashEnforcer private sequenceHash;
    CombinedConstraintHashEnforcer private combinedHash;
    HybridConstraintHashEnforcer private hybridHash;
    CombinedFieldHashEnforcer private combinedFieldHash;
    OuterTypehashConstraintEnforcer private outerTypehash;
    MockLimitOrderRouter private router;
    BasicERC20 private tokenIn;
    BasicERC20 private tokenOut;
    address private relayer;

    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }

    function setUp() public override {
        super.setUp();

        router = new MockLimitOrderRouter();
        baseline = new MetaSwapBatchCalldataEnforcer();
        individualHashes = new IndividualExecutionHashEnforcer();
        sequenceHash = new ApprovalSequenceHashEnforcer();
        combinedHash = new CombinedConstraintHashEnforcer();
        hybridHash = new HybridConstraintHashEnforcer();
        combinedFieldHash = new CombinedFieldHashEnforcer();
        outerTypehash = new OuterTypehashConstraintEnforcer();
        tokenIn = new BasicERC20(address(users.alice.deleGator), "Token In", "TIN", 1_000 ether);
        tokenOut = new BasicERC20(address(router), "Token Out", "TOUT", 10_000 ether);
        relayer = makeAddr("Relayer");
        vm.deal(address(users.alice.deleGator), 1_000 ether);
    }

    function test_gas_baseline_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report("baseline / native", _measure(address(baseline), _baselineTerms(address(0), false), executions_));
    }

    function test_gas_individualHashes_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report("individual hashes / native", _measure(address(individualHashes), _individualTerms(executions_), executions_));
    }

    function test_gas_sequenceHash_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report(
            "approval-sequence + swap hashes / native", _measure(address(sequenceHash), _sequenceTerms(executions_), executions_)
        );
    }

    function test_gas_combinedHash_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report("combined hash / native", _measure(address(combinedHash), _combinedTerms(executions_), executions_));
    }

    function test_gas_hybridHash_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report("hybrid hash / native", _measure(address(hybridHash), _hybridTerms(executions_), executions_));
    }

    function test_gas_combinedFieldHash_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report(
            "combined field hash / native",
            _measure(address(combinedFieldHash), _combinedFieldTerms(executions_), executions_)
        );
    }

    function test_gas_outerTypehash_native() public {
        Execution[] memory executions_ = _nativeBatch("route-a");
        _report(
            "outer typehash only / native",
            _measure(address(outerTypehash), _outerTypehashTerms(executions_), executions_)
        );
    }

    function test_gas_baseline_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report("baseline / approve(amount)", _measure(address(baseline), _baselineTerms(address(tokenIn), false), executions_));
    }

    function test_gas_individualHashes_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report(
            "individual hashes / approve(amount)", _measure(address(individualHashes), _individualTerms(executions_), executions_)
        );
    }

    function test_gas_sequenceHash_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report(
            "approval-sequence + swap hashes / approve(amount)",
            _measure(address(sequenceHash), _sequenceTerms(executions_), executions_)
        );
    }

    function test_gas_combinedHash_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report("combined hash / approve(amount)", _measure(address(combinedHash), _combinedTerms(executions_), executions_));
    }

    function test_gas_hybridHash_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report("hybrid hash / approve(amount)", _measure(address(hybridHash), _hybridTerms(executions_), executions_));
    }

    function test_gas_combinedFieldHash_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report(
            "combined field hash / approve(amount)",
            _measure(address(combinedFieldHash), _combinedFieldTerms(executions_), executions_)
        );
    }

    function test_gas_outerTypehash_oneApproval() public {
        Execution[] memory executions_ = _erc20Batch(false, "route-a");
        _report(
            "outer typehash only / approve(amount)",
            _measure(address(outerTypehash), _outerTypehashTerms(executions_), executions_)
        );
    }

    function test_gas_baseline_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report(
            "baseline / approve(0) + approve(amount)",
            _measure(address(baseline), _baselineTerms(address(tokenIn), true), executions_)
        );
    }

    function test_gas_individualHashes_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report(
            "individual hashes / approve(0) + approve(amount)",
            _measure(address(individualHashes), _individualTerms(executions_), executions_)
        );
    }

    function test_gas_sequenceHash_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report(
            "approval-sequence + swap hashes / approve(0) + approve(amount)",
            _measure(address(sequenceHash), _sequenceTerms(executions_), executions_)
        );
    }

    function test_gas_combinedHash_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report(
            "combined hash / approve(0) + approve(amount)",
            _measure(address(combinedHash), _combinedTerms(executions_), executions_)
        );
    }

    function test_gas_hybridHash_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report("hybrid hash / approve(0) + approve(amount)", _measure(address(hybridHash), _hybridTerms(executions_), executions_));
    }

    function test_gas_combinedFieldHash_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report(
            "combined field hash / approve(0) + approve(amount)",
            _measure(address(combinedFieldHash), _combinedFieldTerms(executions_), executions_)
        );
    }

    function test_gas_outerTypehash_resetApproval() public {
        _setAllowance(1);
        Execution[] memory executions_ = _erc20Batch(true, "route-a");
        _report(
            "outer typehash only / approve(0) + approve(amount)",
            _measure(address(outerTypehash), _outerTypehashTerms(executions_), executions_)
        );
    }

    function test_hashTermsAllowDifferentDynamicRouteData() public {
        Execution[] memory signedExecutions_ = _erc20Batch(false, "route-a");
        Execution[] memory redeemedExecutions_ = _erc20Batch(false, "a-much-longer-route-name");
        redeemedExecutions_[1].callData =
            abi.encodeCall(IMetaSwap.swap, ("different-aggregator", tokenIn, TOKEN_IN_AMOUNT, _route()));

        _enforce(address(individualHashes), _individualTerms(signedExecutions_), redeemedExecutions_);
        _enforce(address(sequenceHash), _sequenceTerms(signedExecutions_), redeemedExecutions_);
        _enforce(address(combinedHash), _combinedTerms(signedExecutions_), redeemedExecutions_);
        _enforce(address(hybridHash), _hybridTerms(signedExecutions_), redeemedExecutions_);
        _enforce(address(combinedFieldHash), _combinedFieldTerms(signedExecutions_), redeemedExecutions_);
        _enforce(address(outerTypehash), _outerTypehashTerms(signedExecutions_), redeemedExecutions_);
    }

    function test_hashTermsRejectChangedApproval() public {
        Execution[] memory signedExecutions_ = _erc20Batch(false, "route-a");
        Execution[] memory tamperedExecutions_ = _erc20Batch(false, "route-a");
        tamperedExecutions_[0].callData = abi.encodeCall(IERC20.approve, (makeAddr("OtherSpender"), TOKEN_IN_AMOUNT));

        vm.expectRevert("IndividualExecutionHashEnforcer:invalid-approval");
        _enforce(address(individualHashes), _individualTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("ApprovalSequenceHashEnforcer:invalid-approval-sequence");
        _enforce(address(sequenceHash), _sequenceTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("CombinedConstraintHashEnforcer:invalid-constraints");
        _enforce(address(combinedHash), _combinedTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("HybridConstraintHashEnforcer:invalid-constraints");
        _enforce(address(hybridHash), _hybridTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("CombinedFieldHashEnforcer:invalid-constraints");
        _enforce(address(combinedFieldHash), _combinedFieldTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("OuterTypehashConstraintEnforcer:invalid-constraints");
        _enforce(address(outerTypehash), _outerTypehashTerms(signedExecutions_), tamperedExecutions_);
    }

    function test_hashTermsRejectChangedSwapStaticFields() public {
        Execution[] memory signedExecutions_ = _erc20Batch(false, "route-a");
        Execution[] memory tamperedExecutions_ = _erc20Batch(false, "route-a");
        tamperedExecutions_[1].callData =
            abi.encodeCall(IMetaSwap.swap, ("route-a", IERC20(makeAddr("OtherToken")), TOKEN_IN_AMOUNT, _route()));

        vm.expectRevert("IndividualExecutionHashEnforcer:invalid-swap");
        _enforce(address(individualHashes), _individualTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("ApprovalSequenceHashEnforcer:invalid-swap");
        _enforce(address(sequenceHash), _sequenceTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("CombinedConstraintHashEnforcer:invalid-constraints");
        _enforce(address(combinedHash), _combinedTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("HybridConstraintHashEnforcer:invalid-constraints");
        _enforce(address(hybridHash), _hybridTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("CombinedFieldHashEnforcer:invalid-constraints");
        _enforce(address(combinedFieldHash), _combinedFieldTerms(signedExecutions_), tamperedExecutions_);

        vm.expectRevert("OuterTypehashConstraintEnforcer:invalid-constraints");
        _enforce(address(outerTypehash), _outerTypehashTerms(signedExecutions_), tamperedExecutions_);
    }

    function test_runtimeCodeSizes() public view {
        console2.log("baseline runtime bytes", address(baseline).code.length);
        console2.log("individual hashes runtime bytes", address(individualHashes).code.length);
        console2.log("sequence hash runtime bytes", address(sequenceHash).code.length);
        console2.log("combined hash runtime bytes", address(combinedHash).code.length);
        console2.log("hybrid hash runtime bytes", address(hybridHash).code.length);
        console2.log("combined field hash runtime bytes", address(combinedFieldHash).code.length);
        console2.log("outer typehash only runtime bytes", address(outerTypehash).code.length);
    }

    function _measure(
        address enforcer_,
        bytes memory terms_,
        Execution[] memory executions_
    )
        private
        returns (GasMeasurement memory measurement_)
    {
        Delegation memory delegation_ = _delegation(enforcer_, terms_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes memory redeemCallData_ = _encodeRedeem(delegations_, ExecutionLib.encodeBatch(executions_));

        measurement_.calldataBytes = redeemCallData_.length;
        measurement_.calldataGas = _calldataGas(redeemCallData_);

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_,) = address(delegationManager).call(redeemCallData_);
        measurement_.executionGas = gasBefore_ - gasleft();
        assertTrue(success_);

        measurement_.estimatedTransactionGas = INTRINSIC_GAS + measurement_.calldataGas + measurement_.executionGas;
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
    }

    function _delegation(address enforcer_, bytes memory terms_) private view returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: enforcer_, terms: terms_, args: hex"" });
        delegation_ = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
    }

    function _encodeRedeem(Delegation[] memory delegations_, bytes memory executionCallData_) private pure returns (bytes memory) {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = executionCallData_;
        return
            abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
    }

    function _nativeBatch(string memory aggregatorId_) private view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = _swap(address(0), TOKEN_IN_AMOUNT, aggregatorId_);
    }

    function _erc20Batch(bool resetApproval_, string memory aggregatorId_) private view returns (Execution[] memory executions_) {
        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);
        if (resetApproval_) executions_[0] = _approval(0);
        executions_[swapIndex_ - 1] = _approval(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = _swap(address(tokenIn), 0, aggregatorId_);
    }

    function _approval(uint256 amount_) private view returns (Execution memory) {
        return
            Execution({ target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), amount_)) });
    }

    function _swap(address tokenIn_, uint256 value_, string memory aggregatorId_) private view returns (Execution memory) {
        return Execution({
            target: address(router),
            value: value_,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(tokenIn_), TOKEN_IN_AMOUNT, _route()))
        });
    }

    function _route() private view returns (bytes memory) {
        return abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT);
    }

    function _baselineTerms(address tokenIn_, bool resetApproval_) private view returns (bytes memory) {
        return abi.encodePacked(address(router), tokenIn_, TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00));
    }

    function _individualTerms(Execution[] memory executions_) private view returns (bytes memory terms_) {
        uint256 length_ = executions_.length;
        if (length_ == 1) {
            return abi.encodePacked(_swapHash(executions_[0], address(0)));
        }
        if (length_ == 2) {
            return abi.encodePacked(_approvalHash(executions_[0]), _swapHash(executions_[1], address(tokenIn)));
        }
        return abi.encodePacked(
            _approvalHash(executions_[0]), _approvalHash(executions_[1]), _swapHash(executions_[2], address(tokenIn))
        );
    }

    function _sequenceTerms(Execution[] memory executions_) private view returns (bytes memory) {
        (bytes32 approvalSequenceHash_, bytes32 swapHash_) = _approvalSequenceAndSwap(executions_);
        return abi.encodePacked(approvalSequenceHash_, swapHash_);
    }

    function _combinedTerms(Execution[] memory executions_) private view returns (bytes memory) {
        (bytes32 approvalSequenceHash_, bytes32 swapHash_) = _approvalSequenceAndSwap(executions_);
        return abi.encodePacked(keccak256(abi.encode(BATCH_TYPEHASH, uint8(executions_.length), approvalSequenceHash_, swapHash_)));
    }

    function _hybridTerms(Execution[] memory executions_) private view returns (bytes memory) {
        if (executions_.length == 1) return abi.encodePacked(_swapHash(executions_[0], address(0)));
        return _combinedTerms(executions_);
    }

    function _combinedFieldTerms(Execution[] memory executions_) private view returns (bytes memory) {
        uint256 length_ = executions_.length;
        bytes32 approvalSequenceHash_;
        bytes32 swapHash_;
        if (length_ == 1) {
            swapHash_ = _swapHash(executions_[0], address(0));
        } else if (length_ == 2) {
            approvalSequenceHash_ = _approvalFieldsHash(TOKEN_IN_AMOUNT);
            swapHash_ = _swapHash(executions_[1], address(tokenIn));
        } else {
            approvalSequenceHash_ = keccak256(
                abi.encode(
                    APPROVAL_SEQUENCE_TYPEHASH,
                    _approvalFieldsHash(0),
                    _approvalFieldsHash(TOKEN_IN_AMOUNT)
                )
            );
            swapHash_ = _swapHash(executions_[2], address(tokenIn));
        }
        return abi.encodePacked(keccak256(abi.encode(BATCH_TYPEHASH, uint8(length_), approvalSequenceHash_, swapHash_)));
    }

    function _outerTypehashTerms(Execution[] memory executions_) private view returns (bytes memory) {
        uint256 length_ = executions_.length;
        bytes32 approvalSequenceHash_;
        bytes32 swapHash_;
        if (length_ == 1) {
            swapHash_ = _swapHashWithoutTypehash(executions_[0], address(0));
        } else if (length_ == 2) {
            approvalSequenceHash_ = _approvalHashWithoutTypehash(executions_[0]);
            swapHash_ = _swapHashWithoutTypehash(executions_[1], address(tokenIn));
        } else {
            approvalSequenceHash_ = keccak256(
                abi.encode(
                    _approvalHashWithoutTypehash(executions_[0]),
                    _approvalHashWithoutTypehash(executions_[1])
                )
            );
            swapHash_ = _swapHashWithoutTypehash(executions_[2], address(tokenIn));
        }
        return abi.encodePacked(keccak256(abi.encode(BATCH_TYPEHASH, uint8(length_), approvalSequenceHash_, swapHash_)));
    }

    function _approvalSequenceAndSwap(Execution[] memory executions_)
        private
        view
        returns (bytes32 approvalSequenceHash_, bytes32 swapHash_)
    {
        if (executions_.length == 1) {
            swapHash_ = _swapHash(executions_[0], address(0));
        } else if (executions_.length == 2) {
            approvalSequenceHash_ = _approvalHash(executions_[0]);
            swapHash_ = _swapHash(executions_[1], address(tokenIn));
        } else {
            approvalSequenceHash_ =
                keccak256(abi.encode(APPROVAL_SEQUENCE_TYPEHASH, _approvalHash(executions_[0]), _approvalHash(executions_[1])));
            swapHash_ = _swapHash(executions_[2], address(tokenIn));
        }
    }

    function _approvalHash(Execution memory execution_) private pure returns (bytes32) {
        return keccak256(abi.encode(APPROVAL_TYPEHASH, execution_.target, execution_.value, keccak256(execution_.callData)));
    }

    function _approvalHashWithoutTypehash(Execution memory execution_) private pure returns (bytes32) {
        return keccak256(abi.encode(execution_.target, execution_.value, keccak256(execution_.callData)));
    }

    function _approvalFieldsHash(uint256 amount_) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                APPROVAL_FIELDS_TYPEHASH,
                address(tokenIn),
                uint256(0),
                IERC20.approve.selector,
                address(router),
                amount_
            )
        );
    }

    function _swapHash(Execution memory execution_, address tokenIn_) private pure returns (bytes32) {
        return keccak256(
            abi.encode(SWAP_TYPEHASH, execution_.target, execution_.value, IMetaSwap.swap.selector, tokenIn_, TOKEN_IN_AMOUNT)
        );
    }

    function _swapHashWithoutTypehash(Execution memory execution_, address tokenIn_) private pure returns (bytes32) {
        return keccak256(
            abi.encode(execution_.target, execution_.value, IMetaSwap.swap.selector, tokenIn_, TOKEN_IN_AMOUNT)
        );
    }

    function _setAllowance(uint256 amount_) private {
        vm.prank(address(users.alice.deleGator));
        tokenIn.approve(address(router), amount_);
    }

    function _enforce(address enforcer_, bytes memory terms_, Execution[] memory executions_) private {
        CaveatEnforcer(enforcer_)
            .beforeHook(
                terms_,
                hex"",
                ModeLib.encodeSimpleBatch(),
                ExecutionLib.encodeBatch(executions_),
                bytes32(0),
                address(users.alice.deleGator),
                relayer
            );
    }

    function _calldataGas(bytes memory data_) private pure returns (uint256 gas_) {
        for (uint256 i_; i_ < data_.length; ++i_) {
            gas_ += data_[i_] == 0 ? 4 : 16;
        }
    }

    function _report(string memory label_, GasMeasurement memory measurement_) private pure {
        console2.log(label_);
        console2.log("  execution gas", measurement_.executionGas);
        console2.log("  calldata bytes", measurement_.calldataBytes);
        console2.log("  calldata gas", measurement_.calldataGas);
        console2.log("  estimated transaction gas", measurement_.estimatedTransactionGas);
    }
}
