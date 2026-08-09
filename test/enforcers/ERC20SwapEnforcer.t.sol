// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ERC20SwapEnforcer } from "../../src/enforcers/ERC20SwapEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract ERC20SwapEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// Constants //////////////////////////////

    uint256 internal constant AMOUNT_IN = 10 ether;
    uint256 internal constant MIN_AMOUNT_OUT = 5 ether;
    uint256 internal constant ROUTER_LIQUIDITY = 100 ether;
    bytes4 internal constant EXECUTE_SELECTOR = 0x24856bc3;
    bytes4 internal constant EXECUTE_WITH_DEADLINE_SELECTOR = 0x3593564c;

    ////////////////////////////// State //////////////////////////////

    ERC20SwapEnforcer public enforcer;
    MockUniversalRouter public router;
    BasicERC20 public sourceToken;
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

        enforcer = new ERC20SwapEnforcer();
        router = new MockUniversalRouter();
        sourceToken = new BasicERC20(address(this), "Source Token", "SRC", 0);
        destinationToken = new BasicERC20(address(this), "Destination Token", "DST", 0);

        sourceToken.mint(delegator, ROUTER_LIQUIDITY);
        destinationToken.mint(address(router), ROUTER_LIQUIDITY);
        vm.deal(address(router), ROUTER_LIQUIDITY);

        vm.label(address(enforcer), "ERC20 Swap Enforcer");
        vm.label(address(router), "Mock Universal Router");
        vm.label(address(sourceToken), "Source Token");
        vm.label(address(destinationToken), "Destination Token");
    }

    ////////////////////////////// Terms and args //////////////////////////////

    function test_decodesTerms() public {
        ERC20SwapEnforcer.TermsData memory terms_ = enforcer.getTermsInfo(_terms(address(destinationToken)));

        assertEq(terms_.sourceToken, address(sourceToken));
        assertEq(terms_.destinationToken, address(destinationToken));
        assertEq(terms_.swapTarget, address(router));
        assertEq(terms_.recipient, delegator);
        assertEq(terms_.minAmountOut, MIN_AMOUNT_OUT);
    }

    function test_decodesArgs() public {
        assertFalse(enforcer.getArgsInfo(hex""));
        assertFalse(enforcer.getArgsInfo(hex"00"));
        assertTrue(enforcer.getArgsInfo(hex"01"));
    }

    function test_getHashKey() public {
        bytes32 delegationHash_ = keccak256("swap");
        assertEq(
            enforcer.getHashKey(delegationManagerAddress, delegationHash_),
            keccak256(abi.encode(delegationManagerAddress, delegationHash_))
        );
    }

    function test_revertWithInvalidTerms() public {
        vm.expectRevert("ERC20SwapEnforcer:invalid-terms-length");
        enforcer.getTermsInfo(hex"");

        vm.expectRevert("ERC20SwapEnforcer:invalid-source-token");
        enforcer.getTermsInfo(_rawTerms(address(0), address(destinationToken), address(router), delegator, MIN_AMOUNT_OUT));

        vm.expectRevert("ERC20SwapEnforcer:invalid-swap-target");
        enforcer.getTermsInfo(_rawTerms(address(sourceToken), address(destinationToken), address(0), delegator, MIN_AMOUNT_OUT));

        vm.expectRevert("ERC20SwapEnforcer:invalid-recipient");
        enforcer.getTermsInfo(
            _rawTerms(address(sourceToken), address(destinationToken), address(router), address(0), MIN_AMOUNT_OUT)
        );

        vm.expectRevert("ERC20SwapEnforcer:zero-min-amount-out");
        enforcer.getTermsInfo(_rawTerms(address(sourceToken), address(destinationToken), address(router), delegator, 0));

        vm.expectRevert("ERC20SwapEnforcer:identical-tokens");
        enforcer.getTermsInfo(_rawTerms(address(sourceToken), address(sourceToken), address(router), delegator, MIN_AMOUNT_OUT));
    }

    function test_revertWithInvalidArgs() public {
        vm.expectRevert("ERC20SwapEnforcer:invalid-args-length");
        enforcer.getArgsInfo(hex"0000");

        vm.expectRevert("ERC20SwapEnforcer:invalid-args");
        enforcer.getArgsInfo(hex"02");
    }

    ////////////////////////////// Valid batch shapes //////////////////////////////

    function test_allowsApprovalAndSwapBatch() public {
        bytes32 delegationHash_ = keccak256("approval-and-swap");
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);

        _before(executions_, hex"", _terms(address(destinationToken)), delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT);
        _after(_terms(address(destinationToken)), delegationHash_);

        bytes32 hashKey_ = enforcer.getHashKey(delegationManagerAddress, delegationHash_);
        assertFalse(enforcer.isLocked(hashKey_));
        assertEq(enforcer.balanceCache(hashKey_), 0);
    }

    function test_allowsSwapBatchWithoutApproval() public {
        bytes32 delegationHash_ = keccak256("swap-only");
        Execution[] memory executions_ = _executions(false, address(destinationToken), MIN_AMOUNT_OUT);

        _before(executions_, hex"01", _terms(address(destinationToken)), delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT);
        _after(_terms(address(destinationToken)), delegationHash_);
    }

    function test_allowsExecuteWithoutDeadlineOverload() public {
        bytes32 delegationHash_ = keccak256("without-deadline");
        Execution[] memory executions_ = _executions(false, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].callData = _routerCalldata(EXECUTE_SELECTOR, address(destinationToken), delegator, AMOUNT_IN, MIN_AMOUNT_OUT);

        _before(executions_, hex"01", _terms(address(destinationToken)), delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT);
        _after(_terms(address(destinationToken)), delegationHash_);
    }

    function test_allowsNativeDestination() public {
        bytes32 delegationHash_ = keccak256("native-destination");
        Execution[] memory executions_ = _executions(true, address(0), MIN_AMOUNT_OUT);
        uint256 balanceBefore_ = delegator.balance;

        _before(executions_, hex"", _terms(address(0)), delegationHash_);
        vm.deal(delegator, balanceBefore_ + MIN_AMOUNT_OUT);
        _after(_terms(address(0)), delegationHash_);
    }

    function test_allowsOutputAboveMinimum() public {
        bytes32 delegationHash_ = keccak256("extra-output");
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT + 1);

        _before(executions_, hex"", _terms(address(destinationToken)), delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT + 1);
        _after(_terms(address(destinationToken)), delegationHash_);
    }

    ////////////////////////////// Invalid batch shapes //////////////////////////////

    function test_revertWithWrongBatchSize() public {
        Execution[] memory oneExecution_ = _executions(false, address(destinationToken), MIN_AMOUNT_OUT);
        vm.expectRevert("ERC20SwapEnforcer:invalid-batch-size");
        _before(oneExecution_, hex"", _terms(address(destinationToken)), keccak256("missing-approval"));

        Execution[] memory twoExecutions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        vm.expectRevert("ERC20SwapEnforcer:invalid-batch-size");
        _before(twoExecutions_, hex"01", _terms(address(destinationToken)), keccak256("unexpected-approval"));
    }

    function test_revertWithInvalidApprovalTarget() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].target = address(destinationToken);

        vm.expectRevert("ERC20SwapEnforcer:invalid-approval-target");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("approval-target"));
    }

    function test_revertWithInvalidApprovalValue() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].value = 1;

        vm.expectRevert("ERC20SwapEnforcer:invalid-approval-value");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("approval-value"));
    }

    function test_revertWithInvalidApprovalCalldata() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].callData = abi.encodeWithSelector(IERC20.approve.selector, address(router));

        vm.expectRevert("ERC20SwapEnforcer:invalid-approval-calldata");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("approval-calldata"));
    }

    function test_revertWithInvalidApprovalMethod() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].callData = abi.encodeWithSelector(IERC20.transfer.selector, address(router), AMOUNT_IN);

        vm.expectRevert("ERC20SwapEnforcer:invalid-approval-method");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("approval-method"));
    }

    function test_revertWithInvalidApprovalSpender() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].callData = abi.encodeCall(IERC20.approve, (redeemer, AMOUNT_IN));

        vm.expectRevert("ERC20SwapEnforcer:invalid-approval-spender");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("approval-spender"));
    }

    function test_revertWithZeroApprovalAmount() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(router), 0));

        vm.expectRevert("ERC20SwapEnforcer:zero-approval-amount");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("approval-amount"));
    }

    function test_revertWithInvalidSwapTarget() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[1].target = redeemer;

        vm.expectRevert("ERC20SwapEnforcer:invalid-swap-target");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("swap-target"));
    }

    function test_revertWithNativeSourceValue() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[1].value = 1 ether;

        vm.expectRevert("ERC20SwapEnforcer:invalid-swap-value");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("native-source"));
    }

    function test_revertWithInvalidSwapCalldata() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[1].callData = hex"1234";

        vm.expectRevert("ERC20SwapEnforcer:invalid-swap-calldata");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("swap-calldata"));
    }

    function test_revertWithInvalidSwapMethod() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        executions_[1].callData = abi.encodeWithSelector(bytes4(keccak256("notExecute()")));

        vm.expectRevert("ERC20SwapEnforcer:invalid-swap-method");
        _before(executions_, hex"", _terms(address(destinationToken)), keccak256("swap-method"));
    }

    ////////////////////////////// Balance validation //////////////////////////////

    function test_revertWithInsufficientERC20Output() public {
        bytes32 delegationHash_ = keccak256("insufficient-erc20");
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT - 1);

        _before(executions_, hex"", _terms(address(destinationToken)), delegationHash_);
        destinationToken.mint(delegator, MIN_AMOUNT_OUT - 1);

        vm.expectRevert("ERC20SwapEnforcer:insufficient-output");
        _after(_terms(address(destinationToken)), delegationHash_);
    }

    function test_revertWithInsufficientNativeOutput() public {
        bytes32 delegationHash_ = keccak256("insufficient-native");
        Execution[] memory executions_ = _executions(true, address(0), MIN_AMOUNT_OUT - 1);
        uint256 balanceBefore_ = delegator.balance;

        _before(executions_, hex"", _terms(address(0)), delegationHash_);
        vm.deal(delegator, balanceBefore_ + MIN_AMOUNT_OUT - 1);

        vm.expectRevert("ERC20SwapEnforcer:insufficient-output");
        _after(_terms(address(0)), delegationHash_);
    }

    function test_revertWhenEnforcerIsAlreadyLocked() public {
        bytes32 delegationHash_ = keccak256("locked");
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);

        _before(executions_, hex"", _terms(address(destinationToken)), delegationHash_);

        vm.expectRevert("ERC20SwapEnforcer:enforcer-is-locked");
        _before(executions_, hex"", _terms(address(destinationToken)), delegationHash_);
    }

    function test_revertWhenAfterHookIsNotLocked() public {
        vm.expectRevert("ERC20SwapEnforcer:enforcer-not-locked");
        _after(_terms(address(destinationToken)), keccak256("not-locked"));
    }

    function test_revertWithInvalidModes() public {
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT);
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(delegationManagerAddress);
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(
            _terms(address(destinationToken)),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256("single"),
            delegator,
            redeemer
        );

        vm.prank(delegationManagerAddress);
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(
            _terms(address(destinationToken)), hex"", batchTryMode, executionCallData_, keccak256("try"), delegator, redeemer
        );
    }

    ////////////////////////////// Integration tests //////////////////////////////

    function test_integrationSwapsERC20WithApproval() public {
        uint256 sourceBefore_ = sourceToken.balanceOf(delegator);
        uint256 destinationBefore_ = destinationToken.balanceOf(delegator);
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT + 1);

        _redeem(executions_, _terms(address(destinationToken)), hex"");

        assertEq(sourceToken.balanceOf(delegator), sourceBefore_ - AMOUNT_IN);
        assertEq(destinationToken.balanceOf(delegator), destinationBefore_ + MIN_AMOUNT_OUT + 1);
        assertEq(sourceToken.allowance(delegator, address(router)), 0);
    }

    function test_integrationSwapsERC20WithExistingApproval() public {
        vm.prank(delegator);
        sourceToken.approve(address(router), AMOUNT_IN);

        uint256 sourceBefore_ = sourceToken.balanceOf(delegator);
        uint256 destinationBefore_ = destinationToken.balanceOf(delegator);
        Execution[] memory executions_ = _executions(false, address(destinationToken), MIN_AMOUNT_OUT);

        _redeem(executions_, _terms(address(destinationToken)), hex"01");

        assertEq(sourceToken.balanceOf(delegator), sourceBefore_ - AMOUNT_IN);
        assertEq(destinationToken.balanceOf(delegator), destinationBefore_ + MIN_AMOUNT_OUT);
        assertEq(sourceToken.allowance(delegator, address(router)), 0);
    }

    function test_integrationSwapsERC20ForNativeToken() public {
        uint256 sourceBefore_ = sourceToken.balanceOf(delegator);
        uint256 nativeBefore_ = delegator.balance;
        Execution[] memory executions_ = _executions(true, address(0), MIN_AMOUNT_OUT);

        _redeem(executions_, _terms(address(0)), hex"");

        assertEq(sourceToken.balanceOf(delegator), sourceBefore_ - AMOUNT_IN);
        assertEq(delegator.balance, nativeBefore_ + MIN_AMOUNT_OUT);
    }

    function test_integrationRevertsAtomicallyWhenOutputIsInsufficient() public {
        uint256 sourceBefore_ = sourceToken.balanceOf(delegator);
        uint256 destinationBefore_ = destinationToken.balanceOf(delegator);
        Execution[] memory executions_ = _executions(true, address(destinationToken), MIN_AMOUNT_OUT - 1);
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_) =
            _redemptionData(executions_, _terms(address(destinationToken)), hex"");

        vm.expectRevert("ERC20SwapEnforcer:insufficient-output");
        vm.prank(redeemer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        assertEq(sourceToken.balanceOf(delegator), sourceBefore_);
        assertEq(destinationToken.balanceOf(delegator), destinationBefore_);
        assertEq(sourceToken.allowance(delegator, address(router)), 0);
    }

    ////////////////////////////// Helpers //////////////////////////////

    function _terms(address _destinationToken) internal view returns (bytes memory) {
        return _rawTerms(address(sourceToken), _destinationToken, address(router), delegator, MIN_AMOUNT_OUT);
    }

    function _rawTerms(
        address _sourceToken,
        address _destinationToken,
        address _router,
        address _recipient,
        uint256 _minAmountOut
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(_sourceToken, _destinationToken, _router, _recipient, _minAmountOut);
    }

    function _executions(
        bool _includeApproval,
        address _destinationToken,
        uint256 _amountOut
    )
        internal
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_;
        if (_includeApproval) {
            executions_ = new Execution[](2);
            executions_[0] = Execution({
                target: address(sourceToken), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), AMOUNT_IN))
            });
            swapIndex_ = 1;
        } else {
            executions_ = new Execution[](1);
        }

        executions_[swapIndex_] = Execution({
            target: address(router),
            value: 0,
            callData: _routerCalldata(EXECUTE_WITH_DEADLINE_SELECTOR, _destinationToken, delegator, AMOUNT_IN, _amountOut)
        });
    }

    function _routerCalldata(
        bytes4 _selector,
        address _destinationToken,
        address _recipient,
        uint256 _amountIn,
        uint256 _amountOut
    )
        internal
        view
        returns (bytes memory)
    {
        bytes memory commands_ = hex"00";
        bytes[] memory inputs_ = new bytes[](1);
        inputs_[0] = abi.encode(address(sourceToken), _destinationToken, _recipient, _amountIn, _amountOut);

        if (_selector == EXECUTE_WITH_DEADLINE_SELECTOR) {
            return abi.encodeWithSelector(_selector, commands_, inputs_, block.timestamp + 1 hours);
        }
        return abi.encodeWithSelector(_selector, commands_, inputs_);
    }

    function _before(
        Execution[] memory _batchExecutions,
        bytes memory _args,
        bytes memory _termsData,
        bytes32 _delegationHash
    )
        internal
    {
        vm.prank(delegationManagerAddress);
        enforcer.beforeHook(
            _termsData, _args, batchDefaultMode, ExecutionLib.encodeBatch(_batchExecutions), _delegationHash, delegator, redeemer
        );
    }

    function _after(bytes memory _termsData, bytes32 _delegationHash) internal {
        vm.prank(delegationManagerAddress);
        enforcer.afterHook(_termsData, hex"", batchDefaultMode, hex"", _delegationHash, delegator, redeemer);
    }

    function _redeem(Execution[] memory _batchExecutions, bytes memory _termsData, bytes memory _args) internal {
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_) =
            _redemptionData(_batchExecutions, _termsData, _args);

        vm.prank(redeemer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _redemptionData(
        Execution[] memory _batchExecutions,
        bytes memory _termsData,
        bytes memory _args
    )
        internal
        view
        returns (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: _termsData, args: _args });

        Delegation memory delegation_ = Delegation({
            delegate: redeemer, delegator: delegator, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        modes_ = new ModeCode[](1);
        modes_[0] = batchDefaultMode;

        executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(_batchExecutions);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}

/**
 * @dev Minimal Uniswap Universal Router-shaped test double. Each command input encodes:
 * `(tokenIn, tokenOut, recipient, amountIn, amountOut)`, where `tokenOut == address(0)` means native token.
 */
contract MockUniversalRouter {
    receive() external payable { }

    function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable {
        require(block.timestamp <= _deadline, "MockUniversalRouter:expired");
        _execute(_commands, _inputs);
    }

    function execute(bytes calldata _commands, bytes[] calldata _inputs) external payable {
        _execute(_commands, _inputs);
    }

    function _execute(bytes calldata _commands, bytes[] calldata _inputs) private {
        require(_commands.length == _inputs.length, "MockUniversalRouter:invalid-inputs");

        for (uint256 i = 0; i < _inputs.length; ++i) {
            (address tokenIn_, address tokenOut_, address recipient_, uint256 amountIn_, uint256 amountOut_) =
                abi.decode(_inputs[i], (address, address, address, uint256, uint256));

            require(IERC20(tokenIn_).transferFrom(msg.sender, address(this), amountIn_), "MockUniversalRouter:transfer-in-failed");

            if (tokenOut_ == address(0)) {
                (bool success_,) = payable(recipient_).call{ value: amountOut_ }("");
                require(success_, "MockUniversalRouter:native-transfer-failed");
            } else {
                require(IERC20(tokenOut_).transfer(recipient_, amountOut_), "MockUniversalRouter:transfer-out-failed");
            }
        }
    }
}
