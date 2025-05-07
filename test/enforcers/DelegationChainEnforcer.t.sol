// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Delegation, Caveat, Execution } from "../../src/utils/Types.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { MultiSigDeleGator } from "../../src/MultiSigDeleGator.sol";
import { DelegationChainEnforcer } from "../../src/enforcers/DelegationChainEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract DelegationChainEnforcerTest is BaseTest {
    ////////////////////////////// Setup //////////////////////////////

    TestUser public chainIntegrity;
    TestUser public treasury;
    // Intermediary Chain Account
    TestUser public ICA;

    MultiSigDeleGator public aliceDeleGator;
    MultiSigDeleGator public bobDeleGator;
    DelegationChainEnforcer public delegationChainEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    address[] public delegators;

    // Prize levels for the delegation chain rewards
    uint256[] public prizeLevels;
    BasicERC20 public token;
    bytes32 public firstReferralDelegationHash;

    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public virtual override {
        super.setUp();

        chainIntegrity = createUser("ChainIntegrity");
        treasury = createUser("Treasury");
        ICA = createUser("Intermediary Chain Account");
        aliceDeleGator = MultiSigDeleGator(payable(users.alice.deleGator));
        bobDeleGator = MultiSigDeleGator(payable(users.bob.deleGator));

        // Set up prize levels
        prizeLevels.push(10 ether);
        prizeLevels.push(10 ether);
        prizeLevels.push(2.5 ether);
        prizeLevels.push(1.5 ether);
        prizeLevels.push(1 ether);

        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        delegationChainEnforcer = new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManager)),
            address(argsEqualityCheckEnforcer),
            prizeLevels
        );

        token = new BasicERC20(address(this), "USDC", "USDC", 18);
        token.mint(address(treasury.deleGator), 100 ether);
    }

    // Should create a delegation chain from chainIntegrity -> alice -> ICA -> bob -> ICA
    function test_chainIntegrityCanDelegateToAliceToICAToBoB() public {
        // Create delegation from chainIntegrity to alice
        Delegation memory chainToAlice_ = Delegation({
            delegate: address(users.alice.deleGator),
            delegator: address(chainIntegrity.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: _getChainIntegrityCaveats(),
            salt: 0,
            signature: hex""
        });
        chainToAlice_ = signDelegation(chainIntegrity, chainToAlice_);

        // Create delegation from alice to ICA
        Delegation memory aliceToICA_ = Delegation({
            delegate: address(ICA.deleGator),
            delegator: address(users.alice.deleGator),
            authority: EncoderLib._getDelegationHash(chainToAlice_),
            caveats: _getPositionCaveats(0),
            salt: 0,
            signature: hex""
        });
        aliceToICA_ = signDelegation(users.alice, aliceToICA_);
        firstReferralDelegationHash = EncoderLib._getDelegationHash(aliceToICA_);

        // Create delegation from ICA to bob
        Delegation memory ICAToBob_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(ICA.deleGator),
            authority: firstReferralDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        ICAToBob_ = signDelegation(ICA, ICAToBob_);

        // Create delegation from bob back to ICA
        Delegation memory bobToICA_ = Delegation({
            delegate: address(ICA.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(ICAToBob_),
            caveats: _getPositionCaveats(1),
            salt: 0,
            signature: hex""
        });
        bobToICA_ = signDelegation(users.bob, bobToICA_);

        delegators.push(address(users.alice.deleGator));
        delegators.push(address(users.bob.deleGator));

        // Adding the redemption args only to the alice delegation
        aliceToICA_.caveats[0].args = _getRedemptionArgs();

        // Build delegation chain
        Delegation[] memory delegations_ = new Delegation[](4);
        delegations_[0] = bobToICA_;
        delegations_[1] = ICAToBob_;
        delegations_[2] = aliceToICA_;
        delegations_[3] = chainToAlice_;

        uint256[] memory balancesBefore_ = _getBalances(delegators);

        // Execute the delegation chain through ICA
        invokeDelegation_UserOp(ICA, delegations_, _getExecution());

        _validatePayments(balancesBefore_);
    }

    // The args contain a delegation chain for each of the delegators/prize levels, and the token to redeem the payments.
    function _getRedemptionArgs() internal view returns (bytes memory encoded_) {
        // Create delegation from treasury with caveats
        // Args enforcer at index 0
        // Includes the first referral delegation hash and the ICA address, because the first delegation with the delegation chain
        // enforcer is the one that redeems the payments after that the others skip it.
        // The args enforcer needs the redeemer, the delegation hash alone is not enough.

        Delegation[][] memory delegations_ = new Delegation[][](delegators.length);
        for (uint256 i = 0; i < delegators.length; i++) {
            delegations_[i] = new Delegation[](1);

            Caveat[] memory caveats_ = new Caveat[](2);

            caveats_[0] = Caveat({
                args: hex"",
                enforcer: address(argsEqualityCheckEnforcer),
                terms: abi.encodePacked(firstReferralDelegationHash, address(address(ICA.deleGator)))
            });

            caveats_[1] = Caveat({
                args: hex"",
                enforcer: address(erc20TransferAmountEnforcer),
                terms: abi.encodePacked(address(token), prizeLevels[i])
            });

            delegations_[i][0] = Delegation({
                delegate: address(delegationChainEnforcer),
                delegator: address(treasury.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: i,
                signature: hex""
            });

            delegations_[i][0] = signDelegation(treasury, delegations_[i][0]);
        }
        encoded_ = abi.encode(delegations_, token);
    }

    function _getBalances(address[] memory _recipients) internal view returns (uint256[] memory balances_) {
        uint256 recipientsLength_ = _recipients.length;
        balances_ = new uint256[](recipientsLength_);
        for (uint256 i = 0; i < recipientsLength_; ++i) {
            balances_[i] = IERC20(token).balanceOf(_recipients[i]);
        }
    }

    function _validatePayments(uint256[] memory balanceBefore_) internal {
        uint256[] memory balances_ = _getBalances(delegators);
        for (uint256 i = 0; i < delegators.length; i++) {
            assertEq(balances_[i], balanceBefore_[i] + prizeLevels[i], "The balance after is insufficient");
        }
    }

    function _getExecution() internal view returns (Execution memory execution_) {
        execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators))
        });
    }

    function _getPositionCaveats(uint256 _position) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(delegationChainEnforcer), terms: abi.encodePacked(uint256(_position)) });
    }

    function _getChainIntegrityCaveats() internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](3);
        // Check target is the enforcer
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(delegationChainEnforcer))
        });
        // Check value is 0
        caveats_[1] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encodePacked(uint256(0)) });
        // Check method is post()
        caveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: abi.encodePacked(DelegationChainEnforcer.post.selector)
        });
    }
}
