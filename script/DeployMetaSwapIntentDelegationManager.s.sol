// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { MetaSwapDelegationManagerBase } from "../src/MetaSwapDelegationManagerBase.sol";
import { MetaSwapIntentDelegationManager } from "../src/MetaSwapIntentDelegationManager.sol";

/**
 * @title DeployMetaSwapIntentDelegationManager
 * @notice Deploys the experimental MetaSwap intent delegation manager.
 * @dev Experimental. EIP-7702 accounts must be wired to this manager address.
 *
 * forge script script/DeployMetaSwapIntentDelegationManager.s.sol --rpc-url <rpc> --private-key $PRIVATE_KEY --broadcast
 *
 * Env:
 * - SALT
 * - SIGNATURE_MODE: 0 = DirectECDSA, 1 = ERC1271
 */
contract DeployMetaSwapIntentDelegationManager is Script {
    bytes32 salt;
    MetaSwapDelegationManagerBase.SignatureMode signatureMode;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        uint256 mode_ = vm.envOr("SIGNATURE_MODE", uint256(0));
        require(mode_ <= 1, "SIGNATURE_MODE must be 0 or 1");
        signatureMode = MetaSwapDelegationManagerBase.SignatureMode(uint8(mode_));

        console2.log("~~~");
        console2.log("Salt:");
        console2.logBytes32(salt);
        console2.log("SignatureMode: %s", mode_ == 0 ? "DirectECDSA" : "ERC1271");
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress = address(new MetaSwapIntentDelegationManager{ salt: salt }(signatureMode));
        console2.log("MetaSwapIntentDelegationManager: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
