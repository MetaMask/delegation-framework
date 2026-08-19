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
import { X3ActivationCacheDelegationManager } from "../../../src/experiments/X3/X3ActivationCacheDelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { DeleGatorCore } from "../../../src/DeleGatorCore.sol";

import { GasExperimentHarness } from "./GasExperimentHarness.sol";

/**
 * @notice X3 first-fill signature activation cache with epoch invalidation.
 * @dev Run: `forge test --isolate -vv --match-contract X3ActivationCacheBenchmark`
 */
contract X3ActivationCacheBenchmark is BaseTest, GasExperimentHarness {
    uint256 internal constant CALL_LIMIT = 10;
    uint256 internal constant USER_AMOUNT = 100e18;

    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    X3ActivationCacheDelegationManager internal x3Manager;
    DeleGatorCore internal x3Delegator;
    BasicERC20 internal token;

    TestUser internal x3User;

    address internal relayer;
    address internal recipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        x3Manager = new X3ActivationCacheDelegationManager(makeAddr("x3-owner"));
        EIP7702StatelessDeleGator x3DeleGatorImpl_ =
            new EIP7702StatelessDeleGator(IDelegationManager(address(x3Manager)), entryPoint);
        x3User = createUser("X3Alice");
        vm.etch(x3User.addr, bytes.concat(hex"ef0100", abi.encodePacked(x3DeleGatorImpl_)));
        x3Delegator = DeleGatorCore(payable(x3User.addr));

        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);
        token.mint(address(x3Delegator), 1_000_000e18);

        relayer = makeAddr("x3-relayer");
        recipient = makeAddr("x3-recipient");
    }

    function test_x3_activationCache_warmSecondFill() public {
        bytes memory cd_ = _buildX3RedeemCalldata();

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory first_ = measureManagerCall(address(x3Manager), relayer, cd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(x3Manager), relayer, cd_);

        snap_ = saveGasSnapshot();
        GasMeasurement memory second_ = measureManagerCall(address(x3Manager), relayer, cd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(x3Manager), relayer, cd_);

        logGasReport("X3 | first fill  | signature validated + cache write", first_);
        logGasReport("X3 | second fill | activation cache hit", second_);

        assertLt(second_.executionGas, first_.executionGas, "cached fill should cost less execution gas");
    }

    function test_x3_epochInvalidation_clearsActivationCache() public {
        Delegation memory delegation_ = _unsignedDelegation(address(x3Delegator));
        delegation_.salt = 1;
        Delegation memory signed_ = _signForManager(x3Manager, x3User, delegation_);
        bytes32 hash_ = EncoderLib._getDelegationHash(signed_);
        bytes32 keyBefore_ = x3Manager.activationKey(signed_.delegator, hash_);

        bytes[] memory contexts_ = new bytes[](1);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = signed_;
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = _modes();
        bytes[] memory execDatas_ = _execDatas();

        vm.prank(relayer);
        x3Manager.redeemDelegations(contexts_, modes_, execDatas_);
        assertTrue(x3Manager.activationCache(keyBefore_));

        vm.prank(x3User.addr);
        x3Manager.disableDelegation(signed_);

        bytes32 keyAfter_ = x3Manager.activationKey(signed_.delegator, hash_);
        assertTrue(keyAfter_ != keyBefore_);
    }

    function test_x3_benchmark_canonicalFirstFillVsCached() public {
        Delegation memory canonicalSigned_ = signDelegation(users.alice, _unsignedDelegation(address(users.alice.deleGator)));
        bytes memory canonicalCd_ = _encodeRedeemFor(canonicalSigned_);

        Delegation memory x3Signed_ = _signForManager(x3Manager, x3User, _unsignedDelegation(address(x3Delegator)));
        bytes memory x3Cd_ = _encodeRedeemFor(x3Signed_);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory canonical_ = measureManagerCall(address(delegationManager), relayer, canonicalCd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(delegationManager), relayer, canonicalCd_);

        snap_ = saveGasSnapshot();
        measureManagerCall(address(x3Manager), relayer, x3Cd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(x3Manager), relayer, x3Cd_);

        snap_ = saveGasSnapshot();
        GasMeasurement memory cached_ = measureManagerCall(address(x3Manager), relayer, x3Cd_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(x3Manager), relayer, x3Cd_);

        logGasReport("X3 | control     | canonical manager (every fill validates sig)", canonical_);
        logGasReport("X3 | warm cache  | X3 manager second fill", cached_);
    }

    function _buildX3RedeemCalldata() internal view returns (bytes memory) {
        Delegation memory signed_ = _signForManager(x3Manager, x3User, _unsignedDelegation(address(x3Delegator)));
        return _encodeRedeemFor(signed_);
    }

    function _encodeRedeemFor(Delegation memory _signed) internal view returns (bytes memory) {
        Execution[] memory executions_ = _oneExecution();
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signed;
        return encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions_));
    }

    function _unsignedDelegation(address _delegator) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_oneExecution())),
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

    function _contexts(bytes memory _cd) internal pure returns (bytes[] memory) {
        bytes memory body_ = new bytes(_cd.length - 4);
        for (uint256 i_; i_ < body_.length; ++i_) {
            body_[i_] = _cd[i_ + 4];
        }
        (, bytes[] memory contexts_,,) = abi.decode(body_, (bytes4, bytes[], ModeCode[], bytes[]));
        return contexts_;
    }

    function _modes() internal pure returns (ModeCode[] memory modes_) {
        modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
    }

    function _execDatas() internal view returns (bytes[] memory datas_) {
        datas_ = new bytes[](1);
        datas_[0] = ExecutionLib.encodeBatch(_oneExecution());
    }
}
