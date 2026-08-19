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
import { IDeleGatorCore } from "../../../src/interfaces/IDeleGatorCore.sol";
import { DelegationManager } from "../../../src/DelegationManager.sol";
import { SimpleDelegationManager } from "../../../src/SimpleDelegationManager.sol";
import { EIP7702MultiManagerDeleGator } from "../../../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { ExecuteFromExecutorWitnessEnforcer } from "./helpers/ExecuteFromExecutorWitnessEnforcer.sol";

/**
 * @notice Ensures manager variants forward identical `(mode, executionCalldata)` toward account execution.
 * @dev Witness enforcer records hook-visible args; `vm.expectCall` asserts the root delegator receives the same
 *      `executeFromExecutor` calldata. `SimpleDelegationManager` is the initial variant under test.
 */
contract ExecuteFromExecutorForwardingSpy is BaseTest {
    DelegationManager internal canonicalManager;
    SimpleDelegationManager internal simpleManager;
    EIP7702MultiManagerDeleGator internal multiManagerImpl;
    ExecuteFromExecutorWitnessEnforcer internal witnessEnforcer;
    BasicERC20 internal token;

    address internal relayer;
    address internal recipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        canonicalManager = delegationManager;
        simpleManager = new SimpleDelegationManager();
        multiManagerImpl = new EIP7702MultiManagerDeleGator();
        witnessEnforcer = new ExecuteFromExecutorWitnessEnforcer();
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(users.alice.addr, 1_000_000e18);

        _etchMultiManager(users.alice.addr);

        EIP7702MultiManagerDeleGator aliceAccount_ = EIP7702MultiManagerDeleGator(payable(users.alice.addr));
        vm.startPrank(users.alice.addr);
        aliceAccount_.approveDelegationManager(IDelegationManager(address(canonicalManager)));
        aliceAccount_.approveDelegationManager(IDelegationManager(address(simpleManager)));
        vm.stopPrank();

        relayer = makeAddr("forwarding-spy-relayer");
        recipient = makeAddr("forwarding-spy-recipient");
    }

    function test_forwardingSpy_canonicalMatchesSimple_singleBatch() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, 100e18)
        });

        ModeCode mode_ = ModeLib.encodeSimpleBatch();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);

        ForwardWitness memory canonical_ = _captureForward(IDelegationManager(address(canonicalManager)), mode_, execData_);
        uint256 snap_ = vm.snapshot();
        ForwardWitness memory simple_ = _captureForward(IDelegationManager(address(simpleManager)), mode_, execData_);
        vm.revertTo(snap_);

        assertEq(ModeCode.unwrap(canonical_.mode), ModeCode.unwrap(simple_.mode), "mode mismatch");
        assertEq(keccak256(canonical_.executionCalldata), keccak256(simple_.executionCalldata), "executionCalldata mismatch");
        assertEq(canonical_.witnessCount, simple_.witnessCount, "witness hook count mismatch");
    }

    struct ForwardWitness {
        ModeCode mode;
        bytes executionCalldata;
        uint256 witnessCount;
    }

    function _captureForward(IDelegationManager _manager, ModeCode _mode, bytes memory _execData)
        internal
        returns (ForwardWitness memory w_)
    {
        witnessEnforcer.resetWitness();

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(witnessEnforcer), terms: hex"", args: hex"" });

        Delegation memory unsigned_ = Delegation({
            delegate: relayer,
            delegator: users.alice.addr,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        Delegation memory signed_ = _signDelegationFor(_manager, users.alice, unsigned_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = signed_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = _execData;

        vm.expectCall(
            users.alice.addr,
            abi.encodeWithSelector(IDeleGatorCore.executeFromExecutor.selector, _mode, _execData)
        );

        vm.prank(relayer);
        _manager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        w_.mode = witnessEnforcer.witnessedMode();
        w_.executionCalldata = witnessEnforcer.witnessedExecutionCalldata();
        w_.witnessCount = witnessEnforcer.witnessCount();
    }

    function _signDelegationFor(
        IDelegationManager _manager,
        TestUser memory _signer,
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
            signature: SigningUtilsLib.signHash_EOA(_signer.privateKey, typedDataHash_)
        });
    }

    function _etchMultiManager(address _eoa) internal {
        vm.etch(_eoa, bytes.concat(hex"ef0100", abi.encodePacked(address(multiManagerImpl))));
    }
}
