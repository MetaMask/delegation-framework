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
 * @title SignPeriodDelegationsWithSafe
 * @notice Signs two delegations (ERC20 USDT period + native ETH period) with recipient restriction, using Safe.
 * @dev Delegation 1: ERC20 (USDT) — 0.1 USDT per 3 min, recipient 0x3EFC72fF137A5603Ce2E7108a70e56CAb49bf1e2.
 * @dev Delegation 2: Native ETH — 0.0001 ETH per 3 min, same recipient.
 * @dev Required .env: SAFE_ADDRESS, GATOR_SAFE_MODULE_ADDRESS, DELEGATION_MANAGER_ADDRESS, DELEGATE_ADDRESS,
 *      SIGNER1_PRIVATE_KEY, SIGNER2_PRIVATE_KEY, SIGNER3_PRIVATE_KEY,
 *      ERC20_PERIOD_ENFORCER_ADDRESS, NATIVE_PERIOD_ENFORCER_ADDRESS, ALLOWED_TARGETS_ENFORCER_ADDRESS,
 * ALLOWED_CALLDATA_ENFORCER_ADDRESS.
 * @dev Optional: PERIOD_START_DATE (defaults to block.timestamp = current time, period starts immediately).
 * @dev Run: forge script script/SignPeriodDelegationsWithSafe.s.sol:SignPeriodDelegationsWithSafe --sig "run()" --rpc-url <rpc>
 */
contract SignPeriodDelegationsWithSafe is Script {
    using SafeDelegationSigner for SafeDelegationSigner.SignerConfig;

    address safeAddress;
    address gatorSafeModule;
    IDelegationManager delegationManager;
    address delegate;
    uint256 signer1PrivateKey;
    uint256 signer2PrivateKey;
    uint256 signer3PrivateKey;

    address constant USDT = address(0xA219439258ca9da29E9Cc4cE5596924745e12B93);
    address constant RECIPIENT = address(0x3EFC72fF137A5603Ce2E7108a70e56CAb49bf1e2);
    uint256 constant USDT_PERIOD_AMOUNT = 100_000; // 0.1 USDT (6 decimals)
    uint256 constant PERIOD_DURATION = 180; // 3 minutes
    uint256 constant ETH_PERIOD_AMOUNT_WEI = 100_000_000_000_000; // 0.0001 ETH

    function setUp() public {
        safeAddress = vm.envAddress("SAFE_ADDRESS");
        gatorSafeModule = vm.envAddress("GATOR_SAFE_MODULE_ADDRESS");
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        delegate = vm.envAddress("DELEGATE_ADDRESS");
        signer1PrivateKey = vm.envUint("SIGNER1_PRIVATE_KEY");
        signer2PrivateKey = vm.envUint("SIGNER2_PRIVATE_KEY");
        signer3PrivateKey = vm.envUint("SIGNER3_PRIVATE_KEY");
        console2.log("Safe: %s | Gator: %s | Delegate: %s", safeAddress, gatorSafeModule, delegate);
    }

    function run() public view {
        console2.log("=== 1. ERC20 (USDT) period delegation ===");
        Delegation memory erc20Delegation = _createERC20PeriodDelegation();
        SafeDelegationSigner.SignedDelegationResult memory erc20Result = _signDelegation(erc20Delegation);
        Execution memory erc20Execution = _createERC20PeriodExecution();
        _logRedeemInputs("ERC20 USDT", erc20Result.delegation, erc20Execution);

        console2.log("");
        console2.log("=== 2. Native ETH period delegation ===");
        Delegation memory nativeDelegation = _createNativePeriodDelegation();
        SafeDelegationSigner.SignedDelegationResult memory nativeResult = _signDelegation(nativeDelegation);
        Execution memory nativeExecution = _createNativePeriodExecution();
        _logRedeemInputs("Native ETH", nativeResult.delegation, nativeExecution);
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

    function _createERC20PeriodDelegation() internal view returns (Delegation memory) {
        address erc20PeriodEnforcer = vm.envAddress("ERC20_PERIOD_ENFORCER_ADDRESS");
        address allowedTargetsEnforcer = vm.envAddress("ALLOWED_TARGETS_ENFORCER_ADDRESS");
        address allowedCalldataEnforcer = vm.envAddress("ALLOWED_CALLDATA_ENFORCER_ADDRESS");

        // startDate: must be in the past so period is active. Set PERIOD_START_DATE in .env or use current timestamp.
        // Using current timestamp ensures proper period calculation alignment with real time.
        uint256 startDate = vm.envOr("PERIOD_START_DATE", block.timestamp);

        // ERC20PeriodTransferEnforcer: 116 bytes = token(20) + periodAmount(32) + periodDuration(32) + startDate(32)
        bytes memory periodTerms = abi.encodePacked(USDT, uint256(USDT_PERIOD_AMOUNT), uint256(PERIOD_DURATION), startDate);

        // AllowedTargetsEnforcer: only USDT contract as target
        bytes memory targetTerms = abi.encodePacked(USDT);

        // AllowedCalldataEnforcer: recipient at callData[4:36] (after selector). Terms: dataStart(32) + value(32)
        bytes memory calldataTerms = abi.encodePacked(uint256(4), abi.encode(RECIPIENT));

        Caveat[] memory caveats = new Caveat[](3);
        caveats[0] = Caveat({ enforcer: erc20PeriodEnforcer, terms: periodTerms, args: hex"" });
        caveats[1] = Caveat({ enforcer: allowedTargetsEnforcer, terms: targetTerms, args: hex"" });
        caveats[2] = Caveat({ enforcer: allowedCalldataEnforcer, terms: calldataTerms, args: hex"" });

        return Delegation({
            delegate: delegate,
            delegator: gatorSafeModule,
            authority: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });
    }

    function _createNativePeriodDelegation() internal view returns (Delegation memory) {
        address nativePeriodEnforcer = vm.envAddress("NATIVE_PERIOD_ENFORCER_ADDRESS");
        address allowedTargetsEnforcer = vm.envAddress("ALLOWED_TARGETS_ENFORCER_ADDRESS");

        // startDate: must be in the past so period is active. Set PERIOD_START_DATE in .env or use current timestamp.
        // Using current timestamp ensures proper period calculation alignment with real time.
        uint256 startDate = vm.envOr("PERIOD_START_DATE", block.timestamp);

        // NativeTokenPeriodTransferEnforcer: 96 bytes = periodAmount(32) + periodDuration(32) + startDate(32)
        bytes memory periodTerms = abi.encodePacked(ETH_PERIOD_AMOUNT_WEI, uint256(PERIOD_DURATION), startDate);

        // AllowedTargetsEnforcer: only recipient can receive ETH (target = recipient for native send)
        bytes memory targetTerms = abi.encodePacked(RECIPIENT);

        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = Caveat({ enforcer: nativePeriodEnforcer, terms: periodTerms, args: hex"" });
        caveats[1] = Caveat({ enforcer: allowedTargetsEnforcer, terms: targetTerms, args: hex"" });

        return Delegation({
            delegate: delegate,
            delegator: gatorSafeModule,
            authority: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });
    }

    function _createERC20PeriodExecution() internal pure returns (Execution memory) {
        bytes memory callData = abi.encodeWithSelector(IERC20.transfer.selector, RECIPIENT, USDT_PERIOD_AMOUNT);
        return Execution({ target: USDT, value: 0, callData: callData });
    }

    function _createNativePeriodExecution() internal pure returns (Execution memory) {
        return Execution({ target: RECIPIENT, value: ETH_PERIOD_AMOUNT_WEI, callData: hex"" });
    }

    function _logRedeemInputs(string memory label, Delegation memory _signedDelegation, Execution memory _execution) internal pure {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = _signedDelegation;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData);

        console2.log("--- %s: Permission Context ---", label);
        console2.logBytes(permissionContexts[0]);
        console2.log("--- %s: Mode ---", label);
        console2.logBytes32(ModeCode.unwrap(modes[0]));
        console2.log("--- %s: Execution Call Data ---", label);
        console2.logBytes(executionCallDatas[0]);
    }
}
