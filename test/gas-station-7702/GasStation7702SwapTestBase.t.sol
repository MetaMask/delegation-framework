// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { MockMetaSwapRouter } from "../utils/MockMetaSwapRouter.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { IERC7821 } from "../../src/interfaces/IERC7821.sol";
import { ExactExecutionEnforcer } from "../../src/enforcers/ExactExecutionEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { SpecificActionERC20TransferBatchEnforcer } from "../../src/enforcers/SpecificActionERC20TransferBatchEnforcer.sol";

/**
 * @notice Shared 7702 + swap fixtures matching metamask-mobile `Delegation7702PublishHook`.
 *
 * @dev Relayer path (not a UserOp): `vm.prank(relayer)` → `DelegationManager.redeemDelegations`.
 *      Delegate is `ANY_DELEGATE` (`0xa11`), same as mobile `ANY_BENEFICIARY`.
 *
 * @dev 7702 wrap: TransactionController `generateEIP7702BatchTransaction` sets
 *      `txParams.to = from` and `txParams.data = IERC7821.execute(batchMode, nested)`.
 *      The publish hook never reads `nestedTransactions`; it uses that single `txParams` execution.
 */
abstract contract GasStation7702SwapTestBase is BaseTest {
    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    uint256 internal constant SWAP_AMOUNT = 1 ether;
    uint256 internal constant FEE_AMOUNT = 0.01 ether;

    ExactExecutionEnforcer internal exactExecutionEnforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;
    SpecificActionERC20TransferBatchEnforcer internal specificActionEnforcer;

    BasicERC20 internal usdc;
    BasicERC20 internal destToken;
    MockMetaSwapRouter internal router;

    address internal relayer;
    address internal feeRecipient;
    address internal alice7702;

    function setUp() public virtual override {
        super.setUp();

        exactExecutionEnforcer = new ExactExecutionEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        specificActionEnforcer = new SpecificActionERC20TransferBatchEnforcer();
        vm.label(address(exactExecutionEnforcer), "ExactExecutionEnforcer");
        vm.label(address(limitedCallsEnforcer), "LimitedCallsEnforcer");
        vm.label(address(specificActionEnforcer), "SpecificActionERC20TransferBatchEnforcer");

        alice7702 = address(users.alice.deleGator);

        usdc = new BasicERC20(address(this), "USD Coin", "USDC", 0);
        destToken = new BasicERC20(address(this), "MetaMask USD", "MUSD", 0);
        usdc.mint(alice7702, 1_000 ether);
        destToken.mint(address(this), 1_000 ether);

        router = new MockMetaSwapRouter(destToken);
        destToken.transfer(address(router), 1_000 ether);
        vm.label(address(router), "MockMetaSwapRouter");

        relayer = makeAddr("SentinelRelayer");
        feeRecipient = makeAddr("MetaMaskFeeRecipient");
    }

    /// @dev Mobile `#buildUnsignedDelegation`: root, `to: ANY_BENEFICIARY`, signed by the 7702 EOA.
    function _signOpenDelegation(Caveat[] memory caveats_) internal view returns (Delegation memory delegation_) {
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice7702, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
    }

    /// @dev Mobile `encodeRedeemDelegations` — one permission context, one mode, one execution payload.
    function _redeem(Delegation memory delegation_, ModeCode mode_, bytes memory executionCallData_) internal {
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

    /**
     * @dev TransactionController `generateEIP7702BatchTransaction`:
     *      `to = from`, `data = execute(CALLTYPE_BATCH, abi.encode(calls))`.
     *      Native nested = `[swap{value}]`. ERC-20 nested = `[approve, swap]`.
     */
    function _wrapAs7702Execute(Execution[] memory nested_) internal view returns (Execution memory) {
        bytes memory executeCalldata_ =
            abi.encodeCall(IERC7821.execute, (ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(nested_)));
        return Execution({ target: alice7702, value: 0, callData: executeCalldata_ });
    }

    function _nativeSwapNested() internal view returns (Execution[] memory nested_) {
        nested_ = new Execution[](1);
        nested_[0] = Execution({
            target: address(router),
            value: SWAP_AMOUNT,
            callData: abi.encodeCall(MockMetaSwapRouter.swapNative, (SWAP_AMOUNT, alice7702))
        });
    }

    function _erc20SwapNested() internal view returns (Execution[] memory nested_) {
        nested_ = new Execution[](2);
        nested_[0] = Execution({
            target: address(usdc), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), SWAP_AMOUNT))
        });
        nested_[1] = Execution({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(MockMetaSwapRouter.swapERC20, (usdc, SWAP_AMOUNT, SWAP_AMOUNT, alice7702))
        });
    }

    function _exactExecutionCaveat(Execution memory execution_) internal view returns (Caveat memory) {
        return Caveat({
            enforcer: address(exactExecutionEnforcer),
            terms: ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            args: hex""
        });
    }

    function _limitedCallsCaveat(uint256 limit_) internal view returns (Caveat memory) {
        return Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(limit_), args: hex"" });
    }

    /// @dev Mobile `specificActionERC20TransferBatchBuilder` packed terms.
    function _specificActionCaveat(
        address feeToken_,
        address feeRecipient_,
        uint256 feeAmount_,
        Execution memory first_
    )
        internal
        view
        returns (Caveat memory)
    {
        return Caveat({
            enforcer: address(specificActionEnforcer),
            terms: abi.encodePacked(feeToken_, feeRecipient_, feeAmount_, first_.target, first_.value, first_.callData),
            args: hex""
        });
    }

    function _feeTransferExecution() internal view returns (Execution memory) {
        return Execution({ target: address(usdc), value: 0, callData: abi.encodeCall(IERC20.transfer, (feeRecipient, FEE_AMOUNT)) });
    }
}
