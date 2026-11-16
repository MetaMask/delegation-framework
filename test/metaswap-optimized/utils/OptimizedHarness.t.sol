// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { EIP7702StatelessDeleGator } from "../../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../../../src/interfaces/IDelegationManager.sol";
import { ERC1271Lib } from "../../../src/libraries/ERC1271Lib.sol";
import { Execution, ModeCode } from "../../../src/utils/Types.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";

/// @dev Byte-for-byte the baseline harness mock, so every variant pays the same swap cost.
contract OptimizedGasMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));
        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "invalid-native-value");
        } else {
            require(msg.value == 0, "unexpected-native-value");
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }
        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "native-transfer-failed");
        } else {
            tokenOut_.safeTransfer(msg.sender, amountOut_);
        }
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }

    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory adapter_) {
        adapter_ = Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

/// @dev Calls back into a manager once, from inside the swap, the way a malicious route hop could.
contract ReentrantMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    receive() external payable { }

    function setReentry(address target_, bytes calldata data_) external {
        reentryTarget = target_;
        reentryData = data_;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        if (reentryTarget != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));
        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "invalid-native-value");
        } else {
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }
        if (amountOut_ == 0) return;
        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "native-transfer-failed");
        } else {
            tokenOut_.safeTransfer(msg.sender, amountOut_);
        }
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }

    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory adapter_) {
        adapter_ = Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

/// @dev Smart-contract delegator: accepts a 32-byte signature equal to the digest, runs any batch.
contract Optimized1271Account {
    using ExecutionLib for bytes;

    receive() external payable { }

    function isValidSignature(bytes32 hash_, bytes memory signature_) external pure returns (bytes4) {
        if (signature_.length == 32 && bytes32(signature_) == hash_) return ERC1271Lib.EIP1271_MAGIC_VALUE;
        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }

    function executeFromExecutor(ModeCode, bytes calldata executionCallData_)
        external
        payable
        returns (bytes[] memory returnData_)
    {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        returnData_ = new bytes[](executions_.length);
        for (uint256 i_; i_ < executions_.length; ++i_) {
            (bool ok_, bytes memory ret_) = executions_[i_].target.call{ value: executions_[i_].value }(executions_[i_].callData);
            require(ok_, "exec-failed");
            returnData_[i_] = ret_;
        }
    }
}

/**
 * @notice Shared fixtures for the optimized-manager gas and security suites.
 * @dev A variant plugs in through an adapter that implements the virtual hooks below. Gas fixtures match
 *      `test/metaswap-optimized/baseline/`: same mock, route payload, amounts, redeemer list, and nonce/salt 1.
 */
abstract contract OptimizedHarness is BaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_MIN = 190 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;
    uint256 internal constant INTRINSIC_GAS = 21_000;
    uint256 internal constant ORDER_ALICE_KEY = 0x0D1;
    uint256 internal constant WRONG_KEY = 0xBAD;
    uint256 internal constant DEFAULT_NONCE = 1;
    /// @dev Same word as `DEFAULT_NONCE`, burned in `setUp` for warm-word runs.
    uint256 internal constant WARM_SIBLING_NONCE = 200;
    address internal constant ANY = address(0xa11);
    string internal constant AGGREGATOR_ID = "actual-aggregator-with-different-length";

    /// @dev PR table row order.
    enum Shape {
        NativeToErc20,
        Erc20ToNative,
        Erc20ToErc20,
        Erc20Reset
    }

    struct GasMeasurement {
        uint256 executionGas;
        uint256 calldataBytes;
        uint256 calldataGas;
        uint256 estimatedTransactionGas;
    }

    struct ExactOrder {
        uint256 key;
        address delegate;
        address delegator;
        uint256 nonce;
        uint128 validAfter;
        uint128 validUntil;
        address[] redeemers;
        bytes batch;
    }

    struct LimitParams {
        uint256 key;
        address delegate;
        address delegator;
        uint256 nonce;
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        uint8 approvalMode;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
        uint128 validAfter;
        uint128 validUntil;
        address[] redeemers;
        bytes batch;
    }

    address internal manager;
    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    OptimizedGasMetaSwapMock internal metaSwap;
    address internal orderAlice;
    address internal relayer;
    address internal signerA;
    address internal signerB;
    uint128 internal expiresAt;
    bytes internal routeData;
    bool internal warmWord;
    /// @dev Capabilities, set by adapter constructors.
    bool internal hasBitmap;
    bool internal hasLock;
    bool internal supportsExact = true;
    bool internal supportsLimit = true;
    /// @dev False for Optimized / DirectRoute (ECDSA / 7702 EOA only). True for `MetaSwapOrderDelegationManager`.
    bool internal supportsErc1271 = true;
    /// @dev True when ExactBatch accepts any submitter. False when a delegate or redeemer list gates it.
    bool internal openExactSubmission;
    /// @dev True when LimitOrder / ExactBatch still sign a delegate field (Order manager).
    bool internal signsDelegate = true;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public virtual override {
        super.setUp();

        manager = _deployManager();
        orderAlice = vm.addr(ORDER_ALICE_KEY);
        relayer = makeAddr("Relayer");
        signerA = makeAddr("SignerA");
        signerB = makeAddr("SignerB");
        expiresAt = uint128(block.timestamp + 1 days);
        routeData = new bytes(160);

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new OptimizedGasMetaSwapMock();

        tokenIn.mint(orderAlice, 100_000 ether);
        tokenOut.mint(address(metaSwap), 100_000 ether);
        vm.deal(orderAlice, 100_000 ether);
        vm.deal(address(metaSwap), 100_000 ether);

        _installAccount(orderAlice, manager);
        if (warmWord) _burnNonce(orderAlice, WARM_SIBLING_NONCE);
        _setUpSuite();
    }

    ////////////////////////////// Suite and variant hooks //////////////////////////////

    /// @dev Suite-specific fixtures. Unimplemented here so a suite and an adapter can be combined freely.
    function _setUpSuite() internal virtual;

    function _deployManager() internal virtual returns (address);

    function _variantName() internal pure virtual returns (string memory);

    function _exactDigest(address manager_, ExactOrder memory order_) internal view virtual returns (bytes32);

    function _exactCalldata(
        address manager_,
        ExactOrder memory order_,
        bytes memory signature_
    )
        internal
        view
        virtual
        returns (bytes memory);

    function _limitDigest(address manager_, LimitParams memory params_) internal view virtual returns (bytes32);

    function _limitCalldata(
        address manager_,
        LimitParams memory params_,
        bytes memory signature_
    )
        internal
        view
        virtual
        returns (bytes memory);

    /// @dev Cancels as the delegator through the variant's own mechanism.
    function _cancelExact(ExactOrder memory order_) internal virtual;

    function _cancelLimit(LimitParams memory params_) internal virtual;

    /// @dev Bitmap variants burn the nonce; others revert.
    function _burnNonce(address delegator_, uint256 nonce_) internal virtual;

    ////////////////////////////// Builders //////////////////////////////

    function _installAccount(address account_, address manager_) internal {
        EIP7702StatelessDeleGator implementation_ = new EIP7702StatelessDeleGator(IDelegationManager(manager_), entryPoint);
        vm.etch(account_, bytes.concat(hex"ef0100", abi.encodePacked(implementation_)));
    }

    function _defaultExact(Shape shape_) internal view returns (ExactOrder memory order_) {
        order_.key = ORDER_ALICE_KEY;
        order_.delegate = relayer;
        order_.delegator = orderAlice;
        order_.nonce = DEFAULT_NONCE;
        order_.validUntil = expiresAt;
        order_.redeemers = _defaultRedeemers();
        order_.batch = ExecutionLib.encodeBatch(_executions(shape_, address(metaSwap), TOKEN_OUT_AMOUNT));
    }

    function _defaultRedeemers() internal view returns (address[] memory redeemers_) {
        redeemers_ = new address[](4);
        redeemers_[1] = signerA;
        redeemers_[2] = signerB;
        redeemers_[3] = relayer;
    }

    /// @dev Packed exact auth: delegator, nonce, timestamp, redeemer count, redeemers.
    function _exactHead(ExactOrder memory order_) internal pure returns (bytes memory) {
        return abi.encodePacked(
            order_.delegator,
            order_.nonce,
            order_.validAfter,
            order_.validUntil,
            uint8(order_.redeemers.length),
            _packAddresses(order_.redeemers)
        );
    }

    function _defaultLimit(Shape shape_) internal view returns (LimitParams memory params_) {
        params_.key = ORDER_ALICE_KEY;
        params_.delegate = ANY;
        params_.delegator = orderAlice;
        params_.nonce = DEFAULT_NONCE;
        params_.metaSwap = address(metaSwap);
        params_.tokenInAmount = TOKEN_IN_AMOUNT;
        params_.recipient = orderAlice;
        params_.tokenOutMin = TOKEN_OUT_MIN;
        params_.validUntil = expiresAt;
        params_.redeemers = _defaultRedeemers();
        if (shape_ == Shape.NativeToErc20) {
            params_.tokenOut = address(tokenOut);
        } else {
            params_.tokenIn = address(tokenIn);
            params_.tokenOut = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
            params_.approvalMode = shape_ == Shape.Erc20Reset ? 3 : 2;
        }
        params_.batch = ExecutionLib.encodeBatch(_executions(shape_, address(metaSwap), TOKEN_OUT_AMOUNT));
    }

    function _executions(
        Shape shape_,
        address metaSwap_,
        uint256 amountOut_
    )
        internal
        view
        returns (Execution[] memory executions_)
    {
        if (shape_ == Shape.NativeToErc20) {
            executions_ = new Execution[](1);
            executions_[0] = _swap(metaSwap_, address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, address(tokenOut), amountOut_);
            return executions_;
        }
        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        if (shape_ == Shape.Erc20Reset) {
            executions_ = new Execution[](3);
            executions_[0] = _approval(metaSwap_, 0);
            executions_[1] = _approval(metaSwap_, TOKEN_IN_AMOUNT);
            executions_[2] = _swap(metaSwap_, address(tokenIn), TOKEN_IN_AMOUNT, 0, tokenOut_, amountOut_);
            return executions_;
        }
        executions_ = new Execution[](2);
        executions_[0] = _approval(metaSwap_, TOKEN_IN_AMOUNT);
        executions_[1] = _swap(metaSwap_, address(tokenIn), TOKEN_IN_AMOUNT, 0, tokenOut_, amountOut_);
    }

    function _approval(address spender_, uint256 amount_) internal view returns (Execution memory) {
        return Execution({ target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (spender_, amount_)) });
    }

    function _swap(
        address metaSwap_,
        address tokenFrom_,
        uint256 amount_,
        uint256 value_,
        address tokenOut_,
        uint256 amountOut_
    )
        internal
        view
        returns (Execution memory)
    {
        return Execution({
            target: metaSwap_,
            value: value_,
            callData: abi.encodeCall(
                IMetaSwap.swap, (AGGREGATOR_ID, IERC20(tokenFrom_), amount_, abi.encode(IERC20(tokenOut_), amountOut_, routeData))
            )
        });
    }

    function _packAddresses(address[] memory addresses_) internal pure returns (bytes memory packed_) {
        for (uint256 i_; i_ < addresses_.length; ++i_) {
            packed_ = bytes.concat(packed_, bytes20(addresses_[i_]));
        }
    }

    ////////////////////////////// Signing and redemption //////////////////////////////

    function _sign(uint256 key_, bytes32 digest_) internal pure returns (bytes memory) {
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _exactCall(ExactOrder memory order_) internal view returns (bytes memory) {
        return _exactCalldata(manager, order_, _sign(order_.key, _exactDigest(manager, order_)));
    }

    function _limitCall(LimitParams memory params_) internal view returns (bytes memory) {
        return _limitCalldata(manager, params_, _sign(params_.key, _limitDigest(manager, params_)));
    }

    function _callAs(address sender_, bytes memory data_) internal returns (bool success_, bytes memory result_) {
        vm.prank(sender_);
        (success_, result_) = manager.call(data_);
    }

    function _redeemOk(bytes memory data_) internal {
        _redeemOkAs(relayer, data_);
    }

    function _redeemOkAs(address sender_, bytes memory data_) internal {
        (bool success_, bytes memory result_) = _callAs(sender_, data_);
        if (!success_) {
            assembly {
                revert(add(result_, 0x20), mload(result_))
            }
        }
    }

    function _redeemFails(bytes memory data_) internal {
        _redeemFailsAs(relayer, data_);
    }

    function _redeemFailsAs(address sender_, bytes memory data_) internal {
        (bool success_,) = _callAs(sender_, data_);
        assertFalse(success_, "redemption should revert");
    }

    ////////////////////////////// Gas //////////////////////////////

    function _measure(bytes memory data_, address account_, Shape shape_) internal returns (GasMeasurement memory measurement_) {
        uint256 tokenInBefore_ = tokenIn.balanceOf(account_);
        uint256 tokenOutBefore_ = tokenOut.balanceOf(account_);
        uint256 nativeBefore_ = account_.balance;

        measurement_.calldataBytes = data_.length;
        measurement_.calldataGas = _calldataGas(data_);

        address manager_ = manager;
        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory result_) = manager_.call(data_);
        measurement_.executionGas = gasBefore_ - gasleft();
        if (!success_) {
            assembly {
                revert(add(result_, 0x20), mload(result_))
            }
        }
        measurement_.estimatedTransactionGas = INTRINSIC_GAS + measurement_.calldataGas + measurement_.executionGas;
        _assertSwapBalances(shape_, account_, tokenInBefore_, tokenOutBefore_, nativeBefore_);
    }

    function _assertSwapBalances(
        Shape shape_,
        address account_,
        uint256 tokenInBefore_,
        uint256 tokenOutBefore_,
        uint256 nativeBefore_
    )
        internal
    {
        if (shape_ == Shape.NativeToErc20) {
            assertEq(account_.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
            assertEq(tokenOut.balanceOf(account_), tokenOutBefore_ + TOKEN_OUT_AMOUNT);
        } else if (shape_ == Shape.Erc20ToNative) {
            assertEq(tokenIn.balanceOf(account_), tokenInBefore_ - TOKEN_IN_AMOUNT);
            assertEq(account_.balance, nativeBefore_ + TOKEN_OUT_AMOUNT);
        } else {
            assertEq(tokenIn.balanceOf(account_), tokenInBefore_ - TOKEN_IN_AMOUNT);
            assertEq(tokenOut.balanceOf(account_), tokenOutBefore_ + TOKEN_OUT_AMOUNT);
        }
    }

    function _calldataGas(bytes memory data_) internal pure returns (uint256 gas_) {
        for (uint256 i_; i_ < data_.length; ++i_) {
            gas_ += data_[i_] == 0 ? 4 : 16;
        }
    }

    /// @dev One parseable line per measurement: `GAS|variant|flow|row|estimatedTx|calldataBytes|executionGas`.
    function _logGas(string memory flow_, string memory row_, GasMeasurement memory measurement_) internal view {
        console2.log(
            string.concat(
                "GAS|",
                _variantName(),
                warmWord ? "-warm" : "",
                "|",
                flow_,
                "|",
                row_,
                "|",
                vm.toString(measurement_.estimatedTransactionGas),
                "|",
                vm.toString(measurement_.calldataBytes),
                "|",
                vm.toString(measurement_.executionGas)
            )
        );
    }
}
