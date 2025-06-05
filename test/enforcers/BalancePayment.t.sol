// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import "../../src/utils/Types.sol";
import { Execution, Caveat, Delegation, ModeCode, CallType, ExecType } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ERC20BalanceChangeTotalEnforcer } from "../../src/enforcers/ERC20BalanceChangeTotalEnforcer.sol";
import { ERC20BalanceChangeAllHookEnforcer } from "../../src/enforcers/ERC20BalanceChangeAllHookEnforcer.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../../src/utils/Constants.sol";
import { console2 } from "forge-std/console2.sol";

contract BalancePaymentTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20TransferAmountEnforcer public transferAmountEnforcer;
    ERC20BalanceChangeEnforcer public balanceChangeEnforcer;
    ERC20BalanceChangeTotalEnforcer public balanceChangeTotalEnforcer;
    ERC20BalanceChangeAllHookEnforcer public balanceChangeAllHookEnforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    BasicERC20 public tokenA;
    BasicERC20 public tokenB;
    SwapMock public swapMock;
    address someUser;
    address delegator;
    address delegate;
    address dm;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Deploy SwapMock and set it as the delegate
        swapMock = new SwapMock(delegationManager);
        dm = address(delegationManager);
        delegator = address(users.alice.deleGator);
        delegate = address(swapMock);
        vm.label(delegate, "Swap Mock");
        someUser = makeAddr("someUser");
        vm.label(someUser, "Some User");

        // Deploy test tokens
        tokenA = new BasicERC20(delegator, "TokenA", "TKA", 100 ether);
        tokenB = new BasicERC20(delegate, "TokenB", "TKB", 100 ether);
        vm.label(address(tokenA), "Token A");
        vm.label(address(tokenB), "Token B");
        swapMock.setTokens(address(tokenA), address(tokenB));

        // Deploy enforcers
        transferAmountEnforcer = new ERC20TransferAmountEnforcer();
        balanceChangeEnforcer = new ERC20BalanceChangeEnforcer();
        balanceChangeTotalEnforcer = new ERC20BalanceChangeTotalEnforcer();
        balanceChangeAllHookEnforcer = new ERC20BalanceChangeAllHookEnforcer();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        vm.label(address(transferAmountEnforcer), "ERC20 Transfer Amount Enforcer");
        vm.label(address(balanceChangeEnforcer), "ERC20 Balance Change Enforcer");
        vm.label(address(balanceChangeTotalEnforcer), "ERC20 Balance Change Total Enforcer");
        vm.label(address(balanceChangeAllHookEnforcer), "ERC20 Balance Change All Hook Enforcer");
        vm.label(address(exactCalldataEnforcer), "Exact Calldata Enforcer");
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        vm.label(address(valueLteEnforcer), "Value Lte Enforcer");
    }

    ////////////////////// Test Cases //////////////////////

    /// @notice Tests enforcement of minimum balance increase requirement in a token swap scenario
    /// @dev Verifies that ERC20BalanceChangeEnforcer correctly reverts when:
    ///      1. TokenA is sent from delegator to SwapMock
    ///      2. The required minimum increase in TokenB balance is not met
    /// This test ensures the ERC20BalanceChangeEnforcer properly protects against failed or incomplete swaps
    /// But it is very restrictive because it doesn't allow a space for the payment to be made.
    function test_ERC20BalanceChangeEnforcer_failWhenPaymentNotReceived() public {
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegator), uint256(2 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of TokenA
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the balance of the recipient to increase by 2 ETH worth of TokenB
        caveats_[1] = Caveat({ args: hex"", enforcer: address(balanceChangeEnforcer), terms: balanceTerms_ });

        Delegation memory delegation = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        swapMock.swap(delegations_, 1 ether);
    }

    /// @notice Tests nested delegations for a token swap with strict parameter validation
    ///
    /// Flow:
    /// 1. Inner delegation: Alice -> SwapMock
    ///    - Allows SwapMock to transfer TokenA from Alice
    ///
    /// 2. Outer delegation: Alice -> SomeUser
    ///    - Enforces exact swap parameters:
    ///      - Exact calldata for swap function
    ///      - Only allows calling SwapMock contract
    ///      - No ETH value allowed
    ///      - Requires receiving TokenB back
    ///
    /// NOTES:
    /// This approach works but it assumes that the function swap can be called by anyone.
    /// The delegation should be needed in a context where the caller is restricted and this wouldn't work.
    function test_ERC20BalanceChangeEnforcer_nestedDelegations() public {
        // Create first delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));

        Caveat[] memory innerCaveats_ = new Caveat[](1);
        // Allows to transfer 1 ETH worth of TokenA
        innerCaveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });

        Delegation memory innerDelegation_ = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: innerCaveats_,
            salt: 0,
            signature: hex""
        });

        innerDelegation_ = signDelegation(users.alice, innerDelegation_);

        Delegation[] memory innerDelegations_ = new Delegation[](1);
        innerDelegations_[0] = innerDelegation_;

        // Create second delegation with exact calldata for swap function
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegator), uint256(1 ether));
        Caveat[] memory outerCaveats_ = new Caveat[](4);
        outerCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(exactCalldataEnforcer),
            terms: abi.encodeWithSelector(SwapMock.swap.selector, innerDelegations_, 1 ether)
        });
        outerCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(swapMock)) });
        outerCaveats_[2] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encodePacked(uint256(0)) });
        outerCaveats_[3] = Caveat({ args: hex"", enforcer: address(balanceChangeEnforcer), terms: balanceTerms_ });

        Delegation memory outerDelegation_ = Delegation({
            delegate: address(someUser),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: outerCaveats_,
            salt: 1,
            signature: hex""
        });

        outerDelegation_ = signDelegation(users.alice, outerDelegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = outerDelegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(
            address(swapMock), 0, abi.encodeWithSelector(SwapMock.swap.selector, innerDelegations_, 1 ether)
        );

        assertEq(tokenA.balanceOf(address(delegator)), 100 ether, "TokenA balance of delegator should be 100 ether");
        assertEq(tokenB.balanceOf(address(delegator)), 0 ether, "TokenB balance of delegator should be 0 ether");
        assertEq(tokenA.balanceOf(address(swapMock)), 0 ether, "TokenA balance of swapMock should be 0 ether");
        assertEq(tokenB.balanceOf(address(swapMock)), 100 ether, "TokenB balance of swapMock should be 100 ether");

        vm.prank(someUser);
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        assertEq(tokenA.balanceOf(address(delegator)), 99 ether, "TokenA balance of delegator should be 99 ether");
        assertEq(tokenB.balanceOf(address(delegator)), 1 ether, "TokenB balance of delegator should be 1 ether");
        assertEq(tokenA.balanceOf(address(swapMock)), 1 ether, "TokenA balance of swapMock should be 1 ether");
        assertEq(tokenB.balanceOf(address(swapMock)), 99 ether, "TokenB balance of swapMock should be 99 ether");
    }

    /**
     * @notice Tests state sharing vulnerability in ERC20BalanceChangeAllHookEnforcer when batching delegations
     * @dev This test demonstrates an issue where multiple delegations checking the same token
     *      balance on the same recipient can lead to unintended behavior. Specifically:
     *      1. Two delegations each require a balance increase of 1 tokenB
     *      2. Each delegation transfers 1 tokenA
     *      3. Only 1 tokenB is received in return (instead of expected 2)
     *      4. Test passes incorrectly because both delegations reference the same balance state
     */
    function test_ERC20BalanceChangeAllHookEnforcer_batchingRedemptionsShareState() public {
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegator), uint256(1 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of TokenA
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the balance of the recipient to increase by 2 ETH worth of TokenB
        caveats_[1] = Caveat({ args: hex"", enforcer: address(balanceChangeAllHookEnforcer), terms: balanceTerms_ });

        Delegation memory delegation1 = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        Delegation memory delegation2 = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });

        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        // Creating two redemption flows
        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[0][0] = delegation1;
        delegations_[1] = new Delegation[](1);
        delegations_[1][0] = delegation2;
        uint256 tokenABalanceBefore = tokenA.balanceOf(address(delegator));
        uint256 tokenBBalanceBefore = tokenB.balanceOf(address(delegator));
        uint256 tokenASwapBefore = tokenA.balanceOf(address(swapMock));
        uint256 tokenBSwapBefore = tokenB.balanceOf(address(swapMock));

        swapMock.swapDoubleSpend(delegations_, 1 ether, false);

        assertEq(tokenA.balanceOf(address(delegator)), tokenABalanceBefore - 2 ether);
        assertEq(tokenB.balanceOf(address(delegator)), tokenBBalanceBefore + 1 ether);
        assertEq(tokenA.balanceOf(address(swapMock)), tokenASwapBefore + 2 ether);
        assertEq(tokenB.balanceOf(address(swapMock)), tokenBSwapBefore - 1 ether);
    }

    /**
     * @notice Tests insufficient balance increase reverts in ERC20BalanceChangeTotalEnforcer
     * @dev This test verifies that the enforcer properly reverts when total balance increase requirements
     *      are not met across batched delegations. Specifically:
     *      1. Two delegations each require a 1 ETH tokenB balance increase (2 ETH total required)
     *      2. Each delegation allows transfer of 1 ETH tokenA (2 ETH total transferred)
     *      3. Swap attempts to return only 1 ETH tokenB total when 2 ETH is required
     *      4. Transaction reverts due to insufficient balance increase
     *      5. Demonstrates enforcer properly validates cumulative balance changes
     */
    function test_ERC20BalanceChangeTotalEnforcer_revertOnInsufficientBalanceIncrease() public {
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(address(tokenB), address(delegator), uint256(1 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of TokenA
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the total balance increase of 2 ETH worth of TokenB across all delegations
        caveats_[1] = Caveat({ args: hex"", enforcer: address(balanceChangeTotalEnforcer), terms: balanceTerms_ });

        Delegation memory delegation1 = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        Delegation memory delegation2 = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });

        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        // Creating two redemption flows
        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[0][0] = delegation1;
        delegations_[1] = new Delegation[](1);
        delegations_[1][0] = delegation2;

        vm.expectRevert("ERC20BalanceChangeTotalEnforcer:insufficient-balance-increase");
        swapMock.swapDoubleSpend(delegations_, 1 ether, false);
    }

    /**
     * @notice Tests successful batch delegation redemption with balance change verification
     * @dev This test verifies that multiple delegations can be redeemed successfully with proper balance tracking:
     *      1. Creates two delegations each allowing 1 ETH tokenA transfer and requiring 1 ETH tokenB receipt
     *      2. Executes both delegations in a batch
     *      3. Verifies tokenA was deducted (-2 ETH total) and tokenB was received (+2 ETH total)
     *      4. Demonstrates proper balance accounting across batched delegations
     */
    function test_ERC20BalanceChangeTotalEnforcer_successfulBatchRedemption() public {
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(address(tokenB), address(delegator), uint256(1 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of TokenA
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the total balance increase of 2 ETH worth of TokenB across all delegations
        caveats_[1] = Caveat({ args: hex"", enforcer: address(balanceChangeTotalEnforcer), terms: balanceTerms_ });

        Delegation memory delegation1 = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        Delegation memory delegation2 = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });

        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        // Creating two redemption flows
        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[0][0] = delegation1;
        delegations_[1] = new Delegation[](1);
        delegations_[1][0] = delegation2;

        uint256 tokenABalanceBefore = tokenA.balanceOf(address(delegator));
        uint256 tokenBBalanceBefore = tokenB.balanceOf(address(delegator));

        swapMock.swapDoubleSpend(delegations_, 1 ether, true);

        assertEq(tokenA.balanceOf(address(delegator)), tokenABalanceBefore - 2 ether);
        assertEq(tokenB.balanceOf(address(delegator)), tokenBBalanceBefore + 2 ether);
    }

    // Override helper from BaseTest
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(transferAmountEnforcer));
    }
}

contract SwapMock is ExecutionHelper {
    IDelegationManager public delegationManager;
    IERC20 public tokenIn;
    IERC20 public tokenOut;

    error NotSelf();
    error UnsupportedCallType(CallType callType);
    error UnsupportedExecType(ExecType execType);

    /**
     * @notice Require the function call to come from the this contract itself.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(IDelegationManager _delegationManager) {
        delegationManager = _delegationManager;
    }

    function setTokens(address _tokenIn, address _tokenOut) external {
        tokenIn = IERC20(_tokenIn);
        tokenOut = IERC20(_tokenOut);
    }

    // This contract swaps X amount of tokensIn for the amount of tokensOut
    function swap(Delegation[] memory _delegations, uint256 _amountIn) external {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(tokenIn), 0, abi.encodeCall(IERC20.transfer, (address(this), _amountIn)));

        // If the normal ERC20BalanceChangeEnforcer is used, this will revert because even when the exection is
        // succesful and the tokens get transferred to the SwapMock, this contract doesn't have a change to pay Alice with the
        // tokensOut.
        // Immediately after the execution the balance of Alice should increase and that can't happen here since it needs the
        // redemption to finish to then pay the tokensOut.
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Some condition representing the need for the ERC20 tokensIn at this point to continue with the execution
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));
        require(balanceTokenIn_ >= _amountIn, "SwapMock:insufficient-balance-in");

        // This is a big assumption
        address recipient_ = _delegations[0].delegator;
        // Transfer the amount of tokensOut to the recipient after receiving the tokensIn
        tokenOut.transfer(recipient_, _amountIn);
    }

    // Uses more than one delegation to transfer tokens from the delegator to the SwapMock
    function swapDoubleSpend(Delegation[][] memory _delegations, uint256 _amountIn, bool _isFair) external {
        uint256 length_ = _delegations.length;
        bytes[] memory permissionContexts_ = new bytes[](length_ + 1);
        for (uint256 i = 0; i < length_; i++) {
            permissionContexts_[i] = abi.encode(_delegations[i]);
        }
        permissionContexts_[length_] = abi.encode(new Delegation[](0));

        ModeCode[] memory encodedModes_ = new ModeCode[](length_ + 1);
        for (uint256 i = 0; i < length_ + 1; i++) {
            encodedModes_[i] = ModeLib.encodeSimpleSingle();
        }

        bytes memory executionCalldata_ = ExecutionLib.encodeSingle(
            address(tokenIn), 0, abi.encodeWithSelector(IERC20.transfer.selector, address(this), _amountIn)
        );
        bytes[] memory executionCallDatas_ = new bytes[](length_ + 1);
        for (uint256 i = 0; i < length_; i++) {
            executionCallDatas_[i] = executionCalldata_;
        }

        bytes4 selector_ = _isFair ? this.validateAndTransferFair.selector : this.validateAndTransferUnfair.selector;

        // This is a big assumption
        // The first delegation.delegate is the one that will receive the tokensOut
        executionCallDatas_[length_] = ExecutionLib.encodeSingle(
            address(this), 0, abi.encodeWithSelector(selector_, _delegations[0][0].delegator, length_, _amountIn)
        );

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    /**
     * @notice Validates that enough tokens were received and transfers output tokens to caller
     * @dev Can only be called by this contract itself via onlySelf modifier
     * @param _delegationsLength The number of delegations that were processed
     * @param _amountIn The input amount per delegation
     */
    function validateAndTransferUnfair(address _recipient, uint256 _delegationsLength, uint256 _amountIn) external onlySelf {
        // Some condition representing the need for the ERC20 tokensIn at this point
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));

        // Required the amount in multiple times
        require(balanceTokenIn_ >= _amountIn * _delegationsLength, "SwapMock:insufficient-balance-in");

        // No matter how many delegations are processed, the amount of tokenB is the amountIn only once.
        // To make it fair, we would need to transfer the amountIn for each delegation.
        tokenOut.transfer(_recipient, _amountIn);
    }

    /**
     * @notice Validates that enough tokens were received and transfers output tokens to caller
     * @dev Can only be called by this contract itself via onlySelf modifier
     * @param _delegationsLength The number of delegations that were processed
     * @param _amountIn The input amount per delegation
     */
    function validateAndTransferFair(address _recipient, uint256 _delegationsLength, uint256 _amountIn) external onlySelf {
        // Some condition representing the need for the ERC20 tokensIn at this point
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));

        uint256 fairAmount_ = _amountIn * _delegationsLength;

        // Required the amount in multiple times
        require(balanceTokenIn_ >= fairAmount_, "SwapMock:insufficient-balance-in");

        // This makes it fair, for each tokenA the same amount of tokenB
        tokenOut.transfer(_recipient, fairAmount_);
    }

    /**
     * @notice Executes one calls on behalf of this contract,
     *         authorized by the DelegationManager.
     * @dev Only callable by the DelegationManager. Supports single-call execution,
     *         and handles the revert logic via ExecType.
     * @dev Related: @erc7579/MSAAdvanced.sol
     * @param _mode The encoded execution mode of the transaction (CallType, ExecType, etc.).
     * @param _executionCalldata The encoded call data (single) to be executed.
     * @return returnData_ An array of returned data from each executed call.
     */
    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        returns (bytes[] memory returnData_)
    {
        require(msg.sender == address(delegationManager), "SwapMock:not-delegation-manager");

        (CallType callType_, ExecType execType_,,) = ModeLib.decode(_mode);

        // Only support single call type with default execution
        if (CallType.unwrap(CALLTYPE_SINGLE) != CallType.unwrap(callType_)) revert UnsupportedCallType(callType_);
        if (ExecType.unwrap(EXECTYPE_DEFAULT) != ExecType.unwrap(execType_)) revert UnsupportedExecType(execType_);

        // Process single execution directly without additional checks
        (address target_, uint256 value_, bytes calldata callData_) = ExecutionLib.decodeSingle(_executionCalldata);

        returnData_ = new bytes[](1);
        returnData_[0] = _execute(target_, value_, callData_);
        return returnData_;
    }
}
