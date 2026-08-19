// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Caveat, Delegation, Execution } from "../../../src/utils/Types.sol";
import { PersistentERC20HookCoordinator } from "../../../src/experiments/X2/PersistentERC20HookCoordinator.sol";

import { GasExperimentHarness } from "./GasExperimentHarness.sol";

/**
 * @notice X2 portable control benchmark (persistent storage).
 * @dev Run: `forge test --isolate -vv --match-contract X2PersistentHookBenchmark`
 */
contract X2PersistentHookBenchmark is BaseTest, GasExperimentHarness {
    uint256 internal constant USER_AMOUNT = 50e18;

    PersistentERC20HookCoordinator internal persistentCoordinator;
    BasicERC20 internal token;

    address internal relayer;
    address internal recipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        persistentCoordinator = new PersistentERC20HookCoordinator();
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);

        relayer = makeAddr("x2-relayer");
        recipient = makeAddr("x2-recipient");
    }

    function test_x2_persistentCoordinator_executes() public {
        bytes memory cd_ = _buildRedeemCalldata();
        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory m_ = measureManagerCall(address(delegationManager), relayer, cd_);
        logGasReport("X2 | persistent storage hook coordinator", m_);
        restoreGasSnapshot(snap_);
        measureManagerCall(address(delegationManager), relayer, cd_);
    }

    function _buildRedeemCalldata() internal returns (bytes memory) {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });

        bytes memory terms_ = abi.encodePacked(
            bytes1(0x01), bytes20(address(token)), bytes20(address(users.alice.deleGator)), bytes32(USER_AMOUNT)
        );

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(persistentCoordinator), terms: terms_, args: hex"" });

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
        return encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions_));
    }
}
