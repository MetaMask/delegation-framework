// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DelegationMetaSwapAdapter } from "../src/helpers/DelegationMetaSwapAdapter.sol";

/**
 * @title UpdateAllowedAggregatorIds
 * @notice Script to whitelist aggregator IDs on DelegationMetaSwapAdapter
 * @dev Uses PRIVATE_KEY from .env. Run with:
 *   forge script script/UpdateAllowedAggregatorIds.s.sol --rpc-url $LINEA_RPC_URL --broadcast
 * @dev Ensure DELEGATION_METASWAP_ADAPTER_ADDRESS is set in .env
 */
contract UpdateAllowedAggregatorIds is Script {
    function setUp() public view {
        address adapter = vm.envAddress("DELEGATION_METASWAP_ADAPTER_ADDRESS");
        console2.log("DelegationMetaSwapAdapter: %s", adapter);
    }

    function run() public {
        DelegationMetaSwapAdapter adapter =
            DelegationMetaSwapAdapter(payable(vm.envAddress("DELEGATION_METASWAP_ADAPTER_ADDRESS")));

        string[] memory aggregatorIds = new string[](1);
        aggregatorIds[0] = "openOceanFeeDynamic";

        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        console2.log("Calling updateAllowedAggregatorIds(\"openOceanFeeDynamic\", true)");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        adapter.updateAllowedAggregatorIds(aggregatorIds, statuses);
        vm.stopBroadcast();

        bytes32 hash = keccak256(abi.encode("openOceanFeeDynamic"));
        console2.log("openOceanFeeDynamic is now allowed:", adapter.isAggregatorAllowed(hash));
    }
}
