// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { LimitOrderSwapAdapter } from "../../../src/experiments/oneshot/LimitOrderSwapAdapter.sol";
import { MockSwapRouter } from "./MockSwapRouter.sol";

/**
 * @notice O-adapter unit tests: bound router, SafeERC20, on-chain minOut enforcement.
 */
contract LimitOrderSwapAdapterTest is BaseTest {
    LimitOrderSwapAdapter internal adapter;
    MockSwapRouter internal router;
    BasicERC20 internal sellToken;
    BasicERC20 internal buyToken;

    address internal receiver;

    uint256 internal constant SELL_AMOUNT = 50e18;
    uint256 internal constant MIN_BUY = 48e18;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        adapter = new LimitOrderSwapAdapter(delegationManager);
        router = new MockSwapRouter();
        adapter.setRouterAllowed(address(router), true);

        sellToken = new BasicERC20(address(this), "SELL", "SELL", 0);
        buyToken = new BasicERC20(address(this), "BUY", "BUY", 0);
        sellToken.mint(address(users.alice.deleGator), 1_000_000e18);
        buyToken.mint(address(router), 1_000_000e18);

        receiver = makeAddr("adapter-receiver");
    }

    function test_swap_happyPath() public {
        _swap(MIN_BUY);
        assertEq(buyToken.balanceOf(receiver), MIN_BUY);
    }

    function test_revertWhen_routerNotAllowed() public {
        adapter.setRouterAllowed(address(router), false);
        bytes memory routerCalldata_ = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, sellToken, buyToken, SELL_AMOUNT, MIN_BUY, receiver, address(0), hex""
        );
        vm.startPrank(address(users.alice.deleGator));
        sellToken.approve(address(adapter), SELL_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderSwapAdapter.RouterNotAllowed.selector, address(router)));
        adapter.swap(sellToken, buyToken, SELL_AMOUNT, MIN_BUY, receiver, address(router), routerCalldata_);
        vm.stopPrank();
    }

    function test_revertWhen_minOutNotMet() public {
        bytes memory routerCalldata_ = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, sellToken, buyToken, SELL_AMOUNT, MIN_BUY - 1, receiver, address(0), hex""
        );
        vm.startPrank(address(users.alice.deleGator));
        sellToken.approve(address(adapter), SELL_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderSwapAdapter.InsufficientBuyDelivered.selector, MIN_BUY, MIN_BUY - 1)
        );
        adapter.swap(sellToken, buyToken, SELL_AMOUNT, MIN_BUY, receiver, address(router), routerCalldata_);
        vm.stopPrank();
    }

    function _swap(uint256 _buyAmount) internal {
        bytes memory routerCalldata_ = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, sellToken, buyToken, SELL_AMOUNT, _buyAmount, receiver, address(0), hex""
        );
        vm.startPrank(address(users.alice.deleGator));
        sellToken.approve(address(adapter), SELL_AMOUNT);
        adapter.swap(sellToken, buyToken, SELL_AMOUNT, MIN_BUY, receiver, address(router), routerCalldata_);
        vm.stopPrank();
    }
}
