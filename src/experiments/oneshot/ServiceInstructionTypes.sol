// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeCode } from "../../utils/Types.sol";

library ServiceInstructionTypes {
    struct ServiceInstruction {
        bytes32 delegationHash;
        address maker;
        uint256 chainId;
        address manager;
        address enforcer;
        ModeCode mode;
        bytes32 executionHash;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 minBuyAmount;
        address receiver;
        uint256 nonce;
        uint256 issuedAt;
        uint256 expiresAt;
    }

    struct MakerBounds {
        address quoteSigner;
        address sellToken;
        address buyToken;
        address receiver;
        address adapter;
        uint256 maxSellAmount;
        uint256 minBuyAmount;
        uint256 maxQuoteLifetime;
    }

    struct ServiceAttestation {
        ServiceInstruction instruction;
        bytes signature;
    }
}
