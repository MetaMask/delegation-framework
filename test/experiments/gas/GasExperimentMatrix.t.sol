// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Caveat, Delegation, Execution } from "../../../src/utils/Types.sol";
import { ExactExecutionBatchLimitedCallsEnforcer } from "../../../src/enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";

import { GasExperimentHarness } from "./GasExperimentHarness.sol";

/**
 * @notice Canonical-manager gas matrix entry points for experiment variants.
 * @dev Run: `forge test --isolate --match-contract GasExperimentMatrix -vv`
 */
contract GasExperimentMatrix is BaseTest, GasExperimentHarness {
    uint256 internal constant CALL_LIMIT = 1;
    uint256 internal constant USER_AMOUNT = 100e18;
    uint256 internal constant FEE_AMOUNT = 1e18;

    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    BasicERC20 internal token;

    address internal relayer;
    address internal recipient;
    address internal feeRecipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);

        relayer = makeAddr("matrix-relayer");
        recipient = makeAddr("matrix-recipient");
        feeRecipient = makeAddr("matrix-fee");
    }

    function test_matrix_canonical_oneExecution_combinedEnforcer() public {
        Execution[] memory executions_ = _oneExecution();
        _benchCanonical("matrix | canonical | 1-exec batch | combined enforcer", executions_);
    }

    function test_matrix_canonical_twoExecutions_combinedEnforcer() public {
        Execution[] memory executions_ = _twoExecutions();
        _benchCanonical("matrix | canonical | 2-exec batch | combined enforcer", executions_);
    }

    function _benchCanonical(string memory _label, Execution[] memory _executions) internal {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_executions)),
            args: hex""
        });

        Delegation memory delegation_ = Delegation({
            delegate: relayer,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes memory execData_ = ExecutionLib.encodeBatch(_executions);
        bytes memory cd_ = encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), execData_);

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory m_ = measureManagerCall(address(delegationManager), relayer, cd_);
        logGasReport(_label, m_);
        restoreGasSnapshot(snap_);

        measureManagerCall(address(delegationManager), relayer, cd_);
    }

    function _oneExecution() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });
    }

    function _twoExecutions() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });
        executions_[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, feeRecipient, FEE_AMOUNT)
        });
    }
}
