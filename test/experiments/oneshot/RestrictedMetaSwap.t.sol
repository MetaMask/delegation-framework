// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation } from "../../../src/utils/Types.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { GasExperimentHarness } from "../gas/GasExperimentHarness.sol";
import { RestrictedMetaSwapAdapter } from "../../../src/experiments/oneshot/RestrictedMetaSwapAdapter.sol";
import { RestrictedMetaSwapEnforcer } from "../../../src/experiments/oneshot/RestrictedMetaSwapEnforcer.sol";

contract MockMetaSwapForRestrictedAdapter is IMetaSwap {
    using SafeERC20 for IERC20;

    IERC20 internal immutable buyToken;

    constructor(IERC20 _buyToken) {
        buyToken = _buyToken;
    }

    function swap(string calldata, IERC20 _tokenFrom, uint256 _amount, bytes calldata _data) external payable {
        uint256 buyAmount_ = abi.decode(_data, (uint256));
        _tokenFrom.safeTransferFrom(msg.sender, address(this), _amount);
        buyToken.safeTransfer(msg.sender, buyAmount_);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract RestrictedMetaSwapTest is Test {
    BasicERC20 internal sellToken;
    BasicERC20 internal buyToken;
    MockMetaSwapForRestrictedAdapter internal metaSwap;
    RestrictedMetaSwapAdapter internal adapter;
    RestrictedMetaSwapEnforcer internal enforcer;

    address internal maker = makeAddr("maker");
    address internal receiver = makeAddr("receiver");
    bytes32 internal delegationHash = keccak256("delegation");

    function setUp() public {
        sellToken = new BasicERC20(address(this), "Sell", "SELL", 0);
        buyToken = new BasicERC20(address(this), "Buy", "BUY", 0);
        metaSwap = new MockMetaSwapForRestrictedAdapter(buyToken);
        adapter = new RestrictedMetaSwapAdapter(metaSwap);
        enforcer = new RestrictedMetaSwapEnforcer();

        sellToken.mint(maker, 100 ether);
        buyToken.mint(address(metaSwap), 1_000 ether);
        vm.prank(maker);
        sellToken.approve(address(adapter), type(uint256).max);
    }

    function test_adapter_allowsAmountToOrGreater() public {
        vm.prank(maker);
        uint256 received_ = adapter.swap("mock", sellToken, buyToken, 100 ether, 190 ether, receiver, abi.encode(200 ether));

        assertEq(received_, 200 ether);
        assertEq(buyToken.balanceOf(receiver), 200 ether);
        assertEq(sellToken.balanceOf(maker), 0);
    }

    function test_adapter_revertsBelowMinimum() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(RestrictedMetaSwapAdapter.InsufficientBuyAmount.selector, 190 ether, 180 ether));
        adapter.swap("mock", sellToken, buyToken, 100 ether, 190 ether, receiver, abi.encode(180 ether));
    }

    function test_enforcer_bindsPairInputReceiverAggregatorAndMinimum() public {
        RestrictedMetaSwapEnforcer.Terms memory terms_ = _terms();
        bytes memory execution_ = _execution(100 ether, 190 ether, receiver, "mock");

        enforcer.beforeHook(
            abi.encode(terms_), hex"", ModeLib.encodeSimpleSingle(), execution_, delegationHash, maker, address(this)
        );
        buyToken.mint(receiver, 200 ether);
        enforcer.afterHook(
            abi.encode(terms_), hex"", ModeLib.encodeSimpleSingle(), execution_, delegationHash, maker, address(this)
        );
    }

    function test_enforcer_rejectsWrongInputAmount() public {
        vm.expectRevert(RestrictedMetaSwapEnforcer.InvalidExecution.selector);
        enforcer.beforeHook(
            abi.encode(_terms()),
            hex"",
            ModeLib.encodeSimpleSingle(),
            _execution(99 ether, 190 ether, receiver, "mock"),
            delegationHash,
            maker,
            address(this)
        );
    }

    function test_enforcer_rejectsWrongBuyToken() public {
        BasicERC20 wrongBuy_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        bytes memory callData_ = abi.encodeCall(
            RestrictedMetaSwapAdapter.swap, ("mock", sellToken, wrongBuy_, 100 ether, 190 ether, receiver, abi.encode(200 ether))
        );
        bytes memory execution_ = ExecutionLib.encodeSingle(address(adapter), 0, callData_);

        vm.expectRevert(RestrictedMetaSwapEnforcer.InvalidExecution.selector);
        enforcer.beforeHook(
            abi.encode(_terms()), hex"", ModeLib.encodeSimpleSingle(), execution_, delegationHash, maker, address(this)
        );
    }

    function test_enforcer_rejectsMinimumBelowSignedFloor() public {
        vm.expectRevert(RestrictedMetaSwapEnforcer.InvalidExecution.selector);
        enforcer.beforeHook(
            abi.encode(_terms()),
            hex"",
            ModeLib.encodeSimpleSingle(),
            _execution(100 ether, 189 ether, receiver, "mock"),
            delegationHash,
            maker,
            address(this)
        );
    }

    function _terms() private view returns (RestrictedMetaSwapEnforcer.Terms memory) {
        return RestrictedMetaSwapEnforcer.Terms({
            adapter: address(adapter),
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            receiver: receiver,
            sellAmount: 100 ether,
            minBuyAmount: 190 ether,
            aggregatorIdHash: keccak256(bytes("mock"))
        });
    }

    function _execution(
        uint256 _sellAmount,
        uint256 _minBuyAmount,
        address _receiver,
        string memory _aggregatorId
    )
        private
        view
        returns (bytes memory)
    {
        bytes memory callData_ = abi.encodeCall(
            RestrictedMetaSwapAdapter.swap,
            (_aggregatorId, sellToken, buyToken, _sellAmount, _minBuyAmount, _receiver, abi.encode(200 ether))
        );
        return ExecutionLib.encodeSingle(address(adapter), 0, callData_);
    }
}

contract RestrictedMetaSwapGasBenchmark is BaseTest, GasExperimentHarness {
    BasicERC20 internal sellToken;
    BasicERC20 internal buyToken;
    MockMetaSwapForRestrictedAdapter internal metaSwap;
    RestrictedMetaSwapAdapter internal adapter;
    RestrictedMetaSwapEnforcer internal enforcer;

    address internal relayer;
    address internal receiver;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        sellToken = new BasicERC20(address(this), "Sell", "SELL", 0);
        buyToken = new BasicERC20(address(this), "Buy", "BUY", 0);
        metaSwap = new MockMetaSwapForRestrictedAdapter(buyToken);
        adapter = new RestrictedMetaSwapAdapter(metaSwap);
        enforcer = new RestrictedMetaSwapEnforcer();
        relayer = makeAddr("restricted-metaswap-relayer");
        receiver = makeAddr("restricted-metaswap-receiver");

        sellToken.mint(address(users.alice.deleGator), 100 ether);
        buyToken.mint(address(metaSwap), 200 ether);
        vm.prank(address(users.alice.deleGator));
        sellToken.approve(address(adapter), type(uint256).max);
    }

    function test_gas_restrictedMetaSwap_redeemDelegations() public {
        RestrictedMetaSwapEnforcer.Terms memory terms_ = RestrictedMetaSwapEnforcer.Terms({
            adapter: address(adapter),
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            receiver: receiver,
            sellAmount: 100 ether,
            minBuyAmount: 190 ether,
            aggregatorIdHash: keccak256(bytes("mock"))
        });
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: abi.encode(terms_), args: hex"" });

        Delegation memory delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: relayer,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 44,
                signature: hex""
            })
        );

        bytes memory callData_ = abi.encodeCall(
            RestrictedMetaSwapAdapter.swap,
            ("mock", sellToken, buyToken, 100 ether, 190 ether, receiver, abi.encode(200 ether))
        );
        bytes memory execution_ = ExecutionLib.encodeSingle(address(adapter), 0, callData_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory measurement_ =
            measureManagerCall(address(delegationManager), relayer, encodeRedeemCall(delegations_, ModeLib.encodeSimpleSingle(), execution_));
        restoreGasSnapshot(snap_);
        logGasReport("O-restricted-metaswap | pair+input+min-output | redeemDelegations", measurement_);
    }
}
