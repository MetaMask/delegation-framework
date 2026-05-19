// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManagerChainConfig, BridgeAddrBatch } from "./TreasuryManagerChainTypes.sol";
import { TreasuryManager } from "../../src/helpers/TreasuryManager.sol";

/// @dev Shared boilerplate: canonical wrapped native + empty arrays + protocol fields zeroed (set in chain file).
library TreasuryManagerChainSkeleton {
    function base(uint256 evmChainId_, address weth_) internal pure returns (TreasuryManagerChainConfig memory c) {
        c.evmChainId = evmChainId_;
        c.weth = weth_;
        c.delegationManager = address(0);
        c.metaSwap = address(0);
        c.metaBridge = address(0);
        c.apiSigner = address(0);
        c.stEth = address(0);
        c.wstEth = address(0);
        c.allowedCallers = new address[](0);
        c.pairLimits = new TreasuryManager.PairLimitInput[](0);
        c.bridgeRouteLimits = new TreasuryManager.BridgeRouteLimitInput[](0);
        c.allowedDestWallets = new address[](0);
        c.allowedDestWalletStatuses = new bool[](0);
        c.destinationChainIds = new uint256[](0);
        c.destinationChainStatuses = new bool[](0);
        c.bridgeDestWalletBatches = new BridgeAddrBatch[](0);
    }
}
