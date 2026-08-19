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
import { ExactExecutionBatchLimitedCallsProfileEnforcer } from "../../../src/experiments/enforcers/ExactExecutionBatchLimitedCallsProfileEnforcer.sol";
import { DelegationManagerC1 } from "../../../src/experiments/manager/DelegationManagerC1.sol";
import { DelegationManagerC2 } from "../../../src/experiments/manager/DelegationManagerC2.sol";
import { DelegationManagerC3 } from "../../../src/experiments/manager/DelegationManagerC3.sol";
import { DelegationManagerC4 } from "../../../src/experiments/manager/DelegationManagerC4.sol";
import { DelegationManagerC5 } from "../../../src/experiments/manager/DelegationManagerC5.sol";
import { EIP7702StatelessDeleGator } from "../../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { DeleGatorCore } from "../../../src/DeleGatorCore.sol";

import { GasExperimentHarness } from "./GasExperimentHarness.sol";

/**
 * @notice C0–C5 compatible ablation gas matrix vs canonical manager.
 * @dev Run: `forge test --isolate -vv --match-contract CompatibleAblationGasBenchmark`
 */
contract CompatibleAblationGasBenchmark is BaseTest, GasExperimentHarness {
    uint256 internal constant CALL_LIMIT = 1;
    uint256 internal constant USER_AMOUNT = 100e18;

    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    ExactExecutionBatchLimitedCallsProfileEnforcer internal profileEnforcer;
    BasicERC20 internal token;

    DelegationManagerC1 internal c1;
    DelegationManagerC2 internal c2;
    DelegationManagerC3 internal c3;
    DelegationManagerC4 internal c4;
    DelegationManagerC5 internal c5;

    TestUser internal c1User;
    TestUser internal c2User;
    TestUser internal c3User;
    TestUser internal c4User;
    TestUser internal c5User;

    address internal relayer;
    address internal recipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        profileEnforcer = new ExactExecutionBatchLimitedCallsProfileEnforcer();
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);

        c1 = new DelegationManagerC1(makeAddr("c1-bench-owner"));
        c2 = new DelegationManagerC2(makeAddr("c2-bench-owner"));
        c3 = new DelegationManagerC3(makeAddr("c3-bench-owner"));
        c4 = new DelegationManagerC4(makeAddr("c4-bench-owner"));
        c5 = new DelegationManagerC5(makeAddr("c5-bench-owner"));

        c1User = _etchVariantUser("C1BenchAlice", c1);
        c2User = _etchVariantUser("C2BenchAlice", c2);
        c3User = _etchVariantUser("C3BenchAlice", c3);
        c4User = _etchVariantUser("C4BenchAlice", c4);
        c5User = _etchVariantUser("C5BenchAlice", c5);

        token.mint(address(c1User.deleGator), 1_000_000e18);
        token.mint(address(c2User.deleGator), 1_000_000e18);
        token.mint(address(c3User.deleGator), 1_000_000e18);
        token.mint(address(c4User.deleGator), 1_000_000e18);
        token.mint(address(c5User.deleGator), 1_000_000e18);

        relayer = makeAddr("ablation-bench-relayer");
        recipient = makeAddr("ablation-bench-recipient");
    }

    function test_bench_C0_canonical_baseline() public {
        _benchManager("C0 | canonical baseline", delegationManager, users.alice, address(users.alice.deleGator), false);
    }

    function test_bench_C1_domainHoist() public {
        _benchManager("C1 | hoisted domain separator", c1, c1User, address(c1User.deleGator), false);
    }

    function test_bench_C2_cachedLengths() public {
        _benchManager("C2 | cached lengths + unchecked loops", c2, c2User, address(c2User.deleGator), false);
    }

    function test_bench_C3_singleRedemptionFastPath() public {
        _benchManager("C3 | single-redemption fast path", c3, c3User, address(c3User.deleGator), false);
    }

    function test_bench_C4_fusedValidation() public {
        _benchManager("C4 | fused validation loop", c4, c4User, address(c4User.deleGator), false);
    }

    function test_bench_C5_leanEvents() public {
        _benchManager("C5 | lean redemption events", c5, c5User, address(c5User.deleGator), false);
    }

    function test_bench_profileEnforcer_vs_combinedEnforcer() public {
        _benchManager("enforcer | profile (mode+validity)", delegationManager, users.alice, address(users.alice.deleGator), true);
        _benchManager("enforcer | combined (baseline)", delegationManager, users.alice, address(users.alice.deleGator), false);
    }

    function _benchManager(
        string memory _label,
        IDelegationManager _manager,
        TestUser memory _user,
        address _delegator,
        bool _useProfileEnforcer
    )
        internal
    {
        Execution[] memory executions_ = _oneExecution();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory signed_ = _signForManager(_manager, _user, _unsignedDelegation(executions_, _delegator, _useProfileEnforcer));

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = signed_;
        bytes memory cd_ = encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), execData_);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory m_ = measureManagerCall(address(_manager), relayer, cd_);
        logGasReport(_label, m_);
        restoreGasSnapshot(snap_);

        measureManagerCall(address(_manager), relayer, cd_);
    }

    function _unsignedDelegation(Execution[] memory _executions, address _delegator, bool _useProfileEnforcer)
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        if (_useProfileEnforcer) {
            ModeCode mode_ = ModeLib.encodeSimpleBatch();
            caveats_[0] = Caveat({
                enforcer: address(profileEnforcer),
                terms: abi.encodePacked(
                    CALL_LIMIT,
                    uint128(0),
                    uint128(type(uint128).max),
                    ModeCode.unwrap(mode_),
                    ExecutionLib.encodeBatch(_executions)
                ),
                args: hex""
            });
        } else {
            caveats_[0] = Caveat({
                enforcer: address(combinedEnforcer),
                terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_executions)),
                args: hex""
            });
        }

        return Delegation({
            delegate: relayer,
            delegator: _delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
    }

    function _signForManager(IDelegationManager _manager, TestUser memory _user, Delegation memory _delegation)
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

    function _etchVariantUser(string memory _name, IDelegationManager _manager) internal returns (TestUser memory user_) {
        user_ = createUser(_name);
        EIP7702StatelessDeleGator impl_ = new EIP7702StatelessDeleGator(_manager, entryPoint);
        vm.etch(user_.addr, bytes.concat(hex"ef0100", abi.encodePacked(address(impl_))));
        user_.deleGator = DeleGatorCore(payable(user_.addr));
    }

    function _oneExecution() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });
    }
}
