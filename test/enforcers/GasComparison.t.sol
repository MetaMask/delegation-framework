// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { MultiTokenPeriodEnforcer } from "../../src/enforcers/MultiTokenPeriodEnforcer.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { NativeTokenPeriodTransferEnforcer } from "../../src/enforcers/NativeTokenPeriodTransferEnforcer.sol";
import { ERC20PeriodTransferEnforcer } from "../../src/enforcers/ERC20PeriodTransferEnforcer.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";

contract GasComparisonTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    MultiTokenPeriodEnforcer public multiTokenEnforcer;
    NativeTokenPeriodTransferEnforcer public nativeTokenEnforcer;
    ERC20PeriodTransferEnforcer public erc20TokenEnforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    // BasicERC20[] public erc20Tokens;
    address[] public tokens;

    // Constants for test configuration
    uint256 constant NUM_NATIVE = 5;
    uint256 constant NUM_ERC20 = 5;
    uint256 constant PERIOD_AMOUNT = 1 ether;
    uint256 constant PERIOD_DURATION = 1 days;
    uint256 startDate;
    address constant RECIPIENT = address(0x123);

    // A dummy delegation hash for simulation
    bytes32 _dummyDelegationHash = keccak256("test-delegation");
    address _redeemer = address(0x123);

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        multiTokenEnforcer = new MultiTokenPeriodEnforcer();
        nativeTokenEnforcer = new NativeTokenPeriodTransferEnforcer();
        erc20TokenEnforcer = new ERC20PeriodTransferEnforcer();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();

        // Deploy ERC20 tokens
        tokens = new address[](NUM_NATIVE + NUM_ERC20);
        // Fills the first 5 elements with erc20, the rest with native
        for (uint256 i = 0; i < NUM_ERC20; i++) {
            tokens[i] = address(
                new BasicERC20(address(this), string(abi.encodePacked("Token", i)), string(abi.encodePacked("TK", i)), 100 ether)
            );
        }

        // Label contracts for better debugging
        vm.label(address(logicalOrWrapperEnforcer), "Logical OR Wrapper Enforcer");
        vm.label(address(multiTokenEnforcer), "Multi Token Period Enforcer");
        vm.label(address(nativeTokenEnforcer), "Native Token Period Enforcer");
        vm.label(address(erc20TokenEnforcer), "ERC20 Token Period Enforcer");

        // Ensure the sender has ETH for native token tests
        vm.deal(address(this), 100 ether);

        // Set block timestamp to start date
        // vm.warp(START_DATE);
        startDate = block.timestamp;
    }

    ////////////////////// Helper Functions //////////////////////
    function _encodeERC20Transfer(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount);
    }

    function _encodeSingleExecution(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return ExecutionLib.encodeSingle(_target, _value, _callData);
    }

    function _encodeNativeTransfer(address _target, uint256 _value) internal pure returns (bytes memory) {
        return ExecutionLib.encodeSingle(_target, _value, "");
    }

    function _createCaveatGroup(
        address[] memory _enforcers,
        bytes[] memory _terms
    )
        internal
        pure
        returns (LogicalOrWrapperEnforcer.CaveatGroup memory)
    {
        require(_enforcers.length == _terms.length, "GasComparisonTest:invalid-input-length");
        Caveat[] memory caveats = new Caveat[](_enforcers.length);
        for (uint256 i = 0; i < _enforcers.length; ++i) {
            caveats[i] = Caveat({ enforcer: _enforcers[i], terms: _terms[i], args: hex"" });
        }
        return LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveats });
    }

    function _createSelectedGroup(
        uint256 _groupIndex,
        bytes[] memory _caveatArgs
    )
        internal
        pure
        returns (LogicalOrWrapperEnforcer.SelectedGroup memory)
    {
        return LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: _groupIndex, caveatArgs: _caveatArgs });
    }

    ////////////////////// Test Cases //////////////////////

    /// @notice Tests gas usage for LogicalOrWrapperEnforcer with 10 token configurations
    function test_GasUsageLogicalOrWrapper() public {
        // Create caveat groups
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](NUM_NATIVE + NUM_ERC20);

        address[] memory erc20Enforcers = new address[](2);
        erc20Enforcers[0] = address(erc20TokenEnforcer);
        erc20Enforcers[1] = address(valueLteEnforcer);

        address[] memory nativeEnforcers = new address[](2);
        nativeEnforcers[0] = address(nativeTokenEnforcer);
        nativeEnforcers[1] = address(exactCalldataEnforcer);

        // Creating terms for both native and ERC20 token enforcers
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) {
                // Create terms for native token enforcer
                bytes[] memory nativeTerms = new bytes[](2);
                nativeTerms[0] = abi.encodePacked(PERIOD_AMOUNT, PERIOD_DURATION, startDate);
                nativeTerms[1] = hex""; // No calldata allowed
                groups[i] = _createCaveatGroup(nativeEnforcers, nativeTerms);
            } else {
                // Create terms for ERC20 token enforcer
                bytes[] memory erc20Terms = new bytes[](2);
                erc20Terms[0] = abi.encodePacked(tokens[i], PERIOD_AMOUNT, PERIOD_DURATION, startDate);
                erc20Terms[1] = abi.encode(uint256(0)); // No value allowed
                groups[i] = _createCaveatGroup(erc20Enforcers, erc20Terms);
            }
        }

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups), args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegator: address(users.alice.deleGator),
            delegate: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Sign the delegation with Alice's key
        delegation_ = signDelegation(users.alice, delegation_);

        for (uint256 i = 0; i < tokens.length; i++) {
            LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(i, new bytes[](2));

            delegation_.caveats[0].args = abi.encode(selectedGroup_);

            // Pack delegations into array
            Delegation[] memory delegations_ = new Delegation[](1);
            delegations_[0] = delegation_;

            // uint256 balanceBefore = _getBalance(tokens[i], RECIPIENT);

            // Have Bob redeem the delegation
            invokeDelegation_UserOp(users.bob, delegations_, _getExecution(tokens[i], RECIPIENT, PERIOD_AMOUNT / 2));

            // uint256 balanceAfter = _getBalance(tokens[i], RECIPIENT);

            // assertEq(balanceAfter, balanceBefore + PERIOD_AMOUNT / 2, "Balance not transferred");
        }
    }

    function _getBalance(address token_, address recipient_) internal view returns (uint256) {
        if (token_ == address(0)) {
            return recipient_.balance;
        } else {
            return IERC20(token_).balanceOf(recipient_);
        }
    }

    function _getExecution(address token_, address recipient_, uint256 amount_) internal pure returns (Execution memory) {
        if (token_ == address(0)) {
            return Execution({ target: recipient_, value: amount_, callData: hex"" });
        } else {
            return Execution({ target: token_, value: 0, callData: _encodeERC20Transfer(recipient_, amount_) });
        }
    }

    function createAndRedeemDelegation() internal {
        // Create a simple delegation from Alice to Bob
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(logicalOrWrapperEnforcer),
            terms: abi.encodePacked(address(0), PERIOD_AMOUNT, PERIOD_DURATION, startDate),
            args: hex""
        });

        Delegation memory delegation_ = Delegation({
            delegator: address(users.alice.deleGator),
            delegate: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Sign the delegation with Alice's key
        delegation_ = signDelegation(users.alice, delegation_);

        // Create execution for Bob to redeem
        Execution memory execution_ = Execution({ target: RECIPIENT, value: PERIOD_AMOUNT / 2, callData: hex"" });

        // Pack delegations into array
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Have Bob redeem the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
    }

    // /// @notice Tests gas usage for MultiTokenPeriodEnforcer with 10 token configurations
    // function test_GasUsageMultiTokenPeriod() public {
    //     // Create terms for all tokens (5 native + 5 ERC20)
    //     bytes memory terms;
    //     for (uint256 i = 0; i < NUM_NATIVE; i++) {
    //         terms = bytes.concat(terms, abi.encodePacked(address(0), PERIOD_AMOUNT, PERIOD_DURATION, START_DATE));
    //     }
    //     for (uint256 i = 0; i < NUM_ERC20; i++) {
    //         terms = bytes.concat(terms, abi.encodePacked(address(erc20Tokens[i]), PERIOD_AMOUNT, PERIOD_DURATION, START_DATE));
    //     }

    //     uint256 gasUsed = 0;

    //     // Test native token transfers
    //     for (uint256 i = 0; i < NUM_NATIVE; i++) {
    //         bytes memory args = abi.encode(i);
    //         bytes memory execData = _encodeNativeTransfer(address(0x123), PERIOD_AMOUNT / 2);
    //         uint256 startGas = gasleft();
    //         multiTokenEnforcer.beforeHook(terms, args, singleDefaultMode, execData, _dummyDelegationHash, address(0), _redeemer);
    //         gasUsed += startGas - gasleft();
    //     }

    //     // Test ERC20 token transfers
    //     for (uint256 i = 0; i < NUM_ERC20; i++) {
    //         bytes memory args = abi.encode(NUM_NATIVE + i);
    //         bytes memory callData = _encodeERC20Transfer(address(0x123), PERIOD_AMOUNT / 2);
    //         bytes memory execData = _encodeSingleExecution(address(erc20Tokens[i]), 0, callData);
    //         uint256 startGas = gasleft();
    //         multiTokenEnforcer.beforeHook(terms, args, singleDefaultMode, execData, _dummyDelegationHash, address(0), _redeemer);
    //         gasUsed += startGas - gasleft();
    //     }

    //     console2.log("Total gas used for MultiTokenPeriodEnforcer:", gasUsed);
    // }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(multiTokenEnforcer));
    }
}
