// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { Caveat, Delegation } from "../../../src/utils/Types.sol";
import { SignedExecutionEnforcer } from "../../../src/experiments/oneshot/SignedExecutionEnforcer.sol";
import { SignedExecutionReceiptEnforcer } from "../../../src/experiments/oneshot/SignedExecutionReceiptEnforcer.sol";
import { ServiceInstructionTypes } from "../../../src/experiments/oneshot/ServiceInstructionTypes.sol";
import { ServiceInstructionLib } from "../../../src/experiments/oneshot/ServiceInstructionLib.sol";
import { LimitOrderSwapAdapter } from "../../../src/experiments/oneshot/LimitOrderSwapAdapter.sol";
import { MockSwapRouter } from "./MockSwapRouter.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { ModeCode } from "../../../src/utils/Types.sol";

/**
 * @notice O-attested-trust and O-attested-receipt integration tests.
 */
contract SignedExecutionEnforcerTest is BaseTest {
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
    uint256 internal constant NONCE = 42;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        trustEnforcer = new SignedExecutionEnforcer();
        receiptEnforcer = new SignedExecutionReceiptEnforcer();
        adapter = new LimitOrderSwapAdapter(delegationManager);
        router = new MockSwapRouter();
        adapter.setRouterAllowed(address(router), true);

        sellToken = new BasicERC20(address(this), "SELL", "SELL", 0);
        buyToken = new BasicERC20(address(this), "BUY", "BUY", 0);
        sellToken.mint(address(users.alice.deleGator), 1_000_000e18);
        buyToken.mint(address(this), 1_000_000e18);
        buyToken.mint(address(router), 1_000_000e18);

        relayer = makeAddr("attested-relayer");
        receiver = makeAddr("attested-receiver");
        (quoteSigner, quoteSignerKey) = makeAddrAndKey("quote-signer");

        vm.prank(address(users.alice.deleGator));
        sellToken.approve(address(adapter), type(uint256).max);
    }

    function test_trust_happyPath() public {
        _runAttestedRedemption(address(trustEnforcer), MIN_BUY, false);
        assertEq(buyToken.balanceOf(receiver), MIN_BUY);
    }

    function test_receipt_happyPath() public {
        _runAttestedRedemption(address(receiptEnforcer), MIN_BUY, false);
        assertEq(buyToken.balanceOf(receiver), MIN_BUY);
    }

    function test_revertWhen_expiredQuote() public {
        Delegation memory delegation_ = _signAttestedDelegation(address(trustEnforcer));
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, MIN_BUY, true);
        vm.expectRevert("SignedExecutionEnforcer:quote-expired");
        _redeem(delegation_, execution_, args_);
    }

    function test_revertWhen_wrongSigner() public {
        Delegation memory delegation_ = _signAttestedDelegation(address(trustEnforcer));
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, MIN_BUY, false);
        ServiceInstructionTypes.ServiceAttestation memory attestation_ =
            abi.decode(args_, (ServiceInstructionTypes.ServiceAttestation));
        attestation_.signature = _signInstruction(attestation_.instruction, users.bob.privateKey);
        args_ = abi.encode(attestation_);
        vm.expectRevert("SignedExecutionEnforcer:invalid-signer");
        _redeem(delegation_, execution_, args_);
    }

    function test_revertWhen_executionHashMismatch() public {
        Delegation memory delegation_ = _signAttestedDelegation(address(trustEnforcer));
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, MIN_BUY, false);
        execution_ = ExecutionLib.encodeSingle(address(adapter), 0, hex"deadbeef");
        vm.expectRevert("SignedExecutionEnforcer:execution-hash-mismatch");
        _redeem(delegation_, execution_, args_);
    }

    function test_revertWhen_replayNonce() public {
        Delegation memory delegation_ = _signAttestedDelegation(address(trustEnforcer));
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, MIN_BUY, false);
        _redeem(delegation_, execution_, args_);
        vm.expectRevert("SignedExecutionEnforcer:nonce-reused");
        _redeem(delegation_, execution_, args_);
    }

    function test_revertWhen_boundsViolation() public {
        Delegation memory delegation_ = _signAttestedDelegation(address(trustEnforcer));
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, MIN_BUY - 1, false);
        vm.expectRevert("SignedExecutionEnforcer:min-buy-violation");
        _redeem(delegation_, execution_, args_);
    }

    function test_receipt_revertWhen_balanceShortfall() public {
        Delegation memory delegation_ = _signAttestedDelegation(address(receiptEnforcer));
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, MIN_BUY, false);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        vm.prank(address(delegationManager));
        receiptEnforcer.beforeHook(
            delegation_.caveats[0].terms,
            args_,
            ModeLib.encodeSimpleSingle(),
            execution_,
            delegationHash_,
            delegation_.delegator,
            relayer
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("SignedExecutionReceiptEnforcer:insufficient-balance-increase");
        receiptEnforcer.afterHook(
            delegation_.caveats[0].terms,
            args_,
            ModeLib.encodeSimpleSingle(),
            execution_,
            delegationHash_,
            delegation_.delegator,
            relayer
        );
    }

    function _runAttestedRedemption(address _enforcer, uint256 _minBuy, bool _expired) internal {
        Delegation memory delegation_ = _signAttestedDelegation(_enforcer);
        (bytes memory execution_, bytes memory args_) = _buildAttestedPayload(delegation_, _minBuy, _expired);
        _redeem(delegation_, execution_, args_);
    }

    function _signAttestedDelegation(address _enforcer) internal returns (Delegation memory) {
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

        Delegation memory delegation_ = Delegation({
            delegate: relayer,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 7,
            signature: hex""
        });
        return signDelegation(users.alice, delegation_);
    }

    function _buildAttestedPayload(
        Delegation memory _delegation,
        uint256 _minBuy,
        bool _expired
    )
        internal
        view
        returns (bytes memory executionCalldata_, bytes memory args_)
    {
        bytes memory routerCalldata_ = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, sellToken, buyToken, SELL_AMOUNT, _minBuy, receiver, address(0), hex""
        );
        bytes memory swapCall_ = abi.encodeWithSelector(
            LimitOrderSwapAdapter.swap.selector,
            sellToken,
            buyToken,
            SELL_AMOUNT,
            _minBuy,
            receiver,
            address(router),
            routerCalldata_
        );
        executionCalldata_ = ExecutionLib.encodeSingle(address(adapter), 0, swapCall_);

        uint256 issuedAt_ = block.timestamp;
        uint256 expiresAt_ = _expired ? block.timestamp : block.timestamp + 120;

        ServiceInstructionTypes.ServiceInstruction memory instruction_ = ServiceInstructionTypes.ServiceInstruction({
            delegationHash: EncoderLib._getDelegationHash(_delegation),
            maker: _delegation.delegator,
            chainId: block.chainid,
            manager: address(delegationManager),
            enforcer: _delegation.caveats[0].enforcer,
            mode: ModeLib.encodeSimpleSingle(),
            executionHash: keccak256(executionCalldata_),
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            sellAmount: SELL_AMOUNT,
            minBuyAmount: _minBuy,
            receiver: receiver,
            nonce: NONCE,
            issuedAt: issuedAt_,
            expiresAt: expiresAt_
        });

        bytes memory sig_ = _signInstruction(instruction_, quoteSignerKey);
        args_ = abi.encode(ServiceInstructionTypes.ServiceAttestation({ instruction: instruction_, signature: sig_ }));
    }

    function _signInstruction(
        ServiceInstructionTypes.ServiceInstruction memory _instruction,
        uint256 _privateKey
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash_ = ServiceInstructionLib.hashServiceInstruction(_instruction);
        bytes32 digest_ = MessageHashUtils.toTypedDataHash(ServiceInstructionLib.serviceDomainSeparator(quoteSigner), structHash_);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_privateKey, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _redeem(Delegation memory _delegation, bytes memory _executionCalldata, bytes memory _args) internal {
        _delegation.caveats[0].args = _args;
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory execDatas_ = new bytes[](1);
        execDatas_[0] = _executionCalldata;

        vm.prank(relayer);
        delegationManager.redeemDelegations(contexts_, modes_, execDatas_);
    }
}
