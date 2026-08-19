// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { console } from "forge-std/console.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { ExactExecutionBatchLimitedCallsEnforcer } from "../../../src/enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";
import { TimestampEnforcer } from "../../../src/enforcers/TimestampEnforcer.sol";
import { OneShotExactLimitOrderLib } from "../../../src/experiments/oneshot/OneShotExactLimitOrderLib.sol";
import { SignedExecutionEnforcer } from "../../../src/experiments/oneshot/SignedExecutionEnforcer.sol";
import { SignedExecutionReceiptEnforcer } from "../../../src/experiments/oneshot/SignedExecutionReceiptEnforcer.sol";
import { ServiceInstructionTypes } from "../../../src/experiments/oneshot/ServiceInstructionTypes.sol";
import { ServiceInstructionLib } from "../../../src/experiments/oneshot/ServiceInstructionLib.sol";
import { LimitOrderSwapAdapter } from "../../../src/experiments/oneshot/LimitOrderSwapAdapter.sol";
import { MockSwapRouter } from "../oneshot/MockSwapRouter.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { GasExperimentHarness } from "../gas/GasExperimentHarness.sol";

/**
 * @notice Gas benchmarks for O* one-shot variants vs O-exact baseline.
 * @dev Run: `forge test --isolate -vv --match-contract OneShotGasBenchmark`
 */
contract OneShotGasBenchmark is BaseTest, GasExperimentHarness {
    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    TimestampEnforcer internal timestampEnforcer;
    SignedExecutionEnforcer internal trustEnforcer;
    SignedExecutionReceiptEnforcer internal receiptEnforcer;
    LimitOrderSwapAdapter internal adapter;
    MockSwapRouter internal router;

    BasicERC20 internal sellToken;
    BasicERC20 internal buyToken;

    address internal relayer;
    address internal receiver;
    address internal quoteSigner;
    uint256 internal quoteSignerKey;

    uint256 internal constant SELL_AMOUNT = 100e18;
    uint256 internal constant MIN_BUY = 95e18;
    uint256 internal constant NONCE = 1;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        trustEnforcer = new SignedExecutionEnforcer();
        receiptEnforcer = new SignedExecutionReceiptEnforcer();
        adapter = new LimitOrderSwapAdapter(delegationManager);
        router = new MockSwapRouter();
        adapter.setRouterAllowed(address(router), true);

        sellToken = new BasicERC20(address(this), "SELL", "SELL", 0);
        buyToken = new BasicERC20(address(this), "BUY", "BUY", 0);
        sellToken.mint(address(users.alice.deleGator), 1_000_000e18);
        buyToken.mint(address(router), 1_000_000e18);

        relayer = makeAddr("gas-relayer");
        receiver = makeAddr("gas-receiver");
        (quoteSigner, quoteSignerKey) = makeAddrAndKey("gas-quote-signer");
    }

    function test_gas_O_exact_baseline() public {
        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory m_ = _benchExact();
        logGasReport("O-exact | combined+timestamp | one-shot", m_);
        restoreGasSnapshot(snap_);
        _benchExact();
    }

    function test_gas_O_attested_trust() public {
        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory m_ = _benchAttested(address(trustEnforcer));
        logGasReport("O-attested-trust | service instruction", m_);
        restoreGasSnapshot(snap_);
        _benchAttested(address(trustEnforcer));
    }

    function test_gas_O_attested_receipt() public {
        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory m_ = _benchAttested(address(receiptEnforcer));
        logGasReport("O-attested-receipt | service + balance check", m_);
        restoreGasSnapshot(snap_);
        _benchAttested(address(receiptEnforcer));
    }

    function _benchExact() internal returns (GasMeasurement memory) {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(sellToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(this), SELL_AMOUNT)
        });
        executions_[1] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(this.settleExact.selector, receiver, SELL_AMOUNT, MIN_BUY)
        });

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: OneShotExactLimitOrderLib.encodeCombinedEnforcerTerms(executions_),
            args: hex""
        });
        caveats_[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms: OneShotExactLimitOrderLib.encodeTimestampTerms(uint128(block.timestamp - 1), uint128(block.timestamp + 1 days)),
            args: hex""
        });

        Delegation memory delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: relayer,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 99,
                signature: hex""
            })
        );

        buyToken.mint(address(this), MIN_BUY);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes memory cd_ = encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions_));
        return measureManagerCall(address(delegationManager), relayer, cd_);
    }

    function _benchAttested(address _enforcer) internal returns (GasMeasurement memory) {
        ServiceInstructionTypes.MakerBounds memory bounds_ = ServiceInstructionTypes.MakerBounds({
            quoteSigner: quoteSigner,
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            receiver: receiver,
            adapter: address(adapter),
            maxSellAmount: SELL_AMOUNT,
            minBuyAmount: MIN_BUY,
            maxQuoteLifetime: 300
        });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: _enforcer, terms: ServiceInstructionLib.encodeMakerBoundsTerms(bounds_), args: hex"" });

        Delegation memory delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: relayer,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 100,
                signature: hex""
            })
        );

        bytes memory routerCalldata_ = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, sellToken, buyToken, SELL_AMOUNT, MIN_BUY, receiver, address(0), hex""
        );
        bytes memory swapCall_ = abi.encodeWithSelector(
            LimitOrderSwapAdapter.swap.selector,
            sellToken,
            buyToken,
            SELL_AMOUNT,
            MIN_BUY,
            receiver,
            address(router),
            routerCalldata_
        );
        bytes memory executionCalldata_ = ExecutionLib.encodeSingle(address(adapter), 0, swapCall_);

        ServiceInstructionTypes.ServiceInstruction memory instruction_ = ServiceInstructionTypes.ServiceInstruction({
            delegationHash: EncoderLib._getDelegationHash(delegation_),
            maker: delegation_.delegator,
            chainId: block.chainid,
            manager: address(delegationManager),
            enforcer: _enforcer,
            mode: ModeLib.encodeSimpleSingle(),
            executionHash: keccak256(executionCalldata_),
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            sellAmount: SELL_AMOUNT,
            minBuyAmount: MIN_BUY,
            receiver: receiver,
            nonce: NONCE,
            issuedAt: block.timestamp,
            expiresAt: block.timestamp + 120
        });

        bytes32 structHash_ = ServiceInstructionLib.hashServiceInstruction(instruction_);
        bytes32 digest_ = MessageHashUtils.toTypedDataHash(ServiceInstructionLib.serviceDomainSeparator(quoteSigner), structHash_);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(quoteSignerKey, digest_);
        delegation_.caveats[0].args = abi.encode(
            ServiceInstructionTypes.ServiceAttestation({ instruction: instruction_, signature: abi.encodePacked(r_, s_, v_) })
        );

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes memory cd_ = encodeRedeemCall(delegations_, ModeLib.encodeSimpleSingle(), executionCalldata_);

        vm.prank(address(users.alice.deleGator));
        sellToken.approve(address(adapter), SELL_AMOUNT);

        return measureManagerCall(address(delegationManager), relayer, cd_);
    }

    function settleExact(address _receiver, uint256 _sellAmount, uint256 _buyAmount) external {
        sellToken.transferFrom(msg.sender, address(this), _sellAmount);
        buyToken.transfer(_receiver, _buyAmount);
    }
}
