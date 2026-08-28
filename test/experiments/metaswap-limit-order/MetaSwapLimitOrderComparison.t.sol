// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { GasExperimentHarness } from "../gas/GasExperimentHarness.sol";
import { HybridDeleGator } from "../../../src/HybridDeleGator.sol";
import { IDelegationManager } from "../../../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { MetaSwapLimitOrderAdapter } from "../../../src/experiments/metaswap-limit-order/MetaSwapLimitOrderAdapter.sol";
import { MetaSwapLimitOrderEnforcer } from "../../../src/experiments/metaswap-limit-order/MetaSwapLimitOrderEnforcer.sol";
import { MetaSwapLimitOrderLib } from "../../../src/experiments/metaswap-limit-order/MetaSwapLimitOrderLib.sol";
import { MetaSwapLimitOrderManager } from "../../../src/experiments/metaswap-limit-order/MetaSwapLimitOrderManager.sol";

contract MetaSwapLimitOrderMock is IMetaSwap {
    using SafeERC20 for IERC20;

    IERC20 internal immutable tokenOut;

    constructor(IERC20 _tokenOut) {
        tokenOut = _tokenOut;
    }

    function swap(string calldata, IERC20 _tokenFrom, uint256, bytes calldata _data) external payable {
        (uint256 spendAmount_, uint256 outputAmount_, address outputRecipient_) = abi.decode(_data, (uint256, uint256, address));
        _tokenFrom.safeTransferFrom(msg.sender, address(this), spendAmount_);
        tokenOut.safeTransfer(outputRecipient_ == address(0) ? msg.sender : outputRecipient_, outputAmount_);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract MetaSwapLimitOrderComparisonTest is BaseTest, GasExperimentHarness {
    uint256 internal constant AMOUNT_IN = 100 ether;
    uint256 internal constant MIN_AMOUNT_OUT = 190 ether;
    uint256 internal constant ACTUAL_AMOUNT_OUT = 200 ether;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MetaSwapLimitOrderMock internal metaSwap;
    MetaSwapLimitOrderAdapter internal adapter;
    MetaSwapLimitOrderEnforcer internal enforcer;
    MetaSwapLimitOrderManager internal specializedManager;
    HybridDeleGator internal specializedMaker;

    address internal automation;
    address internal apiSigner;
    uint256 internal apiSignerKey;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MetaSwapLimitOrderMock(tokenOut);
        (apiSigner, apiSignerKey) = makeAddrAndKey("metaswap-api-signer");
        adapter = new MetaSwapLimitOrderAdapter(metaSwap, apiSigner);
        enforcer = new MetaSwapLimitOrderEnforcer();
        specializedManager = new MetaSwapLimitOrderManager(makeAddr("specialized-manager-owner"));
        specializedMaker = _deploySpecializedMaker();
        automation = makeAddr("limit-order-automation");

        tokenIn.mint(address(users.alice.deleGator), AMOUNT_IN);
        tokenIn.mint(address(specializedMaker), AMOUNT_IN);
        tokenOut.mint(address(metaSwap), 10_000 ether);
    }

    function test_canonicalManager_executesBoundedDynamicRoute() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));

        _redeem(delegationManager, delegation_, _execution(quote_), automation);
        _assertSettlement(address(users.alice.deleGator));
    }

    function test_specializedManager_executesSameBoundedDynamicRoute() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));

        _redeem(specializedManager, delegation_, _execution(quote_), automation);
        _assertSettlement(address(specializedMaker));
    }

    function test_revertsWrongInputToken() public {
        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Execution[] memory executions_ = abi.decode(_execution(quote_), (Execution[]));
        executions_[0].target = address(wrongToken_);
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));

        vm.expectRevert(MetaSwapLimitOrderLib.InvalidTransferCall.selector);
        _redeem(delegationManager, delegation_, ExecutionLib.encodeBatch(executions_), automation);
    }

    function test_revertsWrongOutputToken() public {
        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Execution[] memory executions_ = abi.decode(_execution(quote_), (Execution[]));
        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenIn, wrongToken_, AMOUNT_IN, MIN_AMOUNT_OUT, quote_));
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));

        vm.expectRevert(MetaSwapLimitOrderLib.InvalidSwapCall.selector);
        _redeem(delegationManager, delegation_, ExecutionLib.encodeBatch(executions_), automation);
    }

    function test_revertsInputAmountMismatch() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Execution[] memory executions_ = abi.decode(_execution(quote_), (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(adapter), AMOUNT_IN - 1));
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));

        vm.expectRevert(MetaSwapLimitOrderLib.InvalidTransferCall.selector);
        _redeem(specializedManager, delegation_, ExecutionLib.encodeBatch(executions_), automation);
    }

    function test_revertsWhenMetaSwapConsumesLessThanExactInput() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN - 1, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));
        bytes memory execution_ = _execution(quote_);

        vm.expectRevert(abi.encodeWithSelector(MetaSwapLimitOrderAdapter.RemainingAllowance.selector, 1));
        _redeem(delegationManager, delegation_, execution_, automation);
    }

    function test_revertsBelowActualMinimumOutput() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, MIN_AMOUNT_OUT - 1, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));
        bytes memory execution_ = _execution(quote_);

        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapLimitOrderAdapter.InsufficientOutput.selector, MIN_AMOUNT_OUT, MIN_AMOUNT_OUT - 1)
        );
        _redeem(specializedManager, delegation_, execution_, automation);
    }

    function test_revertsWhenRouteRedirectsOutput() public {
        address attacker_ = makeAddr("route-output-attacker");
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, attacker_, uint64(block.timestamp + 5 minutes), apiSignerKey);
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));
        bytes memory execution_ = _execution(quote_);

        vm.expectRevert(abi.encodeWithSelector(MetaSwapLimitOrderAdapter.InsufficientOutput.selector, MIN_AMOUNT_OUT, 0));
        _redeem(delegationManager, delegation_, execution_, automation);
    }

    function test_revertsExpiredApiQuote() public {
        uint64 quoteExpiry_ = uint64(block.timestamp + 10);
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), quoteExpiry_, apiSignerKey);
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));
        bytes memory execution_ = _execution(quote_);
        vm.warp(quoteExpiry_);

        vm.expectRevert(MetaSwapLimitOrderAdapter.ApiQuoteExpired.selector);
        _redeem(delegationManager, delegation_, execution_, automation);
    }

    function test_revertsInvalidApiSignature() public {
        (, uint256 wrongSignerKey_) = makeAddrAndKey("wrong-api-signer");
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), wrongSignerKey_);
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));
        bytes memory execution_ = _execution(quote_);

        vm.expectRevert(MetaSwapLimitOrderAdapter.InvalidApiSignature.selector);
        _redeem(specializedManager, delegation_, execution_, automation);
    }

    function test_revertsWhenApiQuoteIsReusedWithDifferentMinimum() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Execution[] memory executions_ = abi.decode(_execution(quote_), (Execution[]));
        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenIn, tokenOut, AMOUNT_IN, MIN_AMOUNT_OUT + 1, quote_));
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));

        vm.expectRevert(MetaSwapLimitOrderAdapter.InvalidApiSignature.selector);
        _redeem(delegationManager, delegation_, ExecutionLib.encodeBatch(executions_), automation);
    }

    function test_revertsWrongSpecializedManagerExecutor() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));
        bytes memory execution_ = _execution(quote_);

        vm.expectRevert(IDelegationManager.InvalidDelegate.selector);
        _redeem(specializedManager, delegation_, execution_, makeAddr("unauthorized-automation"));
    }

    function test_revertsExpiredMakerOrder() public {
        uint64 orderExpiry_ = uint64(block.timestamp + 10);
        Delegation memory delegation_ = _canonicalDelegation(orderExpiry_);
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        vm.warp(orderExpiry_);

        vm.expectRevert(MetaSwapLimitOrderLib.OrderExpired.selector);
        _redeem(delegationManager, delegation_, _execution(quote_), automation);
    }

    function test_revertsCanonicalReplay() public {
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        bytes memory execution_ = _execution(quote_);
        _redeem(delegationManager, delegation_, execution_, automation);

        tokenIn.mint(address(users.alice.deleGator), AMOUNT_IN);
        vm.expectRevert(MetaSwapLimitOrderEnforcer.DelegationAlreadyUsed.selector);
        _redeem(delegationManager, delegation_, execution_, automation);
    }

    function test_revertsSpecializedReplay() public {
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        bytes memory execution_ = _execution(quote_);
        _redeem(specializedManager, delegation_, execution_, automation);

        tokenIn.mint(address(specializedMaker), AMOUNT_IN);
        vm.expectRevert(MetaSwapLimitOrderManager.DelegationAlreadyUsed.selector);
        _redeem(specializedManager, delegation_, execution_, automation);
    }

    function test_failedFillDoesNotConsumeOrder() public {
        Delegation memory delegation_ = _canonicalDelegation(uint64(block.timestamp + 1 days));
        MetaSwapLimitOrderAdapter.ApiQuote memory badQuote_ =
            _quote(AMOUNT_IN, MIN_AMOUNT_OUT - 1, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);

        vm.expectRevert();
        _redeem(delegationManager, delegation_, _execution(badQuote_), automation);

        MetaSwapLimitOrderAdapter.ApiQuote memory goodQuote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        _redeem(delegationManager, delegation_, _execution(goodQuote_), automation);
        _assertSettlement(address(users.alice.deleGator));
    }

    function test_specializedManagerCancelStopsFill() public {
        Delegation memory delegation_ = _specializedDelegation(uint64(block.timestamp + 1 days));
        vm.prank(address(specializedMaker));
        specializedManager.disableDelegation(delegation_);

        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        vm.expectRevert(IDelegationManager.CannotUseADisabledDelegation.selector);
        _redeem(specializedManager, delegation_, _execution(quote_), automation);
    }

    function test_gas_compareEquivalentCanonicalAndSpecializedPaths() public {
        MetaSwapLimitOrderAdapter.ApiQuote memory quote_ =
            _quote(AMOUNT_IN, ACTUAL_AMOUNT_OUT, address(0), uint64(block.timestamp + 5 minutes), apiSignerKey);
        bytes memory execution_ = _execution(quote_);
        Delegation memory canonical_ = _canonicalDelegation(uint64(block.timestamp + 1 days));
        Delegation memory specialized_ = _specializedDelegation(uint64(block.timestamp + 1 days));

        uint256 snapshot_ = saveGasSnapshot();
        GasMeasurement memory canonicalGas_ = measureManagerCall(
            address(delegationManager),
            automation,
            encodeRedeemCall(_delegationArray(canonical_), ModeLib.encodeSimpleBatch(), execution_)
        );
        restoreGasSnapshot(snapshot_);

        GasMeasurement memory specializedGas_ = measureManagerCall(
            address(specializedManager),
            automation,
            encodeRedeemCall(_delegationArray(specialized_), ModeLib.encodeSimpleBatch(), execution_)
        );

        logGasReport("MetaSwap limit order | canonical manager + enforcer", canonicalGas_);
        logGasReport("MetaSwap limit order | specialized manager", specializedGas_);
        assertLt(specializedGas_.estimatedTxGas, canonicalGas_.estimatedTxGas);
    }

    function _canonicalDelegation(uint64 _validUntil) private view returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: abi.encode(_terms(_validUntil)), args: hex"" });
        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: automation,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 1,
                signature: hex""
            })
        );
    }

    function _specializedDelegation(uint64 _validUntil) private view returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(specializedManager), terms: abi.encode(_terms(_validUntil)), args: hex"" });
        delegation_ = Delegation({
            delegate: automation,
            delegator: address(specializedMaker),
            authority: specializedManager.ROOT_AUTHORITY(),
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(specializedManager.getDomainHash(), delegationHash_);
        delegation_.signature = signHash(users.alice, typedDataHash_);
    }

    function _terms(uint64 _validUntil) private view returns (MetaSwapLimitOrderLib.Terms memory terms_) {
        terms_ = MetaSwapLimitOrderLib.Terms({
            adapter: address(adapter),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN,
            minAmountOut: MIN_AMOUNT_OUT,
            validAfter: 0,
            validUntil: _validUntil
        });
    }

    function _execution(MetaSwapLimitOrderAdapter.ApiQuote memory _quoteData) private view returns (bytes memory execution_) {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(adapter), AMOUNT_IN))
        });
        executions_[1] = Execution({
            target: address(adapter),
            value: 0,
            callData: abi.encodeCall(adapter.swap, (tokenIn, tokenOut, AMOUNT_IN, MIN_AMOUNT_OUT, _quoteData))
        });
        execution_ = ExecutionLib.encodeBatch(executions_);
    }

    function _quote(
        uint256 _spendAmount,
        uint256 _outputAmount,
        address _outputRecipient,
        uint64 _validUntil,
        uint256 _signerKey
    )
        private
        view
        returns (MetaSwapLimitOrderAdapter.ApiQuote memory quote_)
    {
        quote_.aggregatorId = "mock-aggregator";
        quote_.swapData = abi.encode(_spendAmount, _outputAmount, _outputRecipient);
        quote_.validUntil = _validUntil;
        bytes32 digest_ = adapter.getQuoteDigest(
            tokenIn, tokenOut, AMOUNT_IN, MIN_AMOUNT_OUT, quote_.aggregatorId, quote_.swapData, _validUntil
        );
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, digest_);
        quote_.signature = abi.encodePacked(r_, s_, v_);
    }

    function _redeem(
        IDelegationManager _manager,
        Delegation memory _delegation,
        bytes memory _executionCallData,
        address _executor
    )
        private
    {
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(_delegationArray(_delegation));
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = _executionCallData;

        vm.prank(_executor);
        _manager.redeemDelegations(contexts_, modes_, executions_);
    }

    function _delegationArray(Delegation memory _delegation) private pure returns (Delegation[] memory delegations_) {
        delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
    }

    function _assertSettlement(address _maker) private {
        assertEq(tokenIn.balanceOf(_maker), 0);
        assertEq(tokenOut.balanceOf(_maker), ACTUAL_AMOUNT_OUT);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenOut.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.allowance(address(adapter), address(metaSwap)), 0);
    }

    function _deploySpecializedMaker() private returns (HybridDeleGator maker_) {
        HybridDeleGator implementation_ = new HybridDeleGator(specializedManager, entryPoint);
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.alice.name;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;

        maker_ = HybridDeleGator(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation_),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
                        )
                    )
                ))
        );
    }
}
