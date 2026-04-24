// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { Delegation, Caveat, Execution, ModeCode } from "../src/utils/Types.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeDelegationSigner } from "./helpers/SafeDelegationSigner.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { SigningUtilsLib } from "../test/utils/SigningUtilsLib.t.sol";

/**
 * @title SignDelegationWithSafe
 * @notice Script to sign delegations using Safe multisig for different operation types
 * @dev This script supports:
 *   - ERC20 transfers with token and recipient restrictions
 *   - Token swaps via DelegationMetaSwapAdapter
 *   - Bridge operations (extensible)
 * @dev Fill the required variables in the .env file
 * @dev Run specific operations:
 *   - forge script script/SignDelegationWithSafe.s.sol:SignDelegationWithSafe --sig "runERC20Transfer()" --rpc-url <rpc>
 *   - forge script script/SignDelegationWithSafe.s.sol:SignDelegationWithSafe --sig "runSwap()" --rpc-url <rpc>
 *   - forge script script/SignDelegationWithSafe.s.sol:SignDelegationWithSafe --sig "runBridge()" --rpc-url <rpc>
 */
contract SignDelegationWithSafe is Script {
    using SafeDelegationSigner for SafeDelegationSigner.SignerConfig;

    address safeAddress;
    address gatorSafeModule;
    IDelegationManager delegationManager;
    address delegate;
    address delegationMetaSwapAdapter;
    uint256 signer1PrivateKey;
    uint256 signer2PrivateKey;
    uint256 signer3PrivateKey;
    uint256 automationPrivateKey;

    // Operation type enum
    enum OperationType {
        ERC20Transfer,
        Swap,
        Bridge
    }

    function setUp() public {
        safeAddress = vm.envAddress("SAFE_ADDRESS");
        gatorSafeModule = vm.envAddress("GATOR_SAFE_MODULE_ADDRESS");
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        delegate = vm.envAddress("DELEGATE_ADDRESS");
        signer1PrivateKey = vm.envUint("SIGNER1_PRIVATE_KEY");
        signer2PrivateKey = vm.envUint("SIGNER2_PRIVATE_KEY");
        signer3PrivateKey = vm.envUint("SIGNER3_PRIVATE_KEY");
        // Swap-specific (optional for transfer/bridge flows)
        delegationMetaSwapAdapter = vm.envOr("DELEGATION_METASWAP_ADAPTER_ADDRESS", address(0));
        automationPrivateKey = vm.envOr("AUTOMATION_PRIVATE_KEY", uint256(0));
        console2.log("~~~");
        console2.log("Safe Address: %s", safeAddress);
        console2.log("Gator Safe Module: %s", gatorSafeModule);
        console2.log("Delegation Manager: %s", address(delegationManager));
        console2.log("Delegate: %s", delegate);
        console2.log("Signer 1: %s", vm.addr(signer1PrivateKey));
        console2.log("Signer 2: %s", vm.addr(signer2PrivateKey));
        console2.log("Signer 3: %s", vm.addr(signer3PrivateKey));
        if (delegationMetaSwapAdapter != address(0)) {
            console2.log("Delegation MetaSwap Adapter: %s", delegationMetaSwapAdapter);
        }
        if (automationPrivateKey != 0) {
            console2.log("Automation (subVault signer): %s", vm.addr(automationPrivateKey));
        }
    }

    /// @notice Default run function - executes ERC20 transfer by default
    /// @dev Can be overridden by calling specific functions directly
    function run() public view {
        runERC20Transfer();
    }

    /// @notice Signs and prepares a delegation for ERC20 transfer
    /// @dev Restricts: token contract, transfer function, recipient address
    /// @dev Amount is flexible (not restricted)
    function runERC20Transfer() public view {
        console2.log("=== ERC20 Transfer Delegation ===");

        // Create delegation with ERC20 transfer enforcers
        Delegation memory delegation = _createERC20TransferDelegation();

        // Sign delegation
        SafeDelegationSigner.SignedDelegationResult memory result = _signDelegation(delegation);

        // Create ERC20 transfer execution
        Execution memory execution = _createERC20TransferExecution();

        // Prepare and log redemption inputs
        exampleRedeemDelegations(result.delegation, execution);
    }

    /// @notice Signs and prepares a delegation chain for token swap via DelegationMetaSwapAdapter
    /// @dev Delegation chain: gatorSafeModule (vault) -> delegate (subVault) -> adapter
    /// @dev Simple test delegation: only ArgsEqualityCheckEnforcer (whitelist NOT enforced)
    /// @dev SubVault (delegate) must call adapter.swapByDelegation(sigData, delegations, false)
    /// @dev Requires: DELEGATION_METASWAP_ADAPTER_ADDRESS, AUTOMATION_PRIVATE_KEY in .env
    function runSwap() public view {
        require(delegationMetaSwapAdapter != address(0), "runSwap: DELEGATION_METASWAP_ADAPTER_ADDRESS required");
        require(automationPrivateKey != 0, "runSwap: AUTOMATION_PRIVATE_KEY required");

        console2.log("=== Swap Delegation (DelegationMetaSwapAdapter style) ===");

        // 1. Create vault delegation: gatorSafeModule -> delegate (subVault)
        Delegation memory vaultDelegation = _createSwapVaultDelegation();

        // 2. Sign vault delegation with Safe
        SafeDelegationSigner.SignedDelegationResult memory vaultResult = _signDelegation(vaultDelegation);

        // 3. Create subVault delegation: delegate -> adapter (authority = hash of vault delegation)
        bytes32 vaultDelegationHash = EncoderLib._getDelegationHash(vaultResult.delegation);
        Delegation memory subVaultDelegation = _createSwapSubVaultDelegation(vaultDelegationHash);

        // 4. Sign subVault delegation with automation key
        Delegation memory signedSubVaultDelegation = _signSubVaultDelegation(subVaultDelegation);

        // 5. Prepare and log delegations for swapByDelegation (leaf to root order)
        exampleSwapByDelegation(vaultResult.delegation, signedSubVaultDelegation);
    }

    /// @notice Signs and prepares a delegation for bridge operation
    /// @dev Placeholder for bridge-specific enforcers and execution
    function runBridge() public view {
        console2.log("=== Bridge Delegation ===");

        // Create delegation with bridge enforcers
        Delegation memory delegation = _createBridgeDelegation();

        // Sign delegation
        SafeDelegationSigner.SignedDelegationResult memory result = _signDelegation(delegation);

        // Create bridge execution
        Execution memory execution = _createBridgeExecution();

        // Prepare and log redemption inputs
        exampleRedeemDelegations(result.delegation, execution);
    }

    /// @notice Helper function to sign a delegation with Safe
    /// @param _delegation The delegation to sign
    /// @return result The signed delegation result
    function _signDelegation(Delegation memory _delegation)
        internal
        view
        returns (SafeDelegationSigner.SignedDelegationResult memory result)
    {
        // Prepare signer configuration
        address signer1 = vm.addr(signer1PrivateKey);
        address signer2 = vm.addr(signer2PrivateKey);
        address signer3 = vm.addr(signer3PrivateKey);
        uint256[] memory signerPrivateKeys = new uint256[](3);
        signerPrivateKeys[0] = signer1PrivateKey;
        signerPrivateKeys[1] = signer2PrivateKey;
        signerPrivateKeys[2] = signer3PrivateKey;
        address[] memory signerAddresses = new address[](3);
        signerAddresses[0] = signer1;
        signerAddresses[1] = signer2;
        signerAddresses[2] = signer3;

        SafeDelegationSigner.SignerConfig memory config = SafeDelegationSigner.SignerConfig({
            safeAddress: safeAddress,
            gatorSafeModule: gatorSafeModule,
            delegationManager: delegationManager,
            signerPrivateKeys: signerPrivateKeys,
            signerAddresses: signerAddresses
        });

        // Sign delegation with Safe
        result = SafeDelegationSigner.signDelegationWithSafe(_delegation, config);
    }

    /// @notice Creates a delegation with enforcers for ERC20 transfer restrictions
    /// @dev Restricts: token contract, transfer function, recipient address
    /// @dev Amount is NOT restricted (flexible)
    /// @return delegation The delegation struct with caveats configured
    function _createERC20TransferDelegation() internal view returns (Delegation memory delegation) {
        // Get enforcer addresses from environment or use defaults
        address allowedTargetsEnforcer = vm.envOr("ALLOWED_TARGETS_ENFORCER", address(0));
        address allowedMethodsEnforcer = vm.envOr("ALLOWED_METHODS_ENFORCER", address(0));
        address allowedCalldataEnforcer = vm.envOr("ALLOWED_CALLDATA_ENFORCER", address(0));

        // Token and recipient configuration (can be overridden via env vars)
        address usdtToken = vm.envOr("ERC20_TOKEN_ADDRESS", address(0x936039A819d99856C00FDa88Da3fc1B94711b9Db));
        address recipient = vm.envOr("ERC20_RECIPIENT_ADDRESS", address(0xE6eEEFbE03E9000ccEd855Fd747FdeD9F89bdc45));

        // Prepare enforcer terms
        // 1. AllowedTargetsEnforcer: restrict to specific token contract
        bytes memory targetTerms = abi.encodePacked(usdtToken);

        // 2. AllowedMethodsEnforcer: restrict to transfer function only
        bytes memory methodTerms = abi.encodePacked(IERC20.transfer.selector);

        // 3. AllowedCalldataEnforcer: restrict recipient address (bytes 4-36 of calldata)
        // ERC20 transfer calldata: [0:4] = selector, [4:36] = recipient (32 bytes), [36:68] = amount (32 bytes)
        uint256 dataStart = 4; // Start after 4-byte selector
        bytes memory recipientBytes = abi.encode(recipient); // Pads to 32 bytes
        bytes memory calldataTerms = abi.encodePacked(dataStart, recipientBytes);

        // Create caveats array
        Caveat[] memory caveats = new Caveat[](3);
        caveats[0] = Caveat({ enforcer: allowedTargetsEnforcer, terms: targetTerms, args: hex"" });
        caveats[1] = Caveat({ enforcer: allowedMethodsEnforcer, terms: methodTerms, args: hex"" });
        caveats[2] = Caveat({ enforcer: allowedCalldataEnforcer, terms: calldataTerms, args: hex"" });

        delegation = _createDelegation(caveats);
        console2.log("Created ERC20 transfer delegation with %d caveats", caveats.length);
    }

    /// @notice Creates vault delegation for swap: gatorSafeModule -> delegate (subVault)
    /// @dev Simple test delegation: only ArgsEqualityCheckEnforcer (Token-Whitelist-Not-Enforced)
    /// @return delegation The vault delegation (must be signed by Safe)
    function _createSwapVaultDelegation() internal view returns (Delegation memory delegation) {
        address argsEqualityCheckEnforcer = vm.envAddress("ARGS_EQUALITY_CHECK_ENFORCER_ADDRESS");
        bytes memory terms = abi.encode("Token-Whitelist-Not-Enforced");

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: argsEqualityCheckEnforcer, terms: terms, args: hex"" });

        delegation = Delegation({
            delegate: delegate,
            delegator: gatorSafeModule,
            authority: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff, // ROOT_AUTHORITY
            caveats: caveats,
            salt: 0,
            signature: hex""
        });
        console2.log("Created swap vault delegation (gatorSafeModule -> delegate) with 1 caveat: ArgsEqualityCheckEnforcer");
    }

    /// @notice Creates subVault delegation for swap: delegate -> adapter
    /// @dev Minimal delegation for testing: no caveats
    /// @param _parentDelegationHash Hash of the vault delegation (authority for this delegation)
    /// @return delegation The subVault delegation (must be signed by automation key)
    function _createSwapSubVaultDelegation(bytes32 _parentDelegationHash) internal view returns (Delegation memory delegation) {
        delegation = Delegation({
            delegate: delegationMetaSwapAdapter,
            delegator: delegate,
            authority: _parentDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        console2.log("Created swap subVault delegation (delegate -> adapter) with 0 caveats");
    }

    /// @notice Signs a delegation with the automation (subVault) EOA key
    /// @param _delegation The delegation to sign
    /// @return The signed delegation
    function _signSubVaultDelegation(Delegation memory _delegation) internal view returns (Delegation memory) {
        bytes32 delegationHash = EncoderLib._getDelegationHash(_delegation);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 typedDataHash = MessageHashUtils.toTypedDataHash(domainHash, delegationHash);
        bytes memory signature = SigningUtilsLib.signHash_EOA(automationPrivateKey, typedDataHash);

        return Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: signature
        });
    }

    /// @notice Creates a delegation with enforcers for bridge operations
    /// @dev Placeholder for bridge-specific restrictions
    /// @return delegation The delegation struct with caveats configured
    function _createBridgeDelegation() internal view returns (Delegation memory delegation) {
        // Get enforcer addresses
        address allowedTargetsEnforcer = vm.envOr("ALLOWED_TARGETS_ENFORCER", address(0));
        address allowedMethodsEnforcer = vm.envOr("ALLOWED_METHODS_ENFORCER", address(0));

        // Bridge contract configuration
        address bridgeContract = vm.envOr("BRIDGE_CONTRACT_ADDRESS", address(0));
        bytes4 bridgeFunctionSelector = bytes4(keccak256("bridge(address,uint256,uint256)")); // Example

        // Prepare enforcer terms
        bytes memory targetTerms = abi.encodePacked(bridgeContract);
        bytes memory methodTerms = abi.encodePacked(bridgeFunctionSelector);

        // Create caveats array
        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = Caveat({ enforcer: allowedTargetsEnforcer, terms: targetTerms, args: hex"" });
        caveats[1] = Caveat({ enforcer: allowedMethodsEnforcer, terms: methodTerms, args: hex"" });

        delegation = _createDelegation(caveats);
        console2.log("Created bridge delegation with %d caveats", caveats.length);
    }

    /// @notice Helper function to create a delegation with given caveats
    /// @param _caveats Array of caveats to include in the delegation
    /// @return delegation The delegation struct
    function _createDelegation(Caveat[] memory _caveats) internal view returns (Delegation memory delegation) {
        delegation = Delegation({
            delegate: delegate,
            delegator: gatorSafeModule,
            authority: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff, // ROOT_AUTHORITY
            caveats: _caveats,
            salt: 0,
            signature: hex"" // Will be set after signing
        });
    }

    /// @notice Creates an ERC20 transfer execution
    /// @return execution The execution struct for ERC20 transfer
    function _createERC20TransferExecution() internal view returns (Execution memory execution) {
        address usdtToken = vm.envOr("ERC20_TOKEN_ADDRESS", address(0x936039A819d99856C00FDa88Da3fc1B94711b9Db));
        address recipient = vm.envOr("ERC20_RECIPIENT_ADDRESS", address(0xE6eEEFbE03E9000ccEd855Fd747FdeD9F89bdc45));
        uint256 transferAmount = vm.envOr("ERC20_TRANSFER_AMOUNT", uint256(10 * 10 ** 18));

        bytes memory transferCallData = abi.encodeWithSelector(IERC20.transfer.selector, recipient, transferAmount);

        execution = Execution({ target: usdtToken, value: 0, callData: transferCallData });
        console2.log("Created ERC20 transfer execution: %s tokens to %s", transferAmount, recipient);
    }

    /**
     * @notice Logs the prepared delegation chain for swapByDelegation
     * @dev subVault (delegate) calls: adapter.swapByDelegation(sigData, delegations, false)
     * @dev IMPORTANT: _useTokenWhitelist must be false (matches ArgsEqualityCheckEnforcer terms)
     * @param _vaultDelegation Signed vault delegation (gatorSafeModule -> delegate)
     * @param _subVaultDelegation Signed subVault delegation (delegate -> adapter)
     */
    function exampleSwapByDelegation(Delegation memory _vaultDelegation, Delegation memory _subVaultDelegation) public pure {
        // Delegations array: leaf to root (subVault first, vault last)
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = _subVaultDelegation;
        delegations[1] = _vaultDelegation;

        console2.log("=== Prepared swapByDelegation Inputs ===");
        console2.log("Adapter: call swapByDelegation(sigData, delegations, false)");
        console2.log("Delegations (leaf to root): [subVaultDelegation, vaultDelegation]");
        console2.log("Vault delegation hash:");
        console2.logBytes32(EncoderLib._getDelegationHash(_vaultDelegation));
        console2.log("SubVault delegation hash:");
        console2.logBytes32(EncoderLib._getDelegationHash(_subVaultDelegation));
        console2.log("Encoded delegations:");
        console2.logBytes(abi.encode(delegations));
    }

    /// @notice Creates a bridge execution
    /// @return execution The execution struct for bridge operation
    function _createBridgeExecution() internal view returns (Execution memory execution) {
        address bridgeContract = vm.envOr("BRIDGE_CONTRACT_ADDRESS", address(0));
        // Example bridge parameters - adjust based on your bridge contract interface
        bytes memory bridgeCallData = hex""; // Placeholder - implement based on bridge contract

        execution = Execution({ target: bridgeContract, value: 0, callData: bridgeCallData });
        console2.log("Created bridge execution for contract: %s", bridgeContract);
    }

    /**
     * @notice Prepares inputs for redeemDelegations function call
     * @dev This function prepares the three arrays needed for DelegationManager.redeemDelegations()
     * @param _signedDelegation The delegation with signature already set
     * @param _execution The execution to be performed (target, value, callData)
     * @return permissionContexts Array of encoded delegation arrays (one per execution)
     * @return modes Array of ModeCode values (one per execution)
     * @return executionCallDatas Array of encoded execution call data (one per execution)
     */
    function prepareRedeemDelegationsInputs(
        Delegation memory _signedDelegation,
        Execution memory _execution
    )
        public
        pure
        returns (bytes[] memory permissionContexts, ModeCode[] memory modes, bytes[] memory executionCallDatas)
    {
        // Prepare permission contexts: array of bytes where each element is abi.encode(Delegation[])
        // For a single delegation chain, we have one Delegation array with one delegation
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = _signedDelegation;

        permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        // Prepare modes: array of ModeCode, one per execution
        // Using encodeSimpleSingle() for simple single execution mode
        modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();

        // Prepare execution call datas: array of encoded executions
        // Using ExecutionLib.encodeSingle() to encode target, value, and callData
        executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData);
    }

    /**
     * @notice Example function showing how to call redeemDelegations with prepared inputs
     * @dev This function demonstrates the usage but the actual call is commented out
     * @param _signedDelegation The delegation with signature already set
     * @param _execution The execution to be performed
     */
    function exampleRedeemDelegations(Delegation memory _signedDelegation, Execution memory _execution) public pure {
        // Prepare inputs
        (bytes[] memory permissionContexts, ModeCode[] memory modes, bytes[] memory executionCallDatas) =
            prepareRedeemDelegationsInputs(_signedDelegation, _execution);

        // Log the prepared inputs for verification
        console2.log("=== Prepared redeemDelegations Inputs ===");
        console2.log("Permission Contexts Length:", permissionContexts.length);
        console2.logBytes(permissionContexts[0]);
        console2.log("Modes Length:", modes.length);
        console2.logBytes32(ModeCode.unwrap(modes[0]));
        console2.log("Execution Call Datas Length:", executionCallDatas.length);
        console2.logBytes(executionCallDatas[0]);

        // Uncomment the line below to actually call redeemDelegations
        // delegationManager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }
}
