// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { EIP7702StatelessDeleGator } from "../../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";

/// @dev Output is paid to `msg.sender`, the 7702 user.
///      A quote encodes `(tokenOut, amountOut, route)`. A gasless quote appends
///      `(fee, feeWallet, feeFromSource)` and the fee is settled inside this call.
contract GasComparisonMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));
        (uint256 fee_, address feeWallet_, bool feeFromSource_) = _embeddedFee(data_);
        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "invalid-native-value");
            require(!feeFromSource_, "native-source-fee");
        } else {
            require(msg.value == 0, "unexpected-native-value");
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
            if (feeFromSource_) tokenFrom_.safeTransfer(feeWallet_, fee_);
        }
        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "native-transfer-failed");
        } else {
            uint256 toUser_ = amountOut_;
            if (fee_ > 0 && !feeFromSource_) {
                tokenOut_.safeTransfer(feeWallet_, fee_);
                toUser_ = amountOut_ - fee_;
            }
            tokenOut_.safeTransfer(msg.sender, toUser_);
        }
    }

    /// @dev `(address, uint256, bytes)` puts the bytes offset at `0x60`. A gasless payload
    ///      has three more head words, so that offset is `0xc0`.
    function _embeddedFee(bytes calldata data_) private pure returns (uint256 fee_, address feeWallet_, bool feeFromSource_) {
        if (data_.length < 96 || uint256(bytes32(data_[64:96])) == 96) return (0, address(0), false);
        (,,, fee_, feeWallet_, feeFromSource_) = abi.decode(data_, (IERC20, uint256, bytes, uint256, address, bool));
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }

    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory adapter_) {
        adapter_ = Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

/**
 * @notice Shared gas-comparison fixture.
 * @dev One user (`USER_KEY`) is etched with `EIP7702StatelessDeleGator` bound to the manager that file redeems
 *      through. The account has to name that manager. Installation, funding, route, and redeemers are the same.
 *      A later transaction signs a new permission. `vm.store` leaves the id or nonce word and the token slots
 *      that shape writes non-zero, and those slots stay cold.
 */
abstract contract GasComparisonFixture is BaseTest {
    uint256 internal constant USER_KEY = 0x0D1;
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_MIN = 190 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;
    uint256 internal constant GASLESS_FEE_AMOUNT = 10 ether;
    uint256 internal constant INTRINSIC_GAS = 21_000;
    uint256 internal constant MEASURED_NONCE = 1;
    string internal constant AGGREGATOR_ID = "actual-aggregator-with-different-length";

    enum Shape {
        NativeToErc20,
        Erc20ToNative,
        Erc20ToErc20
    }

    address internal user;
    address internal relayer;
    address internal signerA;
    address internal signerB;
    address internal feeRecipient;
    uint128 internal expiresAt;
    bytes internal routeData;
    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    GasComparisonMetaSwapMock internal metaSwap;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public virtual override {
        super.setUp();
        user = vm.addr(USER_KEY);
        relayer = makeAddr("Relayer");
        signerA = makeAddr("SignerA");
        signerB = makeAddr("SignerB");
        feeRecipient = makeAddr("GaslessFeeRecipient");
        expiresAt = uint128(block.timestamp + 1 days);
        routeData = new bytes(160);

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new GasComparisonMetaSwapMock();

        tokenIn.mint(user, 100_000 ether);
        tokenOut.mint(address(metaSwap), 100_000 ether);
        vm.deal(user, 100_000 ether);
        vm.deal(address(metaSwap), 100_000 ether);
        _installComparison();
    }

    /// @dev Deploy the contract under test, then `_installUser` with the manager that contract expects.
    function _installComparison() internal virtual;

    function _installUser(address manager_) internal {
        EIP7702StatelessDeleGator implementation_ = new EIP7702StatelessDeleGator(IDelegationManager(manager_), entryPoint);
        vm.etch(user, bytes.concat(hex"ef0100", abi.encodePacked(implementation_)));
    }

    function _comparisonName() internal pure virtual returns (string memory);

    function _log(string memory label_, uint256 estimatedTransactionGas_) internal pure {
        console2.log(string.concat(_comparisonName(), " / ", label_));
        console2.log("  estimated tx", estimatedTransactionGas_);
    }

    function _redeemers() internal view returns (address[] memory redeemers_) {
        redeemers_ = new address[](4);
        redeemers_[1] = signerA;
        redeemers_[2] = signerB;
        redeemers_[3] = relayer;
    }

    function _redeemerTerms() internal view returns (bytes memory) {
        return abi.encodePacked(address(0), signerA, signerB, relayer);
    }

    function _timestampTerms() internal view returns (bytes memory) {
        return abi.encodePacked(uint128(0), expiresAt);
    }

    function _sign(uint256 key_, bytes32 digest_) internal pure returns (bytes memory) {
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _signRoot(
        address delegate_,
        bytes32 authority_,
        bytes32 domainHash_,
        Caveat[] memory caveats_,
        uint256 salt_
    )
        internal
        view
        returns (Delegation memory delegation_)
    {
        delegation_ = Delegation({
            delegate: delegate_, delegator: user, authority: authority_, caveats: caveats_, salt: salt_, signature: hex""
        });
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, EncoderLib._getDelegationHash(delegation_));
        delegation_.signature = _sign(USER_KEY, typedDataHash_);
    }

    function _executions(Shape shape_) internal view returns (Execution[] memory executions_) {
        if (shape_ == Shape.NativeToErc20) {
            executions_ = new Execution[](1);
            executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, address(tokenOut));
            return executions_;
        }
        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        executions_ = new Execution[](2);
        executions_[0] = _approvalExecution(TOKEN_IN_AMOUNT);
        executions_[1] = _swapExecution(address(tokenIn), TOKEN_IN_AMOUNT, 0, tokenOut_);
    }

    /// @dev Gasless exact batches pay an ERC-20 fee after the swap.
    ///      Native input pays from tokenOut; ERC-20 input pays from tokenIn.
    function _gaslessExecutions(Shape shape_) internal view returns (Execution[] memory executions_) {
        if (shape_ == Shape.NativeToErc20) {
            executions_ = new Execution[](2);
            executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, address(tokenOut));
            executions_[1] = _feeTransferExecution(address(tokenOut));
            return executions_;
        }

        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        address feeToken_ = shape_ == Shape.Erc20ToNative ? address(tokenIn) : address(tokenOut);
        executions_ = new Execution[](3);
        executions_[0] = _approvalExecution(TOKEN_IN_AMOUNT);
        executions_[1] = _swapExecution(address(tokenIn), TOKEN_IN_AMOUNT, 0, tokenOut_);
        executions_[2] = _feeTransferExecution(feeToken_);
    }

    function _approvalExecution(uint256 amount_) internal view returns (Execution memory) {
        return
            Execution({
                target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), amount_))
            });
    }

    function _feeTransferExecution(address feeToken_) internal view returns (Execution memory) {
        return
            Execution({
                target: feeToken_, value: 0, callData: abi.encodeCall(IERC20.transfer, (feeRecipient, GASLESS_FEE_AMOUNT))
            });
    }

    function _swapExecution(
        address tokenFrom_,
        uint256 amount_,
        uint256 value_,
        address tokenOut_
    )
        internal
        view
        returns (Execution memory)
    {
        return Execution({
            target: address(metaSwap),
            value: value_,
            callData: abi.encodeCall(
                IMetaSwap.swap,
                (AGGREGATOR_ID, IERC20(tokenFrom_), amount_, abi.encode(IERC20(tokenOut_), TOKEN_OUT_AMOUNT, routeData))
            )
        });
    }

    /// @dev One MetaSwap call. The gas fee is the tail of the adapter payload, not its own execution.
    ///      A source fee is pulled as part of `amount_`; a destination fee is split from the output.
    function _swapExecutionWithFee(
        address tokenFrom_,
        uint256 amount_,
        uint256 value_,
        address tokenOut_,
        bool feeFromSource_
    )
        internal
        view
        returns (Execution memory)
    {
        bytes memory adapterData_ =
            abi.encode(IERC20(tokenOut_), TOKEN_OUT_AMOUNT, routeData, GASLESS_FEE_AMOUNT, feeRecipient, feeFromSource_);
        return Execution({
            target: address(metaSwap),
            value: value_,
            callData: abi.encodeCall(IMetaSwap.swap, (AGGREGATOR_ID, IERC20(tokenFrom_), amount_, adapterData_))
        });
    }

    /// @dev `aggregatorId` and swap `data` only. Direct-route managers rebuild approve + swap from the signed terms.
    function _routeBytes(Shape shape_) internal view returns (bytes memory) {
        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        bytes memory data_ = abi.encode(IERC20(tokenOut_), TOKEN_OUT_AMOUNT, routeData);
        bytes memory aggregator_ = bytes(AGGREGATOR_ID);
        return bytes.concat(bytes1(uint8(aggregator_.length)), aggregator_, bytes2(uint16(data_.length)), data_);
    }

    function _measure(address target_, bytes memory data_, Shape shape_) internal returns (uint256) {
        uint256 tokenInBefore_ = tokenIn.balanceOf(user);
        uint256 tokenOutBefore_ = tokenOut.balanceOf(user);
        uint256 nativeBefore_ = user.balance;
        uint256 calldataGas_ = _calldataGas(data_);

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory result_) = target_.call(data_);
        uint256 executionGas_ = gasBefore_ - gasleft();
        if (!success_) {
            assembly {
                revert(add(result_, 0x20), mload(result_))
            }
        }
        _assertFilled(shape_, tokenInBefore_, tokenOutBefore_, nativeBefore_);
        return INTRINSIC_GAS + calldataGas_ + executionGas_;
    }

    function _measureGasless(address target_, bytes memory data_, Shape shape_) internal returns (uint256) {
        uint256 tokenInBefore_ = tokenIn.balanceOf(user);
        uint256 tokenOutBefore_ = tokenOut.balanceOf(user);
        uint256 nativeBefore_ = user.balance;
        uint256 feeBefore_ = _gaslessFeeToken(shape_).balanceOf(feeRecipient);
        uint256 calldataGas_ = _calldataGas(data_);

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory result_) = target_.call(data_);
        uint256 executionGas_ = gasBefore_ - gasleft();
        if (!success_) {
            assembly {
                revert(add(result_, 0x20), mload(result_))
            }
        }
        _assertGaslessFilled(shape_, tokenInBefore_, tokenOutBefore_, nativeBefore_, feeBefore_);
        return INTRINSIC_GAS + calldataGas_ + executionGas_;
    }

    function _redeemDelegations(
        address manager_,
        Delegation[] memory chains_,
        ModeCode[] memory modes_,
        bytes[] memory executionCallDatas_,
        Shape shape_
    )
        internal
        returns (uint256)
    {
        bytes[] memory permissionContexts_ = new bytes[](chains_.length);
        for (uint256 i_; i_ < chains_.length; ++i_) {
            Delegation[] memory delegations_ = new Delegation[](1);
            delegations_[0] = chains_[i_];
            permissionContexts_[i_] = abi.encode(delegations_);
        }
        bytes memory data_ =
            abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
        return _measure(manager_, data_, shape_);
    }

    function _redeemDelegationsGasless(
        address manager_,
        Delegation[] memory chains_,
        ModeCode[] memory modes_,
        bytes[] memory executionCallDatas_,
        Shape shape_
    )
        internal
        returns (uint256)
    {
        bytes[] memory permissionContexts_ = new bytes[](chains_.length);
        for (uint256 i_; i_ < chains_.length; ++i_) {
            Delegation[] memory delegations_ = new Delegation[](1);
            delegations_[0] = chains_[i_];
            permissionContexts_[i_] = abi.encode(delegations_);
        }
        bytes memory data_ =
            abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
        return _measureGasless(manager_, data_, shape_);
    }

    /// @dev Token slots a previous fill of this shape leaves behind. Slots stay cold.
    function _prepareLaterBalances(Shape shape_) internal {
        if (shape_ != Shape.NativeToErc20) {
            vm.store(address(tokenIn), keccak256(abi.encode(address(metaSwap), uint256(0))), bytes32(uint256(1)));
        }
        if (shape_ != Shape.Erc20ToNative) {
            vm.store(address(tokenOut), keccak256(abi.encode(user, uint256(0))), bytes32(uint256(1)));
        }
    }

    /// @dev Token slots a previous gasless exact fill leaves behind. Slots stay cold.
    function _prepareLaterGaslessBalances(Shape shape_) internal {
        _prepareLaterBalances(shape_);
        IERC20 feeToken_ = _gaslessFeeToken(shape_);
        vm.store(address(feeToken_), keccak256(abi.encode(feeRecipient, uint256(0))), bytes32(uint256(1)));
    }

    /**
     * @dev Balances plus bit 200 of an id or nonce word. Bit 1 stays free.
     *      `throughDelegationManager_` is the IdEnforcer / FlexibleSettlement bitmap, keyed by manager then user.
     */
    function _prepareLaterFill(Shape shape_, address bitmapContract_, uint256 mapSlot_, bool throughDelegationManager_) internal {
        _prepareLaterBalances(shape_);

        bytes32 innerSlot_;
        if (throughDelegationManager_) {
            bytes32 managerSlot_ = keccak256(abi.encode(address(delegationManager), mapSlot_));
            innerSlot_ = keccak256(abi.encode(user, managerSlot_));
        } else {
            innerSlot_ = keccak256(abi.encode(user, mapSlot_));
        }
        vm.store(bitmapContract_, keccak256(abi.encode(uint256(0), innerSlot_)), bytes32(uint256(1) << 200));
    }

    function _prepareLaterGaslessFill(Shape shape_, address bitmapContract_, uint256 mapSlot_) internal {
        _prepareLaterGaslessBalances(shape_);
        bytes32 innerSlot_ = keccak256(abi.encode(user, mapSlot_));
        vm.store(bitmapContract_, keccak256(abi.encode(uint256(0), innerSlot_)), bytes32(uint256(1) << 200));
    }

    function _assertFilled(Shape shape_, uint256 tokenInBefore_, uint256 tokenOutBefore_, uint256 nativeBefore_) private {
        if (shape_ == Shape.NativeToErc20) {
            assertEq(user.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
            assertEq(tokenOut.balanceOf(user), tokenOutBefore_ + TOKEN_OUT_AMOUNT);
        } else if (shape_ == Shape.Erc20ToNative) {
            assertEq(tokenIn.balanceOf(user), tokenInBefore_ - TOKEN_IN_AMOUNT);
            assertEq(user.balance, nativeBefore_ + TOKEN_OUT_AMOUNT);
        } else {
            assertEq(tokenIn.balanceOf(user), tokenInBefore_ - TOKEN_IN_AMOUNT);
            assertEq(tokenOut.balanceOf(user), tokenOutBefore_ + TOKEN_OUT_AMOUNT);
        }
    }

    function _assertGaslessFilled(
        Shape shape_,
        uint256 tokenInBefore_,
        uint256 tokenOutBefore_,
        uint256 nativeBefore_,
        uint256 feeBefore_
    )
        private
    {
        assertEq(_gaslessFeeToken(shape_).balanceOf(feeRecipient), feeBefore_ + GASLESS_FEE_AMOUNT);
        if (shape_ == Shape.NativeToErc20) {
            assertEq(user.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
            assertEq(tokenOut.balanceOf(user), tokenOutBefore_ + TOKEN_OUT_AMOUNT - GASLESS_FEE_AMOUNT);
        } else if (shape_ == Shape.Erc20ToNative) {
            assertEq(tokenIn.balanceOf(user), tokenInBefore_ - TOKEN_IN_AMOUNT - GASLESS_FEE_AMOUNT);
            assertEq(user.balance, nativeBefore_ + TOKEN_OUT_AMOUNT);
        } else {
            assertEq(tokenIn.balanceOf(user), tokenInBefore_ - TOKEN_IN_AMOUNT);
            assertEq(tokenOut.balanceOf(user), tokenOutBefore_ + TOKEN_OUT_AMOUNT - GASLESS_FEE_AMOUNT);
        }
    }

    function _gaslessFeeToken(Shape shape_) private view returns (IERC20) {
        return shape_ == Shape.Erc20ToNative ? IERC20(address(tokenIn)) : IERC20(address(tokenOut));
    }

    function _calldataGas(bytes memory data_) private pure returns (uint256 gas_) {
        for (uint256 i_; i_ < data_.length; ++i_) {
            gas_ += data_[i_] == 0 ? 4 : 16;
        }
    }

    function _singleMode() internal pure returns (ModeCode) {
        return ModeLib.encodeSimpleSingle();
    }

    function _batchMode() internal pure returns (ModeCode) {
        return ModeLib.encodeSimpleBatch();
    }
}

/// @notice The six limit rows. Every limit baseline and every packed manager's limit flow uses these names.
abstract contract LimitGasComparison is GasComparisonFixture {
    function _run(Shape shape_) internal virtual returns (uint256);
    function _armLater(Shape shape_) internal virtual;

    function test_gas_nativeToErc20() public {
        _log("native to erc20", _run(Shape.NativeToErc20));
    }

    function test_gas_nativeToErc20_laterTransaction() public {
        _armLater(Shape.NativeToErc20);
        _log("native to erc20 / later tx", _run(Shape.NativeToErc20));
    }

    function test_gas_erc20ToNative() public {
        _log("erc20 to native", _run(Shape.Erc20ToNative));
    }

    function test_gas_erc20ToNative_laterTransaction() public {
        _armLater(Shape.Erc20ToNative);
        _log("erc20 to native / later tx", _run(Shape.Erc20ToNative));
    }

    function test_gas_erc20ToErc20() public {
        _log("erc20 to erc20", _run(Shape.Erc20ToErc20));
    }

    function test_gas_erc20ToErc20_laterTransaction() public {
        _armLater(Shape.Erc20ToErc20);
        _log("erc20 to erc20 / later tx", _run(Shape.Erc20ToErc20));
    }
}

/// @notice The six gasless exact rows. The exact-batch baseline, the order manager, and the packed managers use these names.
abstract contract ExactGasComparison is GasComparisonFixture {
    function _runExact(Shape shape_) internal virtual returns (uint256);
    function _armLaterExact(Shape shape_) internal virtual;

    function test_gas_exact_nativeToErc20() public {
        _log("exact / native to erc20", _runExact(Shape.NativeToErc20));
    }

    function test_gas_exact_nativeToErc20_laterTransaction() public {
        _armLaterExact(Shape.NativeToErc20);
        _log("exact / native to erc20 / later tx", _runExact(Shape.NativeToErc20));
    }

    function test_gas_exact_erc20ToNative() public {
        _log("exact / erc20 to native", _runExact(Shape.Erc20ToNative));
    }

    function test_gas_exact_erc20ToNative_laterTransaction() public {
        _armLaterExact(Shape.Erc20ToNative);
        _log("exact / erc20 to native / later tx", _runExact(Shape.Erc20ToNative));
    }

    function test_gas_exact_erc20ToErc20() public {
        _log("exact / erc20 to erc20", _runExact(Shape.Erc20ToErc20));
    }

    function test_gas_exact_erc20ToErc20_laterTransaction() public {
        _armLaterExact(Shape.Erc20ToErc20);
        _log("exact / erc20 to erc20 / later tx", _runExact(Shape.Erc20ToErc20));
    }
}
