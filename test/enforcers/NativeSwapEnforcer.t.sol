// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { NativeSwapEnforcer } from "../../src/enforcers/NativeSwapEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract NativeSwapEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// Constants //////////////////////////////

    uint256 internal constant AMOUNT_IN = 1 ether;
    uint256 internal constant MAX_AMOUNT_IN = 3 ether;
    uint256 internal constant MIN_AMOUNT_OUT = 5 ether;
    uint256 internal constant ROUTER_LIQUIDITY = 100 ether;
    bytes4 internal constant EXECUTE_SELECTOR = 0x24856bc3;
    bytes4 internal constant EXECUTE_WITH_DEADLINE_SELECTOR = 0x3593564c;

    ////////////////////////////// State //////////////////////////////

    NativeSwapEnforcer public enforcer;
    NativeSwapRouterMock public router;
    BasicERC20 public destinationToken;

    address public delegator;
    address public redeemer;
    address public delegationManagerAddress;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();

        delegator = address(users.alice.deleGator);
        redeemer = address(users.bob.deleGator);
        delegationManagerAddress = address(delegationManager);

        enforcer = new NativeSwapEnforcer();
        router = new NativeSwapRouterMock();
        destinationToken = new BasicERC20(address(this), "Destination Token", "DST", 0);

        destinationToken.mint(address(router), ROUTER_LIQUIDITY);

        vm.label(address(enforcer), "Native Swap Enforcer");
        vm.label(address(router), "Native Swap Router Mock");
        vm.label(address(destinationToken), "Destination Token");
    }

    ////////////////////////////// Terms //////////////////////////////

    function test_decodesTerms() public {
        NativeSwapEnforcer.TermsData memory terms_ = enforcer.getTermsInfo(_terms());

        assertEq(terms_.destinationToken, address(destinationToken));
        assertEq(terms_.swapTarget, address(router));
        assertEq(terms_.recipient, delegator);
        assertEq(terms_.maxAmountIn, MAX_AMOUNT_IN);
        assertEq(terms_.minAmountOut, MIN_AMOUNT_OUT);
    }

    function test_getHashKey() public {
        bytes32 delegationHash_ = keccak256("native-swap");
        assertEq(
            enforcer.getHashKey(delegationManagerAddress, delegationHash_),
            keccak256(abi.encode(delegationManagerAddress, delegationHash_))
        );
    }

    function test_revertWithInvalidTerms() public {
        vm.expectRevert("NativeSwapEnforcer:invalid-terms-length");
        enforcer.getTermsInfo(hex"");

        vm.expectRevert("NativeSwapEnforcer:invalid-destination-token");
        enforcer.getTermsInfo(_rawTerms(address(0), address(router), delegator, MAX_AMOUNT_IN, MIN_AMOUNT_OUT));

        vm.expectRevert("NativeSwapEnforcer:invalid-swap-target");
        enforcer.getTermsInfo(_rawTerms(address(destinationToken), address(0), delegator, MAX_AMOUNT_IN, MIN_AMOUNT_OUT));

        vm.expectRevert("NativeSwapEnforcer:invalid-recipient");
        enforcer.getTermsInfo(_rawTerms(address(destinationToken), address(router), address(0), MAX_AMOUNT_IN, MIN_AMOUNT_OUT));

        vm.expectRevert("NativeSwapEnforcer:zero-max-amount-in");
        enforcer.getTermsInfo(_rawTerms(address(destinationToken), address(router), delegator, 0, MIN_AMOUNT_OUT));

        vm.expectRevert("NativeSwapEnforcer:zero-min-amount-out");
        enforcer.getTermsInfo(_rawTerms(address(destinationToken), address(router), delegator, MAX_AMOUNT_IN, 0));
    }

    ////////////////////////////// Valid executions //////////////////////////////

    function test_allowsNativeSwapWithDeadline() public {
        bytes32 delegationHash_ = keccak256("with-deadline");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT);

        _before(execution_, delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT);
        _after(delegationHash_);

        bytes32 hashKey_ = enforcer.getHashKey(delegationManagerAddress, delegationHash_);
        assertFalse(enforcer.isLocked(hashKey_));
        assertEq(enforcer.balanceCache(hashKey_), 0);
        assertEq(enforcer.spentMap(delegationManagerAddress, delegationHash_), AMOUNT_IN);
    }

    function test_allowsNativeSwapWithoutDeadline() public {
        bytes32 delegationHash_ = keccak256("without-deadline");
        Execution memory execution_ = _execution(EXECUTE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT);

        _before(execution_, delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT);
        _after(delegationHash_);
    }

    function test_allowsOutputAboveMinimum() public {
        bytes32 delegationHash_ = keccak256("extra-output");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT + 1);

        _before(execution_, delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT + 1);
        _after(delegationHash_);
    }

    function test_tracksCumulativeNativeSpent() public {
        bytes32 delegationHash_ = keccak256("cumulative-spend");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT);

        for (uint256 i = 1; i <= 3; ++i) {
            vm.expectEmit(true, true, true, true, address(enforcer));
            emit NativeSwapEnforcer.IncreasedSpentMap(
                delegationManagerAddress, redeemer, delegationHash_, MAX_AMOUNT_IN, AMOUNT_IN * i
            );
            _before(execution_, delegationHash_);
            destinationToken.mint(delegator, MIN_AMOUNT_OUT);
            _after(delegationHash_);

            assertEq(enforcer.spentMap(delegationManagerAddress, delegationHash_), AMOUNT_IN * i);
        }
    }

    ////////////////////////////// Invalid executions //////////////////////////////

    function test_revertWithInvalidSwapTarget() public {
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT);
        execution_.target = redeemer;

        vm.expectRevert("NativeSwapEnforcer:invalid-swap-target");
        _before(execution_, keccak256("swap-target"));
    }

    function test_revertWithZeroSwapValue() public {
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, 0, MIN_AMOUNT_OUT);

        vm.expectRevert("NativeSwapEnforcer:zero-swap-value");
        _before(execution_, keccak256("swap-value"));
    }

    function test_revertWhenSingleSwapExceedsAllowance() public {
        bytes32 delegationHash_ = keccak256("single-allowance-exceeded");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, MAX_AMOUNT_IN + 1, MIN_AMOUNT_OUT);

        vm.expectRevert("NativeSwapEnforcer:allowance-exceeded");
        _before(execution_, delegationHash_);

        assertEq(enforcer.spentMap(delegationManagerAddress, delegationHash_), 0);
    }

    function test_revertWhenCumulativeSwapAllowanceIsExceeded() public {
        bytes32 delegationHash_ = keccak256("cumulative-allowance-exceeded");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, 2 ether, MIN_AMOUNT_OUT);

        _before(execution_, delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT);
        _after(delegationHash_);

        vm.expectRevert("NativeSwapEnforcer:allowance-exceeded");
        _before(execution_, delegationHash_);

        assertEq(enforcer.spentMap(delegationManagerAddress, delegationHash_), 2 ether);
    }

    function test_revertWithInvalidSwapCalldata() public {
        Execution memory execution_ = Execution({ target: address(router), value: AMOUNT_IN, callData: hex"1234" });

        vm.expectRevert("NativeSwapEnforcer:invalid-swap-calldata");
        _before(execution_, keccak256("swap-calldata"));
    }

    function test_revertWithInvalidSwapMethod() public {
        Execution memory execution_ = Execution({
            target: address(router), value: AMOUNT_IN, callData: abi.encodeWithSelector(bytes4(keccak256("notExecute()")))
        });

        vm.expectRevert("NativeSwapEnforcer:invalid-swap-method");
        _before(execution_, keccak256("swap-method"));
    }

    function test_revertWhenEnforcerIsAlreadyLocked() public {
        bytes32 delegationHash_ = keccak256("locked");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT);

        _before(execution_, delegationHash_);

        vm.expectRevert("NativeSwapEnforcer:enforcer-is-locked");
        _before(execution_, delegationHash_);
    }

    function test_revertWhenAfterHookIsNotLocked() public {
        vm.expectRevert("NativeSwapEnforcer:enforcer-not-locked");
        _after(keccak256("not-locked"));
    }

    function test_revertWithInvalidModes() public {
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT);
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(delegationManagerAddress);
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(_terms(), hex"", batchDefaultMode, executionCallData_, keccak256("batch"), delegator, redeemer);

        vm.prank(delegationManagerAddress);
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(_terms(), hex"", singleTryMode, executionCallData_, keccak256("try"), delegator, redeemer);
    }

    ////////////////////////////// Balance validation //////////////////////////////

    function test_revertWithInsufficientOutput() public {
        bytes32 delegationHash_ = keccak256("insufficient-output");
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT - 1);

        _before(execution_, delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT - 1);

        vm.expectRevert("NativeSwapEnforcer:insufficient-output");
        _after(delegationHash_);
    }

    ////////////////////////////// Integration tests //////////////////////////////

    function test_integrationSwapsNativeTokenForERC20() public {
        uint256 nativeBefore_ = delegator.balance;
        uint256 destinationBefore_ = destinationToken.balanceOf(delegator);
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT + 1);

        _redeem(execution_);

        assertEq(delegator.balance, nativeBefore_ - AMOUNT_IN);
        assertEq(destinationToken.balanceOf(delegator), destinationBefore_ + MIN_AMOUNT_OUT + 1);
        assertEq(address(router).balance, AMOUNT_IN);
        assertEq(enforcer.spentMap(delegationManagerAddress, _nativeSwapDelegationHash()), AMOUNT_IN);
    }

    function test_integrationRevertsAtomicallyWhenOutputIsInsufficient() public {
        uint256 nativeBefore_ = delegator.balance;
        uint256 destinationBefore_ = destinationToken.balanceOf(delegator);
        Execution memory execution_ = _execution(EXECUTE_WITH_DEADLINE_SELECTOR, AMOUNT_IN, MIN_AMOUNT_OUT - 1);
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_) =
            _redemptionData(execution_);

        vm.expectRevert("NativeSwapEnforcer:insufficient-output");
        vm.prank(redeemer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        assertEq(delegator.balance, nativeBefore_);
        assertEq(destinationToken.balanceOf(delegator), destinationBefore_);
        assertEq(address(router).balance, 0);
        assertEq(enforcer.spentMap(delegationManagerAddress, _nativeSwapDelegationHash()), 0);
    }

    ////////////////////////////// Helpers //////////////////////////////

    function _terms() internal view returns (bytes memory) {
        return _rawTerms(address(destinationToken), address(router), delegator, MAX_AMOUNT_IN, MIN_AMOUNT_OUT);
    }

    function _rawTerms(
        address _destinationToken,
        address _router,
        address _recipient,
        uint256 _maxAmountIn,
        uint256 _minAmountOut
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(_destinationToken, _router, _recipient, _maxAmountIn, _minAmountOut);
    }

    function _execution(bytes4 _selector, uint256 _value, uint256 _amountOut) internal view returns (Execution memory execution_) {
        execution_ =
            Execution({ target: address(router), value: _value, callData: _routerCalldata(_selector, delegator, _amountOut) });
    }

    function _routerCalldata(bytes4 _selector, address _recipient, uint256 _amountOut) internal view returns (bytes memory) {
        bytes memory commands_ = hex"00";
        bytes[] memory inputs_ = new bytes[](1);
        inputs_[0] = abi.encode(address(destinationToken), _recipient, _amountOut);

        if (_selector == EXECUTE_WITH_DEADLINE_SELECTOR) {
            return abi.encodeWithSelector(_selector, commands_, inputs_, block.timestamp + 1 hours);
        }
        return abi.encodeWithSelector(_selector, commands_, inputs_);
    }

    function _before(Execution memory _executionData, bytes32 _delegationHash) internal {
        vm.prank(delegationManagerAddress);
        enforcer.beforeHook(
            _terms(),
            hex"",
            singleDefaultMode,
            ExecutionLib.encodeSingle(_executionData.target, _executionData.value, _executionData.callData),
            _delegationHash,
            delegator,
            redeemer
        );
    }

    function _after(bytes32 _delegationHash) internal {
        vm.prank(delegationManagerAddress);
        enforcer.afterHook(_terms(), hex"", singleDefaultMode, hex"", _delegationHash, delegator, redeemer);
    }

    function _redeem(Execution memory _executionData) internal {
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_) =
            _redemptionData(_executionData);

        vm.prank(redeemer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _redemptionData(Execution memory _executionData)
        internal
        view
        returns (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: _terms(), args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: redeemer, delegator: delegator, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;

        executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(_executionData.target, _executionData.value, _executionData.callData);
    }

    function _nativeSwapDelegationHash() internal view returns (bytes32) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: _terms(), args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: redeemer, delegator: delegator, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        return EncoderLib._getDelegationHash(delegation_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}

/**
 * @dev Minimal native-input Uniswap Universal Router-shaped test double. Each command input encodes:
 * `(tokenOut, recipient, amountOut)`.
 */
contract NativeSwapRouterMock {
    receive() external payable { }

    function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable {
        require(block.timestamp <= _deadline, "NativeSwapRouterMock:expired");
        _execute(_commands, _inputs);
    }

    function execute(bytes calldata _commands, bytes[] calldata _inputs) external payable {
        _execute(_commands, _inputs);
    }

    function _execute(bytes calldata _commands, bytes[] calldata _inputs) private {
        require(msg.value != 0, "NativeSwapRouterMock:zero-value");
        require(_commands.length == _inputs.length, "NativeSwapRouterMock:invalid-inputs");

        for (uint256 i = 0; i < _inputs.length; ++i) {
            (address tokenOut_, address recipient_, uint256 amountOut_) = abi.decode(_inputs[i], (address, address, uint256));
            require(IERC20(tokenOut_).transfer(recipient_, amountOut_), "NativeSwapRouterMock:transfer-out-failed");
        }
    }
}
