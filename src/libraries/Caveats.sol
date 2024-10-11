// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Caveat } from "../utils/Types.sol";
import { AllowedCalldataEnforcer } from "../enforcers/AllowedCalldataEnforcer.sol";
import { AllowedMethodsEnforcer } from "../enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../enforcers/AllowedTargetsEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../enforcers/ArgsEqualityCheckEnforcer.sol";
import { BlockNumberEnforcer } from "../enforcers/BlockNumberEnforcer.sol";
import { DeployedEnforcer } from "../enforcers/DeployedEnforcer.sol";
import { ERC20BalanceGteEnforcer } from "../enforcers/ERC20BalanceGteEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../enforcers/ERC20TransferAmountEnforcer.sol";
import { ERC721TransferEnforcer } from "../enforcers/ERC721TransferEnforcer.sol";
import { IdEnforcer } from "../enforcers/IdEnforcer.sol";
import { LimitedCallsEnforcer } from "../enforcers/LimitedCallsEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../enforcers/NativeTokenTransferAmountEnforcer.sol";
import { NativeBalanceGteEnforcer } from "../enforcers/NativeBalanceGteEnforcer.sol";
import { NativeTokenPaymentEnforcer } from "../enforcers/NativeTokenPaymentEnforcer.sol";
import { NonceEnforcer } from "../enforcers/NonceEnforcer.sol";
import { RedeemerEnforcer } from "../enforcers/RedeemerEnforcer.sol";
import { TimestampEnforcer } from "../enforcers/TimestampEnforcer.sol";
import { ValueLteEnforcer } from "../enforcers/ValueLteEnforcer.sol";
import { SwapOfferEnforcer } from "../enforcers/SwapOfferEnforcer.sol";
import { MultiPointOfferEnforcer } from "../enforcers/MultiPointOfferEnforcer.sol";

/**
  @title Caveats
  @notice This library aims to export the easier way to create caveats for tests. Its parameters should always be provided in the easiest creator-readable way, even at the cost of gas.
 */
library Caveats {
    function createAllowedCalldataCaveat(
        address enforcerAddress,
        uint256 dataStart,
        bytes memory expectedValue
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(dataStart, expectedValue);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createERC721TransferCaveat(
        address enforcerAddress,
        address permittedContract,
        uint256 permittedTokenId
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(permittedContract, permittedTokenId);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createRedeemerCaveat(
        address enforcerAddress,
        address[] memory allowedRedeemers
    ) internal pure returns (Caveat memory) {
        bytes memory terms = new bytes(allowedRedeemers.length * 20);
        for (uint256 i = 0; i < allowedRedeemers.length; i++) {
            bytes20 redeemer = bytes20(allowedRedeemers[i]);
            for (uint256 j = 0; j < 20; j++) {
                terms[i * 20 + j] = redeemer[j];
            }
        }
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createValueLteCaveat(
        address enforcerAddress,
        uint256 maxValue
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encode(maxValue);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createNativeAllowanceCaveat(
        address enforcerAddress,
        uint256 allowance
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encode(allowance);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createTimestampCaveat(
        address enforcerAddress,
        uint128 timestampAfterThreshold,
        uint128 timestampBeforeThreshold
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(timestampAfterThreshold, timestampBeforeThreshold);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createNonceCaveat(
        address enforcerAddress,
        uint256 nonce
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encode(nonce);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createIdCaveat(
        address enforcerAddress,
        uint256 id
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encode(id);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createNativeBalanceGteCaveat(
        address enforcerAddress,
        address recipient,
        uint256 minBalanceIncrease
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(recipient, minBalanceIncrease);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createNativeTokenPaymentCaveat(
        address enforcerAddress,
        address recipient,
        uint256 amount
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(recipient, amount);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createLimitedCallsCaveat(
        address enforcerAddress,
        uint256 limit
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encode(limit);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createAllowedMethodsCaveat(
        address enforcerAddress,
        string[] memory approvedMethods
    ) internal pure returns (Caveat memory) {
        bytes memory terms = new bytes(approvedMethods.length * 4);
        uint256 offset = 0;
        
        for (uint256 i = 0; i < approvedMethods.length; i++) {
            bytes4 methodId = bytes4(keccak256(bytes(approvedMethods[i])));
            assembly {
                mstore(add(add(terms, 32), offset), methodId)
            }
            offset += 4;
        }
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }
    function createAllowedTargetsCaveat(
        address enforcerAddress,
        address[] memory allowedTargets
    ) internal pure returns (Caveat memory) {
        bytes memory terms = new bytes(allowedTargets.length * 20);
        
        for (uint256 i = 0; i < allowedTargets.length; i++) {
            bytes20 target = bytes20(allowedTargets[i]);
            for (uint256 j = 0; j < 20; j++) {
                terms[i * 20 + j] = target[j];
            }
        }
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }
    function createArgsEqualityCheckCaveat(
        address enforcerAddress,
        bytes memory expectedArgs
    ) internal pure returns (Caveat memory) {
        return Caveat({
            enforcer: enforcerAddress,
            terms: expectedArgs,
            args: ""
        });
    }

    function createBlockNumberCaveat(
        address enforcerAddress,
        uint128 blockAfterThreshold,
        uint128 blockBeforeThreshold
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(blockAfterThreshold, blockBeforeThreshold);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createDeployedEnforcerCaveat(
        address enforcerAddress,
        address expectedAddress,
        bytes32 salt,
        bytes memory bytecode
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(expectedAddress, salt, bytecode);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createERC20BalanceGteCaveat(
        address enforcerAddress,
        address token,
        uint256 amount
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(token, amount);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createERC20TransferAmountCaveat(
        address enforcerAddress,
        address token,
        uint256 maxAmount
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encodePacked(token, maxAmount);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }
    function createSwapOfferCaveat(
        address enforcerAddress,
        SwapOfferEnforcer.SwapOfferTerms memory swapOfferTerms
    ) internal pure returns (Caveat memory) {
        bytes memory terms = abi.encode(swapOfferTerms);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }

    function createMultiPointOfferCaveat(
        address enforcerAddress,
        address tokenIn,
        address tokenOut,
        MultiPointOfferEnforcer.Amount[] memory amounts,
        address recipient
    ) internal pure returns (Caveat memory) {
        MultiPointOfferEnforcer.SwapOffer memory offer = MultiPointOfferEnforcer.SwapOffer({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amounts: amounts,
            recipient: recipient
        });
        
        bytes memory terms = abi.encode(offer);
        
        return Caveat({
            enforcer: enforcerAddress,
            terms: terms,
            args: ""
        });
    }
}
