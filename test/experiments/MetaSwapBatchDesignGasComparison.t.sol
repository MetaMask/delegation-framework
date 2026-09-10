// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "../../src/enforcers/CaveatEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { MetaSwapBatchCalldataEnforcer } from "../../src/enforcers/MetaSwapBatchCalldataEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { MockLimitOrderRouter } from "../utils/MockLimitOrderRouter.sol";

abstract contract MetaSwapDesignValidationBase is CaveatEnforcer {
    uint256 internal constant APPROVE_CALL_LENGTH = 68;
    uint256 internal constant SWAP_CALL_MIN_LENGTH = 132;

    function _validateApproval(
        Execution calldata execution_,
        address tokenIn_,
        address metaSwap_,
        uint256 expectedAmount_
    )
        internal
        pure
    {
        bytes calldata callData_ = execution_.callData;
        require(
            execution_.target == tokenIn_ && execution_.value == 0 && callData_.length == APPROVE_CALL_LENGTH
                && bytes4(callData_[0:4]) == IERC20.approve.selector
                && address(uint160(uint256(bytes32(callData_[4:36])))) == metaSwap_
                && uint256(bytes32(callData_[36:68])) == expectedAmount_,
            "MetaSwapDesignValidationBase:invalid-approval"
        );
    }

    function _validateSwap(
        address target_,
        uint256 value_,
        bytes calldata callData_,
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint256 expectedValue_
    )
        internal
        pure
    {
        require(
            target_ == metaSwap_ && value_ == expectedValue_ && callData_.length >= SWAP_CALL_MIN_LENGTH
                && bytes4(callData_[0:4]) == IMetaSwap.swap.selector
                && address(uint160(uint256(bytes32(callData_[36:68])))) == tokenIn_
                && uint256(bytes32(callData_[68:100])) == tokenInAmount_,
            "MetaSwapDesignValidationBase:invalid-swap"
        );
    }
}

/// @notice ERC-20-only copy of PR 201 with the native branch removed.
contract MetaSwapERC20OnlyEnforcer is MetaSwapDesignValidationBase {
    using ExecutionLib for bytes;

    uint256 private constant TERMS_LENGTH = 73;

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
        require(terms_.length == TERMS_LENGTH, "MetaSwapERC20OnlyEnforcer:invalid-terms");
        address metaSwap_ = address(bytes20(terms_[0:20]));
        address tokenIn_ = address(bytes20(terms_[20:40]));
        uint256 tokenInAmount_ = uint256(bytes32(terms_[40:72]));
        uint8 resetApproval_ = uint8(terms_[72]);
        require(
            metaSwap_ != address(0) && tokenIn_ != address(0) && tokenInAmount_ != 0 && resetApproval_ <= 1,
            "MetaSwapERC20OnlyEnforcer:invalid-terms"
        );

        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        if (resetApproval_ == 1) {
            require(executions_.length == 3, "MetaSwapERC20OnlyEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], tokenIn_, metaSwap_, 0);
            _validateApproval(executions_[1], tokenIn_, metaSwap_, tokenInAmount_);
            _validateSwap(
                executions_[2].target, executions_[2].value, executions_[2].callData, metaSwap_, tokenIn_, tokenInAmount_, 0
            );
        } else {
            require(executions_.length == 2, "MetaSwapERC20OnlyEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], tokenIn_, metaSwap_, tokenInAmount_);
            _validateSwap(
                executions_[1].target, executions_[1].value, executions_[1].callData, metaSwap_, tokenIn_, tokenInAmount_, 0
            );
        }
    }
}

/// @notice Native-only copy retaining PR 201's one-element batch mode.
contract MetaSwapNativeBatchOnlyEnforcer is MetaSwapDesignValidationBase {
    using ExecutionLib for bytes;

    uint256 private constant TERMS_LENGTH = 52;

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
        require(terms_.length == TERMS_LENGTH, "MetaSwapNativeBatchOnlyEnforcer:invalid-terms");
        address metaSwap_ = address(bytes20(terms_[0:20]));
        uint256 tokenInAmount_ = uint256(bytes32(terms_[20:52]));
        require(metaSwap_ != address(0) && tokenInAmount_ != 0, "MetaSwapNativeBatchOnlyEnforcer:invalid-terms");

        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        require(executions_.length == 1, "MetaSwapNativeBatchOnlyEnforcer:invalid-batch-length");
        _validateSwap(
            executions_[0].target,
            executions_[0].value,
            executions_[0].callData,
            metaSwap_,
            address(0),
            tokenInAmount_,
            tokenInAmount_
        );
    }
}

/// @notice Native-only copy using DelegationManager single mode.
contract MetaSwapNativeSingleOnlyEnforcer is MetaSwapDesignValidationBase {
    using ExecutionLib for bytes;

    uint256 private constant TERMS_LENGTH = 52;

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
        onlySingleCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        require(terms_.length == TERMS_LENGTH, "MetaSwapNativeSingleOnlyEnforcer:invalid-terms");
        address metaSwap_ = address(bytes20(terms_[0:20]));
        uint256 tokenInAmount_ = uint256(bytes32(terms_[20:52]));
        require(metaSwap_ != address(0) && tokenInAmount_ != 0, "MetaSwapNativeSingleOnlyEnforcer:invalid-terms");

        (address target_, uint256 value_, bytes calldata callData_) = executionCallData_.decodeSingle();
        _validateSwap(target_, value_, callData_, metaSwap_, address(0), tokenInAmount_, tokenInAmount_);
    }
}

/**
 * @notice PR 201 copy where the final signed byte is an approval policy.
 * @dev Batch length selects the mode, avoiding unsigned caveat args:
 *      bit 0 = swap only, bit 1 = approve(amount) + swap, bit 2 = approve(0) + approve(amount) + swap.
 */
contract MetaSwapApprovalPolicyEnforcer is MetaSwapDesignValidationBase {
    using ExecutionLib for bytes;

    uint8 public constant ALLOW_SKIP_APPROVAL = 1;
    uint8 public constant ALLOW_APPROVAL = 2;
    uint8 public constant ALLOW_RESET_APPROVAL = 4;
    uint256 private constant TERMS_LENGTH = 73;

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
        require(terms_.length == TERMS_LENGTH, "MetaSwapApprovalPolicyEnforcer:invalid-terms");
        address metaSwap_ = address(bytes20(terms_[0:20]));
        address tokenIn_ = address(bytes20(terms_[20:40]));
        uint256 tokenInAmount_ = uint256(bytes32(terms_[40:72]));
        uint8 policy_ = uint8(terms_[72]);
        require(
            metaSwap_ != address(0) && tokenInAmount_ != 0 && policy_ <= 7,
            "MetaSwapApprovalPolicyEnforcer:invalid-terms"
        );

        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        if (tokenIn_ == address(0)) {
            require(policy_ == 0 && executions_.length == 1, "MetaSwapApprovalPolicyEnforcer:shape-not-allowed");
            _validateSwap(
                executions_[0].target,
                executions_[0].value,
                executions_[0].callData,
                metaSwap_,
                address(0),
                tokenInAmount_,
                tokenInAmount_
            );
            return;
        }

        require(policy_ != 0, "MetaSwapApprovalPolicyEnforcer:invalid-terms");
        uint256 swapIndex_;
        if (executions_.length == 1) {
            require(policy_ & ALLOW_SKIP_APPROVAL != 0, "MetaSwapApprovalPolicyEnforcer:shape-not-allowed");
        } else if (executions_.length == 2) {
            require(policy_ & ALLOW_APPROVAL != 0, "MetaSwapApprovalPolicyEnforcer:shape-not-allowed");
            _validateApproval(executions_[0], tokenIn_, metaSwap_, tokenInAmount_);
            swapIndex_ = 1;
        } else {
            require(
                executions_.length == 3 && policy_ & ALLOW_RESET_APPROVAL != 0, "MetaSwapApprovalPolicyEnforcer:shape-not-allowed"
            );
            _validateApproval(executions_[0], tokenIn_, metaSwap_, 0);
            _validateApproval(executions_[1], tokenIn_, metaSwap_, tokenInAmount_);
            swapIndex_ = 2;
        }

        _validateSwap(
            executions_[swapIndex_].target,
            executions_[swapIndex_].value,
            executions_[swapIndex_].callData,
            metaSwap_,
            tokenIn_,
            tokenInAmount_,
            0
        );
    }
}

/**
 * @notice Experimental complete one-shot limit-order enforcer.
 * @dev It combines PR 201 validation, minimum output, and one-shot consumption in one storage slot per delegation.
 *      State is `0` before use, `balanceBefore + 1` during execution, and `type(uint256).max` after success.
 */
contract MetaSwapIntegratedOneShotEnforcer is MetaSwapDesignValidationBase {
    using ExecutionLib for bytes;

    struct Terms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        bool resetApproval;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
    }

    uint256 private constant TERMS_LENGTH = 145;
    mapping(bytes32 key => uint256 state) public delegationState;

    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32 delegationHash_,
        address,
        address
    )
        public
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        Terms memory info_ = _getTerms(terms_);
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        _validateExecutions(executions_, info_);

        bytes32 key_ = _key(msg.sender, delegationHash_);
        require(delegationState[key_] == 0, "MetaSwapIntegratedOneShotEnforcer:already-used");
        uint256 balanceBefore_ = _balanceOf(info_.tokenOut, info_.recipient);
        require(balanceBefore_ != type(uint256).max, "MetaSwapIntegratedOneShotEnforcer:balance-overflow");
        delegationState[key_] = balanceBefore_ + 1;
    }

    function afterHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 delegationHash_,
        address,
        address
    )
        public
        override
    {
        require(terms_.length == TERMS_LENGTH, "MetaSwapIntegratedOneShotEnforcer:invalid-terms");
        address tokenOut_ = address(bytes20(terms_[73:93]));
        address recipient_ = address(bytes20(terms_[93:113]));
        uint256 tokenOutMin_ = uint256(bytes32(terms_[113:145]));
        bytes32 key_ = _key(msg.sender, delegationHash_);
        uint256 cachedState_ = delegationState[key_];
        require(cachedState_ != 0 && cachedState_ != type(uint256).max, "MetaSwapIntegratedOneShotEnforcer:invalid-state");

        uint256 balanceBefore_ = cachedState_ - 1;
        uint256 balanceAfter_ = _balanceOf(tokenOut_, recipient_);
        require(
            balanceAfter_ >= balanceBefore_ && balanceAfter_ - balanceBefore_ >= tokenOutMin_,
            "MetaSwapIntegratedOneShotEnforcer:insufficient-output"
        );
        delegationState[key_] = type(uint256).max;
    }

    function _getTerms(bytes calldata terms_) private pure returns (Terms memory info_) {
        require(terms_.length == TERMS_LENGTH, "MetaSwapIntegratedOneShotEnforcer:invalid-terms");
        info_.metaSwap = address(bytes20(terms_[0:20]));
        info_.tokenIn = address(bytes20(terms_[20:40]));
        info_.tokenInAmount = uint256(bytes32(terms_[40:72]));
        uint8 resetApproval_ = uint8(terms_[72]);
        info_.resetApproval = resetApproval_ == 1;
        info_.tokenOut = address(bytes20(terms_[73:93]));
        info_.recipient = address(bytes20(terms_[93:113]));
        info_.tokenOutMin = uint256(bytes32(terms_[113:145]));
        require(
            info_.metaSwap != address(0) && info_.tokenInAmount != 0 && resetApproval_ <= 1 && info_.recipient != address(0)
                && info_.tokenOutMin != 0,
            "MetaSwapIntegratedOneShotEnforcer:invalid-terms"
        );
    }

    function _validateExecutions(Execution[] calldata executions_, Terms memory info_) private pure {
        if (info_.tokenIn == address(0)) {
            require(!info_.resetApproval && executions_.length == 1, "MetaSwapIntegratedOneShotEnforcer:invalid-batch-length");
            _validateSwap(
                executions_[0].target,
                executions_[0].value,
                executions_[0].callData,
                info_.metaSwap,
                address(0),
                info_.tokenInAmount,
                info_.tokenInAmount
            );
        } else if (info_.resetApproval) {
            require(executions_.length == 3, "MetaSwapIntegratedOneShotEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], info_.tokenIn, info_.metaSwap, 0);
            _validateApproval(executions_[1], info_.tokenIn, info_.metaSwap, info_.tokenInAmount);
            _validateSwap(
                executions_[2].target,
                executions_[2].value,
                executions_[2].callData,
                info_.metaSwap,
                info_.tokenIn,
                info_.tokenInAmount,
                0
            );
        } else {
            require(executions_.length == 2, "MetaSwapIntegratedOneShotEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], info_.tokenIn, info_.metaSwap, info_.tokenInAmount);
            _validateSwap(
                executions_[1].target,
                executions_[1].value,
                executions_[1].callData,
                info_.metaSwap,
                info_.tokenIn,
                info_.tokenInAmount,
                0
            );
        }
    }

    function _balanceOf(address token_, address recipient_) private view returns (uint256) {
        return token_ == address(0) ? recipient_.balance : IERC20(token_).balanceOf(recipient_);
    }

    function _key(address caller_, bytes32 delegationHash_) private pure returns (bytes32) {
        return keccak256(abi.encode(caller_, delegationHash_));
    }
}

contract MetaSwapBatchDesignGasComparisonTest is BaseTest {
    uint256 private constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 private constant TOKEN_OUT_MIN = 190 ether;
    uint256 private constant TOKEN_OUT_AMOUNT = 200 ether;
    uint256 private constant INITIAL_TOKEN_OUT_BALANCE = 1 ether;
    uint256 private constant INTRINSIC_GAS = 21_000;
    uint8 private constant ALL_APPROVAL_MODES = 7;

    struct GasMeasurement {
        uint256 executionGas;
        uint256 calldataBytes;
        uint256 calldataGas;
        uint256 estimatedTransactionGas;
    }

    MetaSwapBatchCalldataEnforcer private baseline;
    MetaSwapERC20OnlyEnforcer private erc20Only;
    MetaSwapNativeBatchOnlyEnforcer private nativeBatchOnly;
    MetaSwapNativeSingleOnlyEnforcer private nativeSingleOnly;
    MetaSwapApprovalPolicyEnforcer private approvalPolicy;
    MetaSwapIntegratedOneShotEnforcer private integratedOneShot;
    LimitedCallsEnforcer private limitedCalls;
    ERC20BalanceChangeEnforcer private balanceChange;
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

        baseline = new MetaSwapBatchCalldataEnforcer();
        erc20Only = new MetaSwapERC20OnlyEnforcer();
        nativeBatchOnly = new MetaSwapNativeBatchOnlyEnforcer();
        nativeSingleOnly = new MetaSwapNativeSingleOnlyEnforcer();
        approvalPolicy = new MetaSwapApprovalPolicyEnforcer();
        integratedOneShot = new MetaSwapIntegratedOneShotEnforcer();
        limitedCalls = new LimitedCallsEnforcer();
        balanceChange = new ERC20BalanceChangeEnforcer();
        router = new MockLimitOrderRouter();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        relayer = makeAddr("Relayer");

        tokenIn.mint(address(users.alice.deleGator), 1_000 ether);
        tokenOut.mint(address(router), 10_000 ether);
        tokenOut.mint(address(users.alice.deleGator), INITIAL_TOKEN_OUT_BALANCE);
        vm.deal(address(users.alice.deleGator), 1_000 ether);
    }

    function test_gas_split_baselineNativeBatch() public {
        _report(
            "split / baseline combined native batch",
            _measure(_oneCaveat(address(baseline), _baselineTerms(address(0), false)), _nativeBatch(), true)
        );
    }

    function test_gas_split_nativeOnlyBatch() public {
        _report("split / native-only batch", _measure(_oneCaveat(address(nativeBatchOnly), _nativeTerms()), _nativeBatch(), true));
    }

    function test_gas_split_nativeOnlySingle() public {
        Execution memory execution_ = _swap(address(0), TOKEN_IN_AMOUNT);
        _report(
            "split / native-only single",
            _measureRaw(
                _oneCaveat(address(nativeSingleOnly), _nativeTerms()),
                ModeLib.encodeSimpleSingle(),
                ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData)
            )
        );
    }

    function test_gas_split_baselineERC20Approval() public {
        _report(
            "split / baseline combined approve(amount)",
            _measure(_oneCaveat(address(baseline), _baselineTerms(address(tokenIn), false)), _erc20Batch(false, false), true)
        );
    }

    function test_gas_split_erc20OnlyApproval() public {
        _report(
            "split / ERC20-only approve(amount)",
            _measure(_oneCaveat(address(erc20Only), _baselineTerms(address(tokenIn), false)), _erc20Batch(false, false), true)
        );
    }

    function test_gas_split_baselineResetApproval() public {
        _setAllowance(1);
        _report(
            "split / baseline combined reset approval",
            _measure(_oneCaveat(address(baseline), _baselineTerms(address(tokenIn), true)), _erc20Batch(true, false), true)
        );
    }

    function test_gas_split_erc20OnlyResetApproval() public {
        _setAllowance(1);
        _report(
            "split / ERC20-only reset approval",
            _measure(_oneCaveat(address(erc20Only), _baselineTerms(address(tokenIn), true)), _erc20Batch(true, false), true)
        );
    }

    function test_gas_policy_baselineApproval() public {
        _report(
            "policy / baseline approve(amount)",
            _measure(_oneCaveat(address(baseline), _baselineTerms(address(tokenIn), false)), _erc20Batch(false, false), true)
        );
    }

    function test_gas_policy_native() public {
        _report(
            "policy / mask native",
            _measure(_oneCaveat(address(approvalPolicy), _baselineTerms(address(0), false)), _nativeBatch(), true)
        );
    }

    function test_gas_policy_allowsApproval() public {
        _report(
            "policy / mask approve(amount)",
            _measure(_oneCaveat(address(approvalPolicy), _policyTerms()), _erc20Batch(false, false), true)
        );
    }

    function test_gas_policy_baselineResetApproval() public {
        _setAllowance(1);
        _report(
            "policy / baseline reset approval",
            _measure(_oneCaveat(address(baseline), _baselineTerms(address(tokenIn), true)), _erc20Batch(true, false), true)
        );
    }

    function test_gas_policy_allowsResetApproval() public {
        _setAllowance(1);
        _report(
            "policy / mask reset approval",
            _measure(_oneCaveat(address(approvalPolicy), _policyTerms()), _erc20Batch(true, false), true)
        );
    }

    function test_gas_policy_skipsApprovalWhenAllowanceExists() public {
        _setAllowance(TOKEN_IN_AMOUNT);
        _report(
            "policy / mask swap-only with existing allowance",
            _measure(_oneCaveat(address(approvalPolicy), _policyTerms()), _erc20Batch(false, true), true)
        );
    }

    function test_gas_integrated_baselineBundleNative() public {
        _report(
            "integrated / baseline + limited + balance native", _measure(_baselineBundle(address(0), false), _nativeBatch(), true)
        );
    }

    function test_gas_integrated_oneShotNative() public {
        _report(
            "integrated / one caveat native",
            _measure(_oneCaveat(address(integratedOneShot), _integratedTerms(address(0), false)), _nativeBatch(), true)
        );
    }

    function test_gas_integrated_baselineBundleERC20Approval() public {
        _report(
            "integrated / baseline + limited + balance approve(amount)",
            _measure(_baselineBundle(address(tokenIn), false), _erc20Batch(false, false), true)
        );
    }

    function test_gas_integrated_oneShotERC20Approval() public {
        _report(
            "integrated / one caveat approve(amount)",
            _measure(
                _oneCaveat(address(integratedOneShot), _integratedTerms(address(tokenIn), false)), _erc20Batch(false, false), true
            )
        );
    }

    function test_gas_integrated_baselineBundleResetApproval() public {
        _setAllowance(1);
        _report(
            "integrated / baseline + limited + balance reset approval",
            _measure(_baselineBundle(address(tokenIn), true), _erc20Batch(true, false), true)
        );
    }

    function test_gas_integrated_oneShotResetApproval() public {
        _setAllowance(1);
        _report(
            "integrated / one caveat reset approval",
            _measure(
                _oneCaveat(address(integratedOneShot), _integratedTerms(address(tokenIn), true)), _erc20Batch(true, false), true
            )
        );
    }

    function test_integratedOneShotRejectsSecondRedemption() public {
        Caveat[] memory caveats_ = _oneCaveat(address(integratedOneShot), _integratedTerms(address(tokenIn), false));
        Delegation memory delegation_ = _sign(caveats_);
        _redeem(delegation_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(_erc20Batch(false, false)));

        vm.expectRevert("MetaSwapIntegratedOneShotEnforcer:already-used");
        _redeem(delegation_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(_erc20Batch(false, false)));
    }

    function test_integratedOneShotRevertsAtomicallyForInsufficientOutputAndAllowsRetry() public {
        Caveat[] memory caveats_ = _oneCaveat(address(integratedOneShot), _integratedTerms(address(tokenIn), false));
        Delegation memory delegation_ = _sign(caveats_);

        vm.expectRevert("MetaSwapIntegratedOneShotEnforcer:insufficient-output");
        _redeem(delegation_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(_erc20Batch(false, false, TOKEN_OUT_MIN - 1)));

        _redeem(delegation_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(_erc20Batch(false, false)));
    }

    function test_policyRejectsUnsignedShape() public {
        uint8 onlyApproval_ = approvalPolicy.ALLOW_APPROVAL();
        Caveat[] memory caveats_ = _oneCaveat(
            address(approvalPolicy), abi.encodePacked(address(router), address(tokenIn), TOKEN_IN_AMOUNT, onlyApproval_)
        );
        Delegation memory delegation_ = _sign(caveats_);

        vm.expectRevert("MetaSwapApprovalPolicyEnforcer:shape-not-allowed");
        _redeem(delegation_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(_erc20Batch(false, true)));
    }

    function test_reportRuntimeSizes() public view {
        console2.log("baseline combined runtime bytes", address(baseline).code.length);
        console2.log("ERC20-only runtime bytes", address(erc20Only).code.length);
        console2.log("native batch-only runtime bytes", address(nativeBatchOnly).code.length);
        console2.log("native single-only runtime bytes", address(nativeSingleOnly).code.length);
        console2.log("approval-policy runtime bytes", address(approvalPolicy).code.length);
        console2.log("integrated one-shot runtime bytes", address(integratedOneShot).code.length);
    }

    function _measure(
        Caveat[] memory caveats_,
        Execution[] memory executions_,
        bool batch_
    )
        private
        returns (GasMeasurement memory)
    {
        require(batch_, "MetaSwapBatchDesignGasComparisonTest:batch-required");
        return _measureRaw(caveats_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions_));
    }

    function _measureRaw(
        Caveat[] memory caveats_,
        ModeCode mode_,
        bytes memory executionCallData_
    )
        private
        returns (GasMeasurement memory measurement_)
    {
        Delegation memory delegation_ = _sign(caveats_);
        bytes memory redeemCallData_ = _encodeRedeem(delegation_, mode_, executionCallData_);
        measurement_.calldataBytes = redeemCallData_.length;
        measurement_.calldataGas = _calldataGas(redeemCallData_);

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory returnData_) = address(delegationManager).call(redeemCallData_);
        measurement_.executionGas = gasBefore_ - gasleft();
        assertTrue(success_, string(returnData_));

        measurement_.estimatedTransactionGas = INTRINSIC_GAS + measurement_.calldataGas + measurement_.executionGas;
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), INITIAL_TOKEN_OUT_BALANCE + TOKEN_OUT_AMOUNT);
    }

    function _baselineBundle(address tokenIn_, bool resetApproval_) private view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](3);
        caveats_[0] = Caveat({ enforcer: address(baseline), terms: _baselineTerms(tokenIn_, resetApproval_), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCalls), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[2] = Caveat({
            enforcer: address(balanceChange),
            terms: abi.encodePacked(false, address(tokenOut), address(users.alice.deleGator), TOKEN_OUT_MIN),
            args: hex""
        });
    }

    function _oneCaveat(address enforcer_, bytes memory terms_) private pure returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: enforcer_, terms: terms_, args: hex"" });
    }

    function _sign(Caveat[] memory caveats_) private view returns (Delegation memory delegation_) {
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

    function _redeem(Delegation memory delegation_, ModeCode mode_, bytes memory executionCallData_) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = mode_;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = executionCallData_;

        vm.prank(relayer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _encodeRedeem(
        Delegation memory delegation_,
        ModeCode mode_,
        bytes memory executionCallData_
    )
        private
        pure
        returns (bytes memory)
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = mode_;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = executionCallData_;
        return
            abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
    }

    function _nativeBatch() private view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = _swap(address(0), TOKEN_IN_AMOUNT);
    }

    function _erc20Batch(bool resetApproval_, bool skipApproval_) private view returns (Execution[] memory) {
        return _erc20Batch(resetApproval_, skipApproval_, TOKEN_OUT_AMOUNT);
    }

    function _erc20Batch(
        bool resetApproval_,
        bool skipApproval_,
        uint256 tokenOutAmount_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        if (skipApproval_) {
            executions_ = new Execution[](1);
            executions_[0] = _swap(address(tokenIn), 0, tokenOutAmount_);
            return executions_;
        }

        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);
        if (resetApproval_) executions_[0] = _approval(0);
        executions_[swapIndex_ - 1] = _approval(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = _swap(address(tokenIn), 0, tokenOutAmount_);
    }

    function _approval(uint256 amount_) private view returns (Execution memory) {
        return
            Execution({ target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), amount_)) });
    }

    function _swap(address tokenIn_, uint256 value_) private view returns (Execution memory) {
        return _swap(tokenIn_, value_, TOKEN_OUT_AMOUNT);
    }

    function _swap(address tokenIn_, uint256 value_, uint256 tokenOutAmount_) private view returns (Execution memory) {
        return Execution({
            target: address(router),
            value: value_,
            callData: abi.encodeCall(
                IMetaSwap.swap,
                (
                    "route-selected-by-redeemer",
                    IERC20(tokenIn_),
                    TOKEN_IN_AMOUNT,
                    abi.encode(IERC20(address(tokenOut)), tokenOutAmount_)
                )
            )
        });
    }

    function _baselineTerms(address tokenIn_, bool resetApproval_) private view returns (bytes memory) {
        return abi.encodePacked(address(router), tokenIn_, TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00));
    }

    function _nativeTerms() private view returns (bytes memory) {
        return abi.encodePacked(address(router), TOKEN_IN_AMOUNT);
    }

    function _policyTerms() private view returns (bytes memory) {
        return abi.encodePacked(address(router), address(tokenIn), TOKEN_IN_AMOUNT, bytes1(ALL_APPROVAL_MODES));
    }

    function _integratedTerms(address tokenIn_, bool resetApproval_) private view returns (bytes memory) {
        return abi.encodePacked(
            address(router),
            tokenIn_,
            TOKEN_IN_AMOUNT,
            bytes1(resetApproval_ ? 0x01 : 0x00),
            address(tokenOut),
            address(users.alice.deleGator),
            TOKEN_OUT_MIN
        );
    }

    function _setAllowance(uint256 amount_) private {
        vm.prank(address(users.alice.deleGator));
        tokenIn.approve(address(router), amount_);
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
