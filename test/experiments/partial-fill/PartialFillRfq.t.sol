// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console } from "forge-std/console.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { FeeOnTransferERC20 } from "../../mocks/FeeOnTransferERC20.sol";
import { Implementation, SignatureType, TestUser } from "../../utils/Types.t.sol";
import { Caveat, Delegation, ModeCode } from "../../../src/utils/Types.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { HybridDeleGator } from "../../../src/HybridDeleGator.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OrderTermsLib } from "../../../src/experiments/partial-fill/OrderTermsLib.sol";
import { PartialFillRfqEnforcer } from "../../../src/experiments/partial-fill/PartialFillRfqEnforcer.sol";
import { PartialFillSettlementAdapter } from "../../../src/experiments/partial-fill/PartialFillSettlementAdapter.sol";
import { LimitOrderDelegationManager } from "../../../src/experiments/manager/LimitOrderDelegationManager.sol";
import { GasExperimentHarness } from "../gas/GasExperimentHarness.sol";

abstract contract PartialFillRfqBase is BaseTest {
    uint256 internal constant TOTAL_SELL = 1_000 ether;
    uint256 internal constant MIN_TOTAL_BUY = 2_000 ether;
    uint256 internal constant MIN_FILL_SELL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 10_000 ether;

    PartialFillRfqEnforcer internal enforcer;
    PartialFillSettlementAdapter internal adapter;
    LimitOrderDelegationManager internal limitOrderManager;

    BasicERC20 internal sellToken;
    BasicERC20 internal buyToken;

    OrderTermsLib.OrderTerms internal baseTerms;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public virtual override {
        super.setUp();

        enforcer = new PartialFillRfqEnforcer();
        adapter = new PartialFillSettlementAdapter(delegationManager, enforcer);
        limitOrderManager = new LimitOrderDelegationManager(makeAddr("LimitOrderManager Owner"));

        sellToken = new BasicERC20(address(users.alice.deleGator), "Sell", "SELL", INITIAL_BALANCE);
        buyToken = new BasicERC20(address(users.bob.addr), "Buy", "BUY", INITIAL_BALANCE);

        baseTerms = OrderTermsLib.OrderTerms({
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            receiver: users.carol.addr,
            totalSell: TOTAL_SELL,
            minTotalBuy: MIN_TOTAL_BUY,
            minFillSell: MIN_FILL_SELL,
            validAfter: 0,
            validUntil: uint64(block.timestamp + 7 days),
            epoch: 0,
            allowPartial: true
        });
    }

    function _requiredBuy(uint256 _fillSell) internal view returns (uint256) {
        return OrderTermsLib.minBuyAmount(baseTerms, _fillSell);
    }

    function _p1Terms() internal view returns (bytes memory) {
        return OrderTermsLib.encodeTerms(baseTerms, address(adapter));
    }

    function _p2Terms() internal view returns (bytes memory) {
        return OrderTermsLib.encodeTermsOnly(baseTerms);
    }

    function _buildP1Delegation(address _delegate) internal returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: _p1Terms(), args: hex"" });
        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: _delegate,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 0,
                signature: hex""
            })
        );
    }

    function _prepareSolver(address _solver, uint256 _buyAmount) internal {
        vm.startPrank(_solver);
        buyToken.approve(address(enforcer), type(uint256).max);
        vm.stopPrank();
        if (_buyAmount > buyToken.balanceOf(_solver)) {
            vm.prank(buyToken.owner());
            buyToken.mint(_solver, _buyAmount);
        }
    }

    function _buildP1Redemption(
        Delegation memory _delegation,
        uint256 _fillSell,
        address _solver
    )
        internal
        view
        returns (bytes[] memory contexts_, ModeCode[] memory modes_, bytes[] memory execs_)
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
        (contexts_, modes_, execs_) = adapter.buildFillRedemption(delegations_, _fillSell, _solver);
    }

    function _redeemP1(bytes[] memory _contexts, ModeCode[] memory _modes, bytes[] memory _execs, address _solver) internal {
        vm.prank(_solver);
        delegationManager.redeemDelegations(_contexts, _modes, _execs);
    }

    function _fillP1(Delegation memory _delegation, uint256 _fillSell, address _solver) internal {
        (bytes[] memory contexts_, ModeCode[] memory modes_, bytes[] memory execs_) =
            _buildP1Redemption(_delegation, _fillSell, _solver);
        _redeemP1(contexts_, modes_, execs_, _solver);
    }

    function _prepareSolver(uint256 _buyAmount) internal {
        _prepareSolver(users.bob.addr, _buyAmount);
    }

    function _fillP1ExpectRevert(
        Delegation memory _delegation,
        uint256 _fillSell,
        address _solver,
        bytes memory _expectedRevert
    )
        internal
    {
        (bytes[] memory contexts_, ModeCode[] memory modes_, bytes[] memory execs_) =
            _buildP1Redemption(_delegation, _fillSell, _solver);
        if (_expectedRevert.length == 0) {
            vm.expectRevert();
        } else {
            vm.expectRevert(_expectedRevert);
        }
        _redeemP1(contexts_, modes_, execs_, _solver);
    }

    function _fillP1(Delegation memory _delegation, uint256 _fillSell) internal {
        address solver_ = _delegation.delegate == ANY_DELEGATE ? users.bob.addr : _delegation.delegate;
        _fillP1(_delegation, _fillSell, solver_);
    }
}

contract PartialFillRfqTest is PartialFillRfqBase {
    function test_fullFill_privateSolver() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(_requiredBuy(TOTAL_SELL));
        _fillP1(delegation_, TOTAL_SELL);

        assertEq(enforcer.filledSell(EncoderLib._getDelegationHash(delegation_)), TOTAL_SELL);
        assertEq(sellToken.balanceOf(users.bob.addr), TOTAL_SELL);
        assertEq(buyToken.balanceOf(users.carol.addr), MIN_TOTAL_BUY);
    }

    function test_partialFills_thenComplete() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(MIN_TOTAL_BUY);

        _fillP1(delegation_, 300 ether);
        assertEq(enforcer.filledSell(EncoderLib._getDelegationHash(delegation_)), 300 ether);

        _fillP1(delegation_, 400 ether);
        assertEq(enforcer.filledSell(EncoderLib._getDelegationHash(delegation_)), 700 ether);

        _fillP1(delegation_, 300 ether);
        assertEq(enforcer.filledSell(EncoderLib._getDelegationHash(delegation_)), TOTAL_SELL);
        assertEq(sellToken.balanceOf(users.bob.addr), TOTAL_SELL);
        assertEq(buyToken.balanceOf(users.carol.addr), MIN_TOTAL_BUY);
    }

    function test_finalRemainderBelowMinFill() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(MIN_TOTAL_BUY);

        _fillP1(delegation_, 900 ether);

        _fillP1ExpectRevert(
            delegation_,
            40 ether,
            users.bob.addr,
            abi.encodeWithSelector(OrderTermsLib.FillBelowMinimum.selector, 40 ether, MIN_FILL_SELL)
        );

        _fillP1(delegation_, 100 ether);
        assertEq(enforcer.filledSell(EncoderLib._getDelegationHash(delegation_)), TOTAL_SELL);
    }

    function test_cancelViaDisableDelegation() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(_requiredBuy(100 ether));

        vm.prank(address(users.alice.deleGator));
        delegationManager.disableDelegation(delegation_);

        (bytes[] memory contexts_, ModeCode[] memory modes_, bytes[] memory execs_) =
            _buildP1Redemption(delegation_, 100 ether, users.bob.addr);
        vm.expectRevert();
        _redeemP1(contexts_, modes_, execs_, users.bob.addr);
    }

    function test_epochBumpInvalidatesOrder() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(_requiredBuy(100 ether));

        vm.prank(address(users.alice.deleGator));
        enforcer.bumpEpoch();

        _fillP1ExpectRevert(
            delegation_,
            100 ether,
            users.bob.addr,
            abi.encodeWithSelector(PartialFillRfqEnforcer.StaleEpoch.selector, uint64(0), uint64(1))
        );
    }

    function test_expiryRejectsFill() public {
        baseTerms.validUntil = uint64(block.timestamp + 100);
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(_requiredBuy(100 ether));

        vm.warp(block.timestamp + 101);
        _fillP1ExpectRevert(
            delegation_, 100 ether, users.bob.addr, abi.encodeWithSelector(PartialFillRfqEnforcer.OrderExpired.selector)
        );
    }

    function test_permissionlessSolver() public {
        Delegation memory delegation_ = _buildP1Delegation(ANY_DELEGATE);
        _prepareSolver(users.dave.addr, _requiredBuy(200 ether));
        _fillP1(delegation_, 200 ether, users.dave.addr);

        assertEq(enforcer.filledSell(EncoderLib._getDelegationHash(delegation_)), 200 ether);
        assertEq(sellToken.balanceOf(users.dave.addr), 200 ether);
    }

    function test_privateSolverRejectsWrongCaller() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(users.bob.addr, _requiredBuy(100 ether));

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        vm.expectRevert(PartialFillSettlementAdapter.NotLeafDelegate.selector);
        adapter.buildFillRedemption(delegations_, 100 ether, users.dave.addr);
    }

    function test_feeOnTransferSellTokenReverts() public {
        FeeOnTransferERC20 feeSell_ = new FeeOnTransferERC20("FeeSell", "FSELL", 100);
        feeSell_.mint(address(users.alice.deleGator), TOTAL_SELL);

        baseTerms.sellToken = address(feeSell_);
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(_requiredBuy(100 ether));

        _fillP1ExpectRevert(delegation_, 100 ether, users.bob.addr, bytes(""));
    }

    function test_leavesDustRemainderReverts() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(MIN_TOTAL_BUY);

        _fillP1ExpectRevert(
            delegation_,
            950 ether,
            users.bob.addr,
            abi.encodeWithSelector(OrderTermsLib.LeavesDustRemainder.selector, 50 ether, MIN_FILL_SELL)
        );
    }
}

contract LimitOrderManagerTest is PartialFillRfqBase {
    HybridDeleGator internal p2Maker;

    function setUp() public override {
        super.setUp();
        HybridDeleGator impl_ = new HybridDeleGator(limitOrderManager, entryPoint);
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.alice.name;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;
        p2Maker = HybridDeleGator(
            payable(address(
                    new ERC1967Proxy(
                        address(impl_),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
                        )
                    )
                ))
        );
        vm.prank(address(users.alice.deleGator));
        sellToken.mint(address(p2Maker), INITIAL_BALANCE);
        baseTerms.sellToken = address(sellToken);
    }

    function _buildP2Delegation(address _delegate) internal returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(limitOrderManager), terms: _p2Terms(), args: hex"" });
        delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(p2Maker),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(limitOrderManager.getDomainHash(), delegationHash_);
        delegation_.signature = signHash(users.alice, typedDataHash_);
    }

    function _prepareSolverP2(address _solver, uint256 _buyAmount) internal {
        vm.startPrank(_solver);
        buyToken.approve(address(limitOrderManager), type(uint256).max);
        vm.stopPrank();
        if (_buyAmount > buyToken.balanceOf(_solver)) {
            vm.prank(buyToken.owner());
            buyToken.mint(_solver, _buyAmount);
        }
    }

    function _fillP2(Delegation memory _delegation, uint256 _fillSell, address _solver) internal {
        vm.prank(_solver);
        limitOrderManager.fillOrder(_delegation, _fillSell);
    }

    function test_p2_fullFill() public {
        Delegation memory delegation_ = _buildP2Delegation(users.bob.addr);
        _prepareSolverP2(users.bob.addr, _requiredBuy(TOTAL_SELL));
        _fillP2(delegation_, TOTAL_SELL, users.bob.addr);

        assertEq(limitOrderManager.filledSell(EncoderLib._getDelegationHash(delegation_)), TOTAL_SELL);
        assertEq(sellToken.balanceOf(users.bob.addr), TOTAL_SELL);
        assertEq(buyToken.balanceOf(users.carol.addr), MIN_TOTAL_BUY);
    }

    function test_p2_partialFill() public {
        Delegation memory delegation_ = _buildP2Delegation(users.bob.addr);
        _prepareSolverP2(users.bob.addr, MIN_TOTAL_BUY);
        _fillP2(delegation_, 250 ether, users.bob.addr);
        assertEq(limitOrderManager.filledSell(EncoderLib._getDelegationHash(delegation_)), 250 ether);
    }

    function test_p2_permissionlessSolver() public {
        Delegation memory delegation_ = _buildP2Delegation(limitOrderManager.ANY_DELEGATE());
        _prepareSolverP2(users.dave.addr, _requiredBuy(150 ether));
        _fillP2(delegation_, 150 ether, users.dave.addr);
        assertEq(sellToken.balanceOf(users.dave.addr), 150 ether);
    }

    function test_p2_rejectsAdditionalUnsupportedCaveat() public {
        Delegation memory delegation_ = _buildP2Delegation(users.bob.addr);
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = delegation_.caveats[0];
        caveats_[1] = Caveat({ enforcer: makeAddr("unsupported-enforcer"), terms: hex"", args: hex"" });
        delegation_.caveats = caveats_;

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(limitOrderManager.getDomainHash(), delegationHash_);
        delegation_.signature = signHash(users.alice, typedDataHash_);

        vm.prank(users.bob.addr);
        vm.expectRevert(LimitOrderDelegationManager.InvalidOrderProfile.selector);
        limitOrderManager.fillOrder(delegation_, 100 ether);
    }
}

contract PartialFillGasBenchmark is PartialFillRfqBase, GasExperimentHarness {
    function test_benchmark_p1_first_partial_subsequent() public {
        Delegation memory delegation_ = _buildP1Delegation(users.bob.addr);
        _prepareSolver(MIN_TOTAL_BUY);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory first_ = measureManagerCall(
            address(delegationManager),
            users.bob.addr,
            encodeRedeemCall(_delegationArray(delegation_, 100 ether, users.bob.addr), singleDefaultMode, _sellExecution(100 ether))
        );
        restoreGasSnapshot(snap_);
        logGasReport("P1 | first partial fill (100 sell)", first_);

        _fillP1(delegation_, 100 ether);
        snap_ = saveGasSnapshot();
        GasMeasurement memory partial_ = measureManagerCall(
            address(delegationManager),
            users.bob.addr,
            encodeRedeemCall(_delegationArray(delegation_, 200 ether, users.bob.addr), singleDefaultMode, _sellExecution(200 ether))
        );
        restoreGasSnapshot(snap_);
        logGasReport("P1 | subsequent partial fill (200 sell)", partial_);

        _fillP1(delegation_, 200 ether);
        uint256 remainder_ = TOTAL_SELL - enforcer.filledSell(EncoderLib._getDelegationHash(delegation_));
        snap_ = saveGasSnapshot();
        GasMeasurement memory final_ = measureManagerCall(
            address(delegationManager),
            users.bob.addr,
            encodeRedeemCall(
                _delegationArray(delegation_, remainder_, users.bob.addr), singleDefaultMode, _sellExecution(remainder_)
            )
        );
        restoreGasSnapshot(snap_);
        logGasReport("P1 | final fill (remainder)", final_);
    }

    function test_benchmark_p2_first_partial_subsequent() public {
        HybridDeleGator impl_ = new HybridDeleGator(limitOrderManager, entryPoint);
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.alice.name;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;
        HybridDeleGator p2Maker_ = HybridDeleGator(
            payable(address(
                    new ERC1967Proxy(
                        address(impl_),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
                        )
                    )
                ))
        );
        vm.prank(address(users.alice.deleGator));
        sellToken.mint(address(p2Maker_), INITIAL_BALANCE);
        baseTerms.sellToken = address(sellToken);

        Delegation memory delegation_ = _buildP2DelegationFor(p2Maker_, users.bob.addr);
        _prepareSolverP2For(MIN_TOTAL_BUY);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory first_ = _measureP2Fill(delegation_, 100 ether);
        restoreGasSnapshot(snap_);
        logGasReport("P2 | first partial fill (100 sell)", first_);

        _fillP2For(delegation_, 100 ether);
        snap_ = saveGasSnapshot();
        GasMeasurement memory partial_ = _measureP2Fill(delegation_, 200 ether);
        restoreGasSnapshot(snap_);
        logGasReport("P2 | subsequent partial fill (200 sell)", partial_);

        _fillP2For(delegation_, 200 ether);
        uint256 remainder_ = TOTAL_SELL - limitOrderManager.filledSell(EncoderLib._getDelegationHash(delegation_));
        snap_ = saveGasSnapshot();
        GasMeasurement memory final_ = _measureP2Fill(delegation_, remainder_);
        restoreGasSnapshot(snap_);
        logGasReport("P2 | final fill (remainder) via fillOrder", final_);
    }

    /// @notice Same ERC-7710 `redeemDelegations(bytes[],ModeCode[],bytes[])` entry as canonical DelegationManager.
    function test_benchmark_p2_redeemDelegations_same_signature() public {
        HybridDeleGator impl_ = new HybridDeleGator(limitOrderManager, entryPoint);
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.alice.name;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;
        HybridDeleGator p2Maker_ = HybridDeleGator(
            payable(address(
                    new ERC1967Proxy(
                        address(impl_),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
                        )
                    )
                ))
        );
        vm.prank(address(users.alice.deleGator));
        sellToken.mint(address(p2Maker_), INITIAL_BALANCE);
        baseTerms.sellToken = address(sellToken);

        Delegation memory delegation_ = _buildP2DelegationFor(p2Maker_, users.bob.addr);
        _prepareSolverP2For(MIN_TOTAL_BUY);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory first_ = _measureP2Redeem(delegation_, 100 ether);
        restoreGasSnapshot(snap_);
        logGasReport("P2 | first partial via redeemDelegations", first_);

        _redeemP2(delegation_, 100 ether);
        snap_ = saveGasSnapshot();
        GasMeasurement memory partial_ = _measureP2Redeem(delegation_, 200 ether);
        restoreGasSnapshot(snap_);
        logGasReport("P2 | subsequent partial via redeemDelegations", partial_);
    }

    function _buildP2DelegationFor(HybridDeleGator _maker, address _delegate) private returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(limitOrderManager), terms: _p2Terms(), args: hex"" });
        delegation_ = Delegation({
            delegate: _delegate, delegator: address(_maker), authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(limitOrderManager.getDomainHash(), delegationHash_);
        delegation_.signature = signHash(users.alice, typedDataHash_);
    }

    function _prepareSolverP2For(uint256 _buyAmount) private {
        vm.startPrank(users.bob.addr);
        buyToken.approve(address(limitOrderManager), type(uint256).max);
        vm.stopPrank();
        if (_buyAmount > buyToken.balanceOf(users.bob.addr)) {
            vm.prank(buyToken.owner());
            buyToken.mint(users.bob.addr, _buyAmount);
        }
    }

    function _fillP2For(Delegation memory _delegation, uint256 _fillSell) private {
        vm.prank(_delegation.delegate);
        limitOrderManager.fillOrder(_delegation, _fillSell);
    }

    function _redeemP2(Delegation memory _delegation, uint256 _fillSell) private {
        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) = _p2RedeemArgs(_delegation, _fillSell);
        vm.prank(_delegation.delegate);
        limitOrderManager.redeemDelegations(pc_, modes_, ecd_);
    }

    function _p2RedeemArgs(
        Delegation memory _delegation,
        uint256 _fillSell
    )
        private
        view
        returns (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_)
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
        pc_ = new bytes[](1);
        pc_[0] = abi.encode(delegations_);
        modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        ecd_ = new bytes[](1);
        ecd_[0] =
            ExecutionLib.encodeSingle(address(sellToken), 0, abi.encodeCall(IERC20.transfer, (_delegation.delegate, _fillSell)));
    }

    function _measureP2Redeem(Delegation memory _delegation, uint256 _fillSell) private returns (GasMeasurement memory m_) {
        (bytes[] memory pc_, ModeCode[] memory modes_, bytes[] memory ecd_) = _p2RedeemArgs(_delegation, _fillSell);
        bytes memory callData_ = abi.encodeWithSelector(limitOrderManager.redeemDelegations.selector, pc_, modes_, ecd_);
        m_.calldataBytes = callData_.length;
        m_.calldataGas = calldataGas(callData_);
        vm.prank(_delegation.delegate);
        uint256 gasBefore_ = gasleft();
        (bool ok_, bytes memory ret_) = address(limitOrderManager).call(callData_);
        m_.executionGas = gasBefore_ - gasleft();
        m_.estimatedTxGas = INTRINSIC_GAS + m_.calldataGas + m_.executionGas;
        if (!ok_) {
            assembly {
                revert(add(ret_, 0x20), mload(ret_))
            }
        }
    }

    function _measureP2Fill(Delegation memory _delegation, uint256 _fillSell) private returns (GasMeasurement memory m_) {
        bytes memory callData_ = abi.encodeWithSelector(limitOrderManager.fillOrder.selector, _delegation, _fillSell);
        m_.calldataBytes = callData_.length;
        m_.calldataGas = calldataGas(callData_);

        vm.prank(_delegation.delegate);
        uint256 gasBefore_ = gasleft();
        (bool ok_, bytes memory ret_) = address(limitOrderManager).call(callData_);
        m_.executionGas = gasBefore_ - gasleft();
        m_.estimatedTxGas = INTRINSIC_GAS + m_.calldataGas + m_.executionGas;

        if (!ok_) {
            assembly {
                revert(add(ret_, 0x20), mload(ret_))
            }
        }
    }

    function _delegationArray(
        Delegation memory _delegation,
        uint256 _fillSell,
        address
    )
        private
        pure
        returns (Delegation[] memory delegations_)
    {
        delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
        delegations_[0].caveats[0].args = abi.encode(_fillSell);
    }

    function _sellExecution(uint256 _amount) private view returns (bytes memory execution_) {
        execution_ = ExecutionLib.encodeSingle(address(sellToken), 0, abi.encodeCall(IERC20.transfer, (users.bob.addr, _amount)));
    }
}
