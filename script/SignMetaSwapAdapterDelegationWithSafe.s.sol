// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Delegation, Caveat, Execution, ModeCode } from "../src/utils/Types.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeDelegationSigner } from "./helpers/SafeDelegationSigner.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";

/**
 * @title SignMetaSwapAdapterDelegationWithSafe
 * @notice Signs a Linea delegation from the Gator Safe module to DelegationMetaSwapAdapter with **only**
 *         RedeemerEnforcer (no period / target / calldata caveats). Matches the v2 adapter model: a single
 *         chain where `delegate` is the adapter and redeemer terms allow only that contract to redeem.
 * @dev Default deployed adapter on Linea: 0xbb56322416A4E3C1f64Eb4ace298Cce9FD376D35 (override via env).
 * @dev Required env (e.g. from `.env` if your shell/IDE exports it into the `forge` process):
 *      SAFE_ADDRESS, GATOR_SAFE_MODULE_ADDRESS, DELEGATION_MANAGER_ADDRESS,
 *      SIGNER1_PRIVATE_KEY, SIGNER2_PRIVATE_KEY, SIGNER3_PRIVATE_KEY, REDEEMER_ENFORCER_ADDRESS.
 * @dev Optional: DELEGATION_METASWAP_ADAPTER_ADDRESS, DELEGATION_SALT, EXAMPLE_TOKEN_FROM,
 *      EXAMPLE_AMOUNT_FROM (for logged sample execution only).
 * @dev `vm.env*` only sees variables in the environment of the `forge` process. That often matches
 *      `.env` when direnv, an IDE task, or another wrapper exports those keys; it is separate from
 *      foundry.toml `${VAR}` substitution. If a key is missing, export that key (or the subset this script needs).
 * @dev Run (example):
 *      forge script script/SignMetaSwapAdapterDelegationWithSafe.s.sol:SignMetaSwapAdapterDelegationWithSafe \\
 *        --sig "run()" --rpc-url linea --broadcast
 */
contract SignMetaSwapAdapterDelegationWithSafe is Script {
    using SafeDelegationSigner for SafeDelegationSigner.SignerConfig;

    address internal safeAddress;
    address internal gatorSafeModule;
    IDelegationManager internal delegationManager;
    uint256 internal signer1PrivateKey;
    uint256 internal signer2PrivateKey;
    uint256 internal signer3PrivateKey;
    address internal metaSwapAdapter;
    address internal redeemerEnforcer;

    function setUp() public {
        safeAddress = vm.envAddress("SAFE_ADDRESS");
        gatorSafeModule = vm.envAddress("GATOR_SAFE_MODULE_ADDRESS");
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        signer1PrivateKey = vm.envUint("SIGNER1_PRIVATE_KEY");
        signer2PrivateKey = vm.envUint("SIGNER2_PRIVATE_KEY");
        signer3PrivateKey = vm.envUint("SIGNER3_PRIVATE_KEY");
        redeemerEnforcer = vm.envAddress("REDEEMER_ENFORCER_ADDRESS");
        metaSwapAdapter = vm.envAddress("DELEGATION_METASWAP_ADAPTER_ADDRESS");

        console2.log("Chain ID: %s", block.chainid);
        console2.log("Safe: %s", safeAddress);
        console2.log("Gator module (delegator): %s", gatorSafeModule);
        console2.log("MetaSwap adapter (delegate + redeemer): %s", metaSwapAdapter);
        console2.log("RedeemerEnforcer: %s", redeemerEnforcer);
    }

    function run() public view {
        Delegation memory delegation = _createDelegation();
        SafeDelegationSigner.SignedDelegationResult memory signed = _signDelegation(delegation);

        console2.log("");
        console2.log("=== Signed delegation (adapter-bound, RedeemerEnforcer only) ===");
        console2.log("Delegation hash:");
        console2.logBytes32(EncoderLib._getDelegationHash(signed.delegation));

        _logSwapByDelegationContext(signed.delegation);

        Execution memory exampleExec = _examplePullFundsExecution();
        _logRedeemDelegationsSample(signed.delegation, exampleExec);
    }

    function _createDelegation() internal view returns (Delegation memory delegation) {
        // Only the adapter may redeem; same address as `delegate` per DelegationMetaSwapAdapter v2 usage.
        bytes memory redeemerTerms = abi.encodePacked(metaSwapAdapter);

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: redeemerEnforcer, terms: redeemerTerms, args: hex"" });

        uint256 salt = vm.envOr("DELEGATION_SALT", uint256(0));

        delegation = Delegation({
            delegate: metaSwapAdapter,
            delegator: gatorSafeModule,
            authority: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            caveats: caveats,
            salt: salt,
            signature: hex""
        });
    }

    function _signDelegation(Delegation memory _delegation)
        internal
        view
        returns (SafeDelegationSigner.SignedDelegationResult memory result)
    {
        uint256[] memory signerPrivateKeys = new uint256[](3);
        signerPrivateKeys[0] = signer1PrivateKey;
        signerPrivateKeys[1] = signer2PrivateKey;
        signerPrivateKeys[2] = signer3PrivateKey;
        address[] memory signerAddresses = new address[](3);
        signerAddresses[0] = vm.addr(signer1PrivateKey);
        signerAddresses[1] = vm.addr(signer2PrivateKey);
        signerAddresses[2] = vm.addr(signer3PrivateKey);

        SafeDelegationSigner.SignerConfig memory config = SafeDelegationSigner.SignerConfig({
            safeAddress: safeAddress,
            gatorSafeModule: gatorSafeModule,
            delegationManager: delegationManager,
            signerPrivateKeys: signerPrivateKeys,
            signerAddresses: signerAddresses
        });
        result = SafeDelegationSigner.signDelegationWithSafe(_delegation, config);
    }

    /// @dev Single delegation; `swapByDelegation` expects leaf-to-root array `[delegation]`.
    function _logSwapByDelegationContext(Delegation memory _signedDelegation) internal pure {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = _signedDelegation;

        console2.log("");
        console2.log("=== swapByDelegation: permission context (abi.encode(Delegation[])) ===");
        console2.logBytes(abi.encode(delegations));
    }

    /// @dev Mirrors adapter-internal redemption: ERC20 transfer to adapter, or native send to adapter.
    function _examplePullFundsExecution() internal view returns (Execution memory execution) {
        address tokenFrom = vm.envOr("EXAMPLE_TOKEN_FROM", address(0));
        uint256 amountFrom = vm.envOr("EXAMPLE_AMOUNT_FROM", uint256(0));

        if (tokenFrom == address(0)) {
            execution = Execution({ target: metaSwapAdapter, value: amountFrom, callData: hex"" });
        } else {
            bytes memory transferData = abi.encodeCall(IERC20.transfer, (metaSwapAdapter, amountFrom));
            execution = Execution({ target: tokenFrom, value: 0, callData: transferData });
        }
    }

    function _logRedeemDelegationsSample(Delegation memory _signedDelegation, Execution memory _execution) internal pure {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = _signedDelegation;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData);

        console2.log("");
        console2.log("=== Sample redeemDelegations inputs (EXAMPLE_* env only; not enforced by caveats) ===");
        console2.log("Permission context:");
        console2.logBytes(permissionContexts[0]);
        console2.log("Mode:");
        console2.logBytes32(ModeCode.unwrap(modes[0]));
        console2.log("Execution call data:");
        console2.logBytes(executionCallDatas[0]);
    }
}
