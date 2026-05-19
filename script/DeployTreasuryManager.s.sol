// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TreasuryManager } from "../src/helpers/TreasuryManager.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IMetaBridge } from "../src/helpers/interfaces/IMetaBridge.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";

import { BridgeAddrBatch, TreasuryManagerChainConfig } from "./treasury/TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainConfigRouter } from "./treasury/TreasuryManagerChainConfigRouter.sol";

/**
 * @title DeployTreasuryManager
 * @notice Deploys `TreasuryManager` with CREATE2, `initialize`, and owner policies in one broadcast (owner = deployer).
 *
 * @dev CHAIN CONFIG
 *      Set `DEPLOY_CHAIN` to one of: `ethereum`, `bsc`, `polygon`, `base`, `arbitrum`, `linea`, `avalanche`,
 *      `zksync`, `sei`, `optimism`, `monad` (lowercase). Per-chain data lives in `script/treasury/chains/`.
 *      Each `TreasuryManagerConfig*.get()` includes commented `delegationManager` / `metaSwap` / `metaBridge` /
 *      `apiSigner` (and optional `allowedCallers`) assignments — uncomment and set before broadcast, then tune
 *      `pairLimits`, `bridgeRouteLimits`, and allowlists as needed. `TreasuryManagerChainBridgeDefaults` sets
 *      Ethereum (chain id 1) as the sole bridge destination; same-chain payout wallets (`_sameChainDestWallets`) and
 *      bridge-only dest wallets (`_bridgeDestWallets`) must be set explicitly in each chain file and passed into
 *      `TreasuryManagerChainBridgeDefaults.applyStandardAllowlistsAndBridgeTopology`. Output-token gating is enforced
 *      per swap pair via `pairLimits` and per bridge route via `bridgeRouteLimits`.
 *
 * @dev REQUIRED ENV
 *      - `DEPLOY_CHAIN` (see above)
 *      - `PRIVATE_KEY` (owner + broadcaster)
 *      - `SALT` (CREATE2 salt string)
 *
 * @dev RUN
 *      DEPLOY_CHAIN=linea forge script script/DeployTreasuryManager.s.sol \
 *          --rpc-url $LINEA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
 */
contract DeployTreasuryManager is Script {
    bytes32 internal salt;
    address internal treasuryOwner;
    uint256 internal broadcasterPrivateKey;

    function setUp() public {
        broadcasterPrivateKey = vm.envUint("PRIVATE_KEY");
        treasuryOwner = vm.addr(broadcasterPrivateKey);
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        TreasuryManagerChainConfig memory cfg_ = TreasuryManagerChainConfigRouter.load(vm);

        require(block.chainid == cfg_.evmChainId, "DeployTreasuryManager: RPC chainId mismatch vs config");
        _validateInputs(cfg_);
        _logConfig(cfg_);
    }

    function run() public {
        TreasuryManagerChainConfig memory cfg_ = TreasuryManagerChainConfigRouter.load(vm);

        vm.startBroadcast(broadcasterPrivateKey);

        console2.log("~~~ Broadcasting deploy (chain: %s) ~~~", vm.envString("DEPLOY_CHAIN"));

        TreasuryManager treasury_ = new TreasuryManager{ salt: salt }(treasuryOwner);
        console2.log("TreasuryManager deployed at: %s", address(treasury_));

        _initializeAndConfigure(treasury_, cfg_);

        vm.stopBroadcast();
    }

    function _initializeAndConfigure(TreasuryManager _treasury, TreasuryManagerChainConfig memory cfg_) internal {
        _treasury.initialize(
            cfg_.apiSigner,
            IDelegationManager(cfg_.delegationManager),
            IMetaSwap(cfg_.metaSwap),
            IMetaBridge(cfg_.metaBridge),
            IERC20(cfg_.weth),
            cfg_.stEth,
            cfg_.wstEth
        );
        console2.log("initialize() completed");

        if (cfg_.allowedCallers.length != 0) {
            _treasury.updateAllowedCallers(cfg_.allowedCallers, _trueArray(cfg_.allowedCallers.length));
            console2.log("Configured %s allowed caller(s)", cfg_.allowedCallers.length);
            for (uint256 i_; i_ < cfg_.allowedCallers.length; ++i_) {
                console2.log("  - %s", cfg_.allowedCallers[i_]);
            }
        }

        if (cfg_.pairLimits.length != 0) {
            _treasury.setPairLimits(cfg_.pairLimits);
            console2.log("Configured %s pair limit(s)", cfg_.pairLimits.length);
            for (uint256 i_; i_ < cfg_.pairLimits.length; ++i_) {
                console2.log(
                    "  - tokenFrom=%s tokenTo=%s", address(cfg_.pairLimits[i_].tokenFrom), address(cfg_.pairLimits[i_].tokenTo)
                );
                console2.log(
                    "      maxSlippage=%s maxPriceImpact=%s enabled=%s",
                    cfg_.pairLimits[i_].limit.maxSlippage,
                    cfg_.pairLimits[i_].limit.maxPriceImpact,
                    cfg_.pairLimits[i_].limit.enabled ? "true" : "false"
                );
            }
        }

        if (cfg_.bridgeRouteLimits.length != 0) {
            _treasury.setBridgeRouteLimits(cfg_.bridgeRouteLimits);
            console2.log("Configured %s bridge route limit(s)", cfg_.bridgeRouteLimits.length);
            for (uint256 i_; i_ < cfg_.bridgeRouteLimits.length; ++i_) {
                console2.log(
                    "  - sourceTokenFrom=%s destChainId=%s destTokenTo=%s",
                    address(cfg_.bridgeRouteLimits[i_].sourceTokenFrom),
                    cfg_.bridgeRouteLimits[i_].destinationChainId,
                    cfg_.bridgeRouteLimits[i_].destinationTokenTo
                );
                console2.log(
                    "      maxSlippage=%s maxPriceImpact=%s enabled=%s",
                    cfg_.bridgeRouteLimits[i_].limit.maxSlippage,
                    cfg_.bridgeRouteLimits[i_].limit.maxPriceImpact,
                    cfg_.bridgeRouteLimits[i_].limit.enabled ? "true" : "false"
                );
            }
        }

        _configureAllowlists(_treasury, cfg_);
    }

    function _configureAllowlists(TreasuryManager _treasury, TreasuryManagerChainConfig memory cfg_) internal {
        if (cfg_.allowedDestWallets.length != 0) {
            require(
                cfg_.allowedDestWallets.length == cfg_.allowedDestWalletStatuses.length,
                "DeployTreasuryManager: dest wallets length mismatch"
            );
            _treasury.updateAllowedDestWallets(cfg_.allowedDestWallets, cfg_.allowedDestWalletStatuses);
            console2.log("updateAllowedDestWallets: %s entries", cfg_.allowedDestWallets.length);
        }

        if (cfg_.destinationChainIds.length != 0) {
            require(
                cfg_.destinationChainIds.length == cfg_.destinationChainStatuses.length,
                "DeployTreasuryManager: destination chains length mismatch"
            );
            _treasury.updateDestinationChains(cfg_.destinationChainIds, cfg_.destinationChainStatuses);
            console2.log("updateDestinationChains: %s entries", cfg_.destinationChainIds.length);
        }

        for (uint256 i_; i_ < cfg_.bridgeDestWalletBatches.length; ++i_) {
            BridgeAddrBatch memory b_ = cfg_.bridgeDestWalletBatches[i_];
            if (b_.addresses.length == 0) continue;
            require(b_.addresses.length == b_.statuses.length, "DeployTreasuryManager: bridge dest statuses mismatch");
            _treasury.updateAllowedBridgeDestWallets(b_.destinationChainId, b_.addresses, b_.statuses);
            console2.log("updateAllowedBridgeDestWallets chainId=%s count=%s", b_.destinationChainId, b_.addresses.length);
        }
    }

    function _trueArray(uint256 _len) internal pure returns (bool[] memory out_) {
        out_ = new bool[](_len);
        for (uint256 i_; i_ < _len; ++i_) {
            out_[i_] = true;
        }
    }

    function _validateInputs(TreasuryManagerChainConfig memory cfg_) internal view {
        require(treasuryOwner != address(0), "DeployTreasuryManager: owner is zero");
        require(cfg_.apiSigner != address(0), "DeployTreasuryManager: api signer is zero");
        require(cfg_.delegationManager != address(0), "DeployTreasuryManager: delegation manager is zero");
        require(cfg_.metaSwap != address(0), "DeployTreasuryManager: metaSwap is zero");
        require(cfg_.metaBridge != address(0), "DeployTreasuryManager: metaBridge is zero");
        require(cfg_.weth != address(0), "DeployTreasuryManager: weth is zero (edit chain config file)");
    }

    function _logConfig(TreasuryManagerChainConfig memory cfg_) internal view {
        console2.log("~~~ Deploy configuration ~~~");
        console2.log("DEPLOY_CHAIN:                  %s", vm.envString("DEPLOY_CHAIN"));
        console2.log("config evmChainId:             %s", cfg_.evmChainId);
        console2.log("Owner (from PRIVATE_KEY):      %s", treasuryOwner);
        console2.log("DelegationManager:             %s", cfg_.delegationManager);
        console2.log("MetaSwap:                      %s", cfg_.metaSwap);
        console2.log("MetaBridge:                    %s", cfg_.metaBridge);
        console2.log("WETH:                          %s", cfg_.weth);
        console2.log("stEth:                         %s", cfg_.stEth);
        console2.log("wstEth:                        %s", cfg_.wstEth);
        console2.log("Api signer:                    %s", cfg_.apiSigner);
        console2.log("Salt:");
        console2.logBytes32(salt);

        console2.log("Allowed callers (%s):", cfg_.allowedCallers.length);
        for (uint256 i_; i_ < cfg_.allowedCallers.length; ++i_) {
            console2.log("  - %s", cfg_.allowedCallers[i_]);
        }

        console2.log("Pair limits (%s):", cfg_.pairLimits.length);
        for (uint256 i_; i_ < cfg_.pairLimits.length; ++i_) {
            console2.log(
                "  - tokenFrom=%s tokenTo=%s", address(cfg_.pairLimits[i_].tokenFrom), address(cfg_.pairLimits[i_].tokenTo)
            );
            console2.log(
                "      maxSlippage=%s maxPriceImpact=%s enabled=%s",
                cfg_.pairLimits[i_].limit.maxSlippage,
                cfg_.pairLimits[i_].limit.maxPriceImpact,
                cfg_.pairLimits[i_].limit.enabled ? "true" : "false"
            );
        }

        console2.log("Bridge route limits (%s):", cfg_.bridgeRouteLimits.length);
        for (uint256 i_; i_ < cfg_.bridgeRouteLimits.length; ++i_) {
            console2.log(
                "  - sourceTokenFrom=%s destChainId=%s destTokenTo=%s",
                address(cfg_.bridgeRouteLimits[i_].sourceTokenFrom),
                cfg_.bridgeRouteLimits[i_].destinationChainId,
                cfg_.bridgeRouteLimits[i_].destinationTokenTo
            );
            console2.log(
                "      maxSlippage=%s maxPriceImpact=%s enabled=%s",
                cfg_.bridgeRouteLimits[i_].limit.maxSlippage,
                cfg_.bridgeRouteLimits[i_].limit.maxPriceImpact,
                cfg_.bridgeRouteLimits[i_].limit.enabled ? "true" : "false"
            );
        }

        console2.log("Allowlist same-chain dest wallets (count): %s", cfg_.allowedDestWallets.length);
        if (cfg_.bridgeDestWalletBatches.length != 0) {
            console2.log("Bridge dest wallets (first batch, count): %s", cfg_.bridgeDestWalletBatches[0].addresses.length);
        }
        console2.log("Allowlist destination chains (count):  %s", cfg_.destinationChainIds.length);
        console2.log("Bridge dest wallet batches:            %s", cfg_.bridgeDestWalletBatches.length);
    }
}
