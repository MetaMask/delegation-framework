// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IERC7821 } from "../../src/interfaces/IERC7821.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";

contract ExistingEnforcersMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_,) = abi.decode(data_, (IERC20, uint256, bytes));

        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "invalid-native-input");
        } else {
            require(msg.value == 0, "unexpected-value");
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        tokenOut_.safeTransfer(msg.sender, amountOut_);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }

    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory adapter_) {
        adapter_ = Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

/**
 * @notice Measures a route-flexible MetaSwap delegation composed exclusively from existing enforcers.
 * @dev The delegation signs a placeholder route, but redemption uses different dynamic aggregator and route data.
 */
contract MetaSwapExistingEnforcersGasTest is BaseTest {
    uint256 private constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 private constant TOKEN_OUT_MIN = 190 ether;
    uint256 private constant TOKEN_OUT_AMOUNT = 200 ether;
    uint256 private constant INTRINSIC_GAS = 21_000;

    // IERC7821.execute selector + mode + dynamic bytes offset.
    uint256 private constant OUTER_HEADER_LENGTH = 68;
    // Nested batch start: selector + ABI head + executionData length.
    uint256 private constant INNER_BATCH_START = 100;

    struct GasMeasurement {
        uint256 executionGas;
        uint256 calldataBytes;
        uint256 calldataGas;
        uint256 estimatedTransactionGas;
    }

    AllowedCalldataEnforcer private allowedCalldataEnforcer;
    AllowedMethodsEnforcer private allowedMethodsEnforcer;
    AllowedTargetsEnforcer private allowedTargetsEnforcer;
    ValueLteEnforcer private valueLteEnforcer;
    LimitedCallsEnforcer private limitedCallsEnforcer;
    ERC20BalanceChangeEnforcer private balanceChangeEnforcer;

    BasicERC20 private tokenIn;
    BasicERC20 private tokenOut;
    ExistingEnforcersMetaSwapMock private metaSwap;
    address private alice;
    address private relayer;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        balanceChangeEnforcer = new ERC20BalanceChangeEnforcer();

        alice = address(users.alice.deleGator);
        relayer = makeAddr("Relayer");
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new ExistingEnforcersMetaSwapMock();

        tokenIn.mint(alice, 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(alice, 1_000 ether);
    }

    function test_gas_nativeInputWithUnknownRoute() public {
        Execution memory template_ = _wrap(_nativeInner("placeholder", _route(hex"01")));
        Execution memory fill_ = _wrap(_nativeInner("actual-aggregator-with-different-length", _route(new bytes(160))));

        GasMeasurement memory measurement_ = _measure(_sign(_caveats(template_)), fill_);

        _report("existing enforcers / native", measurement_);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_gas_erc20InputWithUnknownRoute() public {
        Execution memory template_ = _wrap(_erc20Inner(false, "placeholder", _route(hex"01")));
        Execution memory fill_ = _wrap(_erc20Inner(false, "actual-aggregator-with-different-length", _route(new bytes(160))));

        GasMeasurement memory measurement_ = _measure(_sign(_caveats(template_)), fill_);

        _report("existing enforcers / approve(amount)", measurement_);
        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_gas_erc20ResetApprovalWithUnknownRoute() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), 1);

        Execution memory template_ = _wrap(_erc20Inner(true, "placeholder", _route(hex"01")));
        Execution memory fill_ = _wrap(_erc20Inner(true, "actual-aggregator-with-different-length", _route(new bytes(160))));

        GasMeasurement memory measurement_ = _measure(_sign(_caveats(template_)), fill_);

        _report("existing enforcers / approve(0) + approve(amount)", measurement_);
        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenIn.allowance(alice, address(metaSwap)), 0);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function _caveats(Execution memory template_) private view returns (Caveat[] memory caveats_) {
        Caveat[] memory calldataCaveats_ = _calldataCaveats(template_);
        caveats_ = new Caveat[](calldataCaveats_.length + 5);

        caveats_[0] = Caveat({ enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(alice), args: hex"" });
        caveats_[1] =
            Caveat({ enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC7821.execute.selector), args: hex"" });
        caveats_[2] = Caveat({ enforcer: address(valueLteEnforcer), terms: abi.encode(uint256(0)), args: hex"" });

        for (uint256 i_; i_ < calldataCaveats_.length; ++i_) {
            caveats_[i_ + 3] = calldataCaveats_[i_];
        }

        caveats_[caveats_.length - 2] =
            Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[caveats_.length - 1] = Caveat({
            enforcer: address(balanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
    }

    function _calldataCaveats(Execution memory template_) private view returns (Caveat[] memory caveats_) {
        uint256 swapSelectorOffset_ = _indexOf(template_.callData, IMetaSwap.swap.selector);
        uint256 swapCallDataLengthOffset_ = swapSelectorOffset_ - 32;
        caveats_ = new Caveat[](4);

        // AllowedMethods binds [0:4]. This binds BATCH_DEFAULT and the nested bytes offset.
        caveats_[0] = _allowedCalldataCaveat(4, _slice(template_.callData, 4, OUTER_HEADER_LENGTH - 4));
        // Skip route-dependent outer bytes length [68:100]. Bind count, order, approvals, and swap target/value.
        caveats_[1] = _allowedCalldataCaveat(
            INNER_BATCH_START, _slice(template_.callData, INNER_BATCH_START, swapCallDataLengthOffset_ - INNER_BATCH_START)
        );
        caveats_[2] = _allowedCalldataCaveat(swapSelectorOffset_, abi.encodePacked(IMetaSwap.swap.selector));
        // Skip the dynamic aggregator offset and bind tokenFrom + amount.
        caveats_[3] = _allowedCalldataCaveat(swapSelectorOffset_ + 36, _slice(template_.callData, swapSelectorOffset_ + 36, 64));
    }

    function _allowedCalldataCaveat(uint256 offset_, bytes memory expected_) private view returns (Caveat memory) {
        return Caveat({ enforcer: address(allowedCalldataEnforcer), terms: abi.encodePacked(offset_, expected_), args: hex"" });
    }

    function _nativeInner(string memory aggregatorId_, bytes memory route_) private view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(metaSwap),
            value: TOKEN_IN_AMOUNT,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(address(0)), TOKEN_IN_AMOUNT, route_))
        });
    }

    function _erc20Inner(
        bool resetApproval_,
        string memory aggregatorId_,
        bytes memory route_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);

        if (resetApproval_) executions_[0] = _approval(0);
        executions_[swapIndex_ - 1] = _approval(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = Execution({
            target: address(metaSwap),
            value: 0,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(address(tokenIn)), TOKEN_IN_AMOUNT, route_))
        });
    }

    function _approval(uint256 amount_) private view returns (Execution memory) {
        return
            Execution({
                target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), amount_))
            });
    }

    function _route(bytes memory routeData_) private view returns (bytes memory) {
        return abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT, routeData_);
    }

    function _wrap(Execution[] memory inner_) private view returns (Execution memory) {
        return Execution({
            target: alice,
            value: 0,
            callData: abi.encodeCall(IERC7821.execute, (ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(inner_)))
        });
    }

    function _sign(Caveat[] memory caveats_) private view returns (Delegation memory delegation_) {
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
    }

    function _measure(
        Delegation memory delegation_,
        Execution memory execution_
    )
        private
        returns (GasMeasurement memory measurement_)
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory redeemCallData_ = abi.encodeWithSelector(
            IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_
        );

        measurement_.calldataBytes = redeemCallData_.length;
        measurement_.calldataGas = _calldataGas(redeemCallData_);

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory result_) = address(delegationManager).call(redeemCallData_);
        measurement_.executionGas = gasBefore_ - gasleft();
        if (!success_) _revertWith(result_);

        measurement_.estimatedTransactionGas = INTRINSIC_GAS + measurement_.calldataGas + measurement_.executionGas;
    }

    function _indexOf(bytes memory data_, bytes4 needle_) private pure returns (uint256 index_) {
        for (uint256 i_; i_ + 4 <= data_.length; ++i_) {
            bytes4 candidate_;
            assembly {
                candidate_ := mload(add(add(data_, 0x20), i_))
            }
            if (candidate_ == needle_) return i_;
        }
        revert("selector-not-found");
    }

    function _slice(bytes memory data_, uint256 start_, uint256 length_) private pure returns (bytes memory result_) {
        result_ = new bytes(length_);
        for (uint256 i_; i_ < length_; ++i_) {
            result_[i_] = data_[start_ + i_];
        }
    }

    function _calldataGas(bytes memory data_) private pure returns (uint256 gas_) {
        for (uint256 i_; i_ < data_.length; ++i_) {
            gas_ += data_[i_] == 0 ? 4 : 16;
        }
    }

    function _revertWith(bytes memory result_) private pure {
        assembly {
            revert(add(result_, 0x20), mload(result_))
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
