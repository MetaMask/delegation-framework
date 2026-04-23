// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { BasicERC20 } from "../test/utils/BasicERC20.t.sol";

/**
 * @title DeployBasicERC20
 * @notice Deploys a BasicERC20 contract configured to simulate USDT (Tether USD)
 * @dev The contract uses 18 decimals (default ERC20) rather than USDT's 6 decimals
 * @dev To use 6 decimals, modify BasicERC20 to override the decimals() function
 * @dev run the script with:
 * forge script script/DeployBasicERC20.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployBasicERC20 is Script {
    address owner;
    string constant TOKEN_NAME = "Tether USD";
    string constant TOKEN_SYMBOL = "USDT";
    uint256 constant INITIAL_SUPPLY = 1_000_000 * 10**18; // 1,000,000 USDT (with 18 decimals)

    function setUp() public {
        // Owner can be set via environment variable or defaults to msg.sender
        owner = vm.envOr("OWNER_ADDRESS", address(msg.sender));
        console2.log("~~~");
        console2.log("Owner: %s", owner);
        console2.log("Token Name: %s", TOKEN_NAME);
        console2.log("Token Symbol: %s", TOKEN_SYMBOL);
        console2.log("Initial Supply: %s", INITIAL_SUPPLY);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        // Deploy BasicERC20 configured as USDT
        BasicERC20 usdt = new BasicERC20(
            owner,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            INITIAL_SUPPLY
        );

        console2.log("USDT deployed at: %s", address(usdt));
        console2.log("Owner balance: %s", usdt.balanceOf(owner));

        vm.stopBroadcast();
    }
}

