// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DelegationMetaSwapAdapter } from "../src/helpers/DelegationMetaSwapAdapter.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";

/**
 * @title DeployDelegationMetaSwapAdapter
 * @notice Deploys the `DelegationMetaSwapAdapter` and (optionally) configures it in the same broadcast.
 *
 * @dev DEPLOYMENT MODEL
 *      The contract is always deployed with `META_SWAP_ADAPTER_OWNER_ADDRESS` as the constructor owner so
 *      the CREATE2 init code (and therefore the deployment address) stays deterministic across chains and
 *      across runs that share the same `SALT`.
 *
 *      Auto-configuration only runs when `deployer == metaSwapAdapterOwner` (i.e. the broadcaster is also
 *      the final owner). When they differ, the script just deploys and logs the calls the owner must make
 *      separately (typically from a Safe).
 *
 * @dev CONFIGURATION
 *      Pair policies are HARDCODED in `_pairLimits()` below as an array of `PairLimitInput` structs
 *      — edit them before running. Each entry sets one (tokenFrom, tokenTo) pair with its slippage
 *      cap, price-impact cap, and `enabled` flag (the `enabled` flag IS the pair allow-list).
 *
 *      `ALLOWED_CALLERS` (operator/relayer addresses) is still read from the env so it can vary per
 *      environment without code changes.
 *
 * @dev REQUIRED ENV VARS (see .env.example)
 *      - SALT
 *      - META_SWAP_ADAPTER_OWNER_ADDRESS
 *      - DELEGATION_MANAGER_ADDRESS
 *      - METASWAP_ADDRESS
 *      - SWAPS_API_SIGNER_ADDRESS
 *      - ALLOWED_CALLERS  (comma-separated addresses; optional, may be empty)
 *
 * @dev RUN
 *      forge script script/DeployDelegationMetaSwapAdapter.s.sol \
 *          --rpc-url $LINEA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
 */
contract DeployDelegationMetaSwapAdapter is Script {
    bytes32 internal salt;
    address internal deployer;
    address internal metaSwapAdapterOwner;
    address internal swapApiSigner;
    IDelegationManager internal delegationManager;
    IMetaSwap internal metaSwap;

    address[] internal allowedCallers;

    // Linea token addresses
    address internal constant ETH = address(0);
    address internal constant WETH = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
    address internal constant USDC = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address internal constant USDT = 0xA219439258ca9da29E9Cc4cE5596924745e12B93;
    address internal constant DAI = 0x4AF15ec2A0BD43Db75dd04E62FAA3B8EF36b00d5;
    address internal constant WBTC = 0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        metaSwapAdapterOwner = vm.envAddress("META_SWAP_ADAPTER_OWNER_ADDRESS");
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        metaSwap = IMetaSwap(vm.envAddress("METASWAP_ADDRESS"));
        swapApiSigner = vm.envAddress("SWAPS_API_SIGNER_ADDRESS");
        deployer = msg.sender;

        allowedCallers = _readAddressArray("ALLOWED_CALLERS");

        _validateInputs();
        _logConfig();
    }

    function run() public {
        console2.log("~~~ Broadcasting deploy ~~~");
        vm.startBroadcast();

        DelegationMetaSwapAdapter adapter_ = new DelegationMetaSwapAdapter{ salt: salt }(
            metaSwapAdapterOwner, swapApiSigner, delegationManager, metaSwap, IERC20(WETH)
        );
        console2.log("DelegationMetaSwapAdapter deployed at: %s", address(adapter_));

        if (deployer == metaSwapAdapterOwner) {
            _configure(adapter_);
        } else {
            _logManualConfigInstructions(address(adapter_));
        }

        vm.stopBroadcast();
    }

    ////////////////////////////// Hardcoded configuration //////////////////////////////

    // NATIVE TOKEN: use `address(0)` for the chain's native token.
    //
    // Pair policy is directional: A->B and B->A are independent entries.
    // Format: 1e18 = 1%, 100e18 = 100%; values must be <= 100e18.
    // enabled == false disables the pair regardless of cap values.

    /// @dev Per-(tokenFrom, tokenTo) pair policies. EDIT before deploying.
    /// Caps below are MAX values (the contract enforces signed <= cap; the API/operator should also
    /// apply tighter "safe" defaults off-chain).
    function _pairLimits() internal pure returns (DelegationMetaSwapAdapter.PairLimitInput[] memory inputs_) {
        inputs_ = new DelegationMetaSwapAdapter.PairLimitInput[](8);

        // ETH <-> USDC and WETH <-> USDC : max slippage 1%, max priceImpact 0.75%
        inputs_[0] = _pair(ETH, USDC, 1e18, 0.75e18);
        inputs_[1] = _pair(USDC, ETH, 1e18, 0.75e18);

        // USDT -> USDC : max slippage 0.5%, max priceImpact 0.25%
        inputs_[2] = _pair(USDT, USDC, 0.5e18, 0.25e18);

        // USDT -> ETH : max slippage 1.25%, max priceImpact 1%
        inputs_[3] = _pair(USDT, ETH, 1.25e18, 1e18);

        // DAI -> USDC : max slippage 1.5%, max priceImpact 1%
        inputs_[4] = _pair(DAI, USDC, 1.5e18, 1e18);

        // DAI -> ETH : max slippage 2%, max priceImpact 1.5%
        inputs_[5] = _pair(DAI, ETH, 2e18, 1.5e18);

        // WBTC -> ETH : max slippage 1.25%, max priceImpact 1%
        inputs_[6] = _pair(WBTC, ETH, 1.25e18, 1e18);

        // WBTC -> USDC : max slippage 2%, max priceImpact 1.5%
        inputs_[7] = _pair(WBTC, USDC, 2e18, 1.5e18);
    }

    /// @dev Compact constructor for a single enabled `PairLimitInput`.
    function _pair(
        address _from,
        address _to,
        uint128 _maxSlippage,
        uint128 _maxPriceImpact
    )
        private
        pure
        returns (DelegationMetaSwapAdapter.PairLimitInput memory)
    {
        return DelegationMetaSwapAdapter.PairLimitInput({
            tokenFrom: IERC20(_from),
            tokenTo: IERC20(_to),
            limit: DelegationMetaSwapAdapter.PairLimit({
                maxSlippage: _maxSlippage, maxPriceImpact: _maxPriceImpact, enabled: true
            })
        });
    }

    ////////////////////////////// Configuration //////////////////////////////

    function _configure(DelegationMetaSwapAdapter _adapter) internal {
        if (allowedCallers.length != 0) {
            _adapter.updateAllowedCallers(allowedCallers, _trueArray(allowedCallers.length));
            console2.log("Configured %s allowed caller(s):", allowedCallers.length);
            for (uint256 i_ = 0; i_ < allowedCallers.length; ++i_) {
                console2.log("  - %s", allowedCallers[i_]);
            }
        }

        DelegationMetaSwapAdapter.PairLimitInput[] memory pairs_ = _pairLimits();
        if (pairs_.length != 0) {
            _adapter.setPairLimits(pairs_);
            console2.log("Configured %s pair limit(s):", pairs_.length);
            for (uint256 i_ = 0; i_ < pairs_.length; ++i_) {
                console2.log("  - tokenFrom=%s tokenTo=%s", address(pairs_[i_].tokenFrom), address(pairs_[i_].tokenTo));
                console2.log(
                    "      maxSlippage=%s maxPriceImpact=%s enabled=%s",
                    pairs_[i_].limit.maxSlippage,
                    pairs_[i_].limit.maxPriceImpact,
                    pairs_[i_].limit.enabled ? "true" : "false"
                );
            }
        }
    }

    function _logManualConfigInstructions(address _adapter) internal view {
        console2.log("");
        console2.log("~~~ Deployer != owner: skipping auto-configuration ~~~");
        console2.log("The owner (%s) must execute the following calls on %s:", metaSwapAdapterOwner, _adapter);

        if (allowedCallers.length != 0) {
            console2.log("  updateAllowedCallers(<addresses>, <true...>)  with addresses:");
            for (uint256 i_ = 0; i_ < allowedCallers.length; ++i_) {
                console2.log("    - %s", allowedCallers[i_]);
            }
        }

        DelegationMetaSwapAdapter.PairLimitInput[] memory pairs_ = _pairLimits();
        if (pairs_.length != 0) {
            console2.log("  setPairLimits(PairLimitInput[]) with entries:");
            for (uint256 i_ = 0; i_ < pairs_.length; ++i_) {
                console2.log("    - tokenFrom=%s tokenTo=%s", address(pairs_[i_].tokenFrom), address(pairs_[i_].tokenTo));
                console2.log(
                    "        maxSlippage=%s maxPriceImpact=%s enabled=%s",
                    pairs_[i_].limit.maxSlippage,
                    pairs_[i_].limit.maxPriceImpact,
                    pairs_[i_].limit.enabled ? "true" : "false"
                );
            }
        }
    }

    ////////////////////////////// Env / misc helpers //////////////////////////////

    /**
     * @dev Reads a comma-separated address list from `_name`. Returns an empty array if the env var is
     *      unset or empty. Required so optional configuration sections can be safely omitted.
     */
    function _readAddressArray(string memory _name) internal view returns (address[] memory) {
        string memory raw_ = vm.envOr(_name, string(""));
        if (bytes(raw_).length == 0) return new address[](0);
        return vm.envAddress(_name, ",");
    }

    function _trueArray(uint256 _len) internal pure returns (bool[] memory out_) {
        out_ = new bool[](_len);
        for (uint256 i_ = 0; i_ < _len; ++i_) {
            out_[i_] = true;
        }
    }

    function _validateInputs() internal view {
        require(metaSwapAdapterOwner != address(0), "DeployScript: owner is zero");
        require(swapApiSigner != address(0), "DeployScript: swap api signer is zero");
        require(address(delegationManager) != address(0), "DeployScript: delegation manager is zero");
        require(address(metaSwap) != address(0), "DeployScript: metaSwap is zero");
    }

    function _logConfig() internal view {
        DelegationMetaSwapAdapter.PairLimitInput[] memory pairs_ = _pairLimits();

        console2.log("~~~ Deploy configuration ~~~");
        console2.log("Deployer:                  %s", deployer);
        console2.log("Owner:                     %s", metaSwapAdapterOwner);
        console2.log("DelegationManager:         %s", address(delegationManager));
        console2.log("MetaSwap:                  %s", address(metaSwap));
        console2.log("SwapApiSigner:             %s", swapApiSigner);
        console2.log("Auto-configure:            ", deployer == metaSwapAdapterOwner ? "yes" : "no");
        console2.log("Salt:");
        console2.logBytes32(salt);

        console2.log("Allowed callers (%s):", allowedCallers.length);
        for (uint256 i_ = 0; i_ < allowedCallers.length; ++i_) {
            console2.log("  - %s", allowedCallers[i_]);
        }

        console2.log("Pair limits (%s):", pairs_.length);
        for (uint256 i_ = 0; i_ < pairs_.length; ++i_) {
            console2.log("  - tokenFrom=%s tokenTo=%s", address(pairs_[i_].tokenFrom), address(pairs_[i_].tokenTo));
            console2.log(
                "      maxSlippage=%s maxPriceImpact=%s enabled=%s",
                pairs_[i_].limit.maxSlippage,
                pairs_[i_].limit.maxPriceImpact,
                pairs_[i_].limit.enabled ? "true" : "false"
            );
        }
    }
}
