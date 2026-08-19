// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../../utils/Types.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { SigningUtilsLib } from "../../utils/SigningUtilsLib.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../../src/interfaces/IDelegationManager.sol";
import { ExactExecutionBatchLimitedCallsEnforcer } from "../../../src/enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";
import { CompactOrderCodec } from "../../../src/experiments/X1/CompactOrderCodec.sol";
import { X1CompactOrderDelegationManager } from "../../../src/experiments/X1/X1CompactOrderDelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { DeleGatorCore } from "../../../src/DeleGatorCore.sol";

import { GasExperimentHarness } from "./GasExperimentHarness.sol";

/**
 * @notice X1 compact fixed-schema order encoding benchmark vs standard ABI decode.
 * @dev Run: `forge test --isolate -vv --match-contract X1CompactOrderBenchmark`
 */
contract X1CompactOrderBenchmark is BaseTest, GasExperimentHarness {
    uint256 internal constant CALL_LIMIT = 1;
    uint256 internal constant USER_AMOUNT = 100e18;

    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    X1CompactOrderDelegationManager internal x1Manager;
    DeleGatorCore internal x1Delegator;
    BasicERC20 internal token;

    TestUser internal x1User;

    address internal relayer;
    address internal recipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        x1Manager = new X1CompactOrderDelegationManager(makeAddr("x1-owner"));
        EIP7702StatelessDeleGator x1DeleGatorImpl_ =
            new EIP7702StatelessDeleGator(IDelegationManager(address(x1Manager)), entryPoint);
        x1User = createUser("X1Alice");
        vm.etch(x1User.addr, bytes.concat(hex"ef0100", abi.encodePacked(x1DeleGatorImpl_)));
        x1Delegator = DeleGatorCore(payable(x1User.addr));

        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);
        token.mint(address(x1Delegator), 1_000_000e18);

        relayer = makeAddr("x1-relayer");
        recipient = makeAddr("x1-recipient");
    }

    function test_x1_codec_roundtrip() public {
        Delegation memory signed_ = _buildSignedDelegation(delegationManager, users.alice, address(users.alice.deleGator));
        bytes memory compact_ = CompactOrderCodec.encodeSingleDelegation(signed_);
        Delegation memory decoded_ = CompactOrderCodec.decodeSingleDelegation(compact_);

        assertEq(decoded_.delegate, signed_.delegate);
        assertEq(decoded_.delegator, signed_.delegator);
        assertEq(decoded_.authority, signed_.authority);
        assertEq(decoded_.salt, signed_.salt);
        assertEq(decoded_.caveats.length, signed_.caveats.length);
        assertEq(decoded_.caveats[0].enforcer, signed_.caveats[0].enforcer);
        assertEq(keccak256(decoded_.caveats[0].terms), keccak256(signed_.caveats[0].terms));
        assertEq(keccak256(decoded_.signature), keccak256(signed_.signature));
    }

    function test_x1_benchmark_standardVsCompact() public {
        Execution[] memory executions_ = _oneExecution();
        Delegation memory signedCanonical_ = _buildSignedDelegation(delegationManager, users.alice, address(users.alice.deleGator));
        Delegation memory signedX1_ = _signForManager(x1Manager, x1User, _unsignedDelegation(executions_, address(x1Delegator)));

        bytes memory standardCd_ = _encodeStandardRedeem(delegationManager, signedCanonical_, executions_);
        bytes memory compactCd_ = _encodeCompactRedeem(x1Manager, signedX1_, executions_);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory standard_ = measureManagerCall(address(delegationManager), relayer, standardCd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(delegationManager), relayer, standardCd_);

        snap_ = saveGasSnapshot();
        GasMeasurement memory compact_ = measureManagerCall(address(x1Manager), relayer, compactCd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(x1Manager), relayer, compactCd_);

        logGasReport("X1 | canonical | standard Delegation[] ABI", standard_);
        logGasReport("X1 | compact   | fixed-schema permission context", compact_);

        assertLt(compact_.calldataBytes, standard_.calldataBytes, "compact calldata should be smaller");
        assertLt(compact_.calldataGas, standard_.calldataGas, "compact calldata gas should be lower");
    }

    function _encodeStandardRedeem(
        IDelegationManager _manager,
        Delegation memory _signed,
        Execution[] memory _executions
    )
        internal
        view
        returns (bytes memory)
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signed;
        return encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(_executions));
    }

    function _encodeCompactRedeem(
        X1CompactOrderDelegationManager _manager,
        Delegation memory _signed,
        Execution[] memory _executions
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = CompactOrderCodec.encodeSingleDelegation(_signed);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(_executions);
        return
            abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
    }

    function _buildSignedDelegation(
        IDelegationManager _manager,
        TestUser memory _user,
        address _delegator
    )
        internal
        view
        returns (Delegation memory)
    {
        return _signForManager(_manager, _user, _unsignedDelegation(_oneExecution(), _delegator));
    }

    function _unsignedDelegation(Execution[] memory _executions, address _delegator) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_executions)),
            args: hex""
        });

        return Delegation({
            delegate: relayer, delegator: _delegator, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
    }

    function _signForManager(
        IDelegationManager _manager,
        TestUser memory _user,
        Delegation memory _delegation
    )
        internal
        view
        returns (Delegation memory signed_)
    {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(_manager.getDomainHash(), delegationHash_);
        signed_ = Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: SigningUtilsLib.signHash_EOA(_user.privateKey, typedDataHash_)
        });
    }

    function _oneExecution() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });
    }
}
