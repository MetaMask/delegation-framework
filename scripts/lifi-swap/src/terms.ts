import { encodePacked, keccak256, padHex, stringToBytes, toHex, type Address, type Hex } from "viem";

import { encodeLiFiBitcoinBytes32, isBitcoinAddress } from "./bitcoinEncoding.js";
import { TERMS_LENGTH } from "./constants.js";
import type { LiFiTermsRecord } from "./types.js";

export function addressToBytes32(address: Address): Hex {
  return padHex(address, { size: 32 });
}

/** LiFi-compatible bytes32 for non-EVM token ids and recipients. */
export function encodeLiFiNonEvmBytes32(value: string): Hex {
  if (isBitcoinAddress(value)) {
    return encodeLiFiBitcoinBytes32(value);
  }
  const bytes = stringToBytes(value);
  if (bytes.length > 32) {
    return keccak256(bytes);
  }
  return padHex(toHex(bytes), { size: 32 });
}

export function encodeLiFiTerms(terms: {
  lifiDiamond: Address;
  inputToken: Address;
  outputAssetId: Hex;
  outputRecipient: Hex;
  destinationChainId: bigint;
  quoteSigner: Address;
  periodAmount: bigint;
  periodDuration: bigint;
  startDate: bigint;
  slippageBps: bigint;
}): Hex {
  const encoded = encodePacked(
    [
      "address",
      "address",
      "bytes32",
      "bytes32",
      "uint256",
      "address",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
    ],
    [
      terms.lifiDiamond,
      terms.inputToken,
      terms.outputAssetId,
      terms.outputRecipient,
      terms.destinationChainId,
      terms.quoteSigner,
      terms.periodAmount,
      terms.periodDuration,
      terms.startDate,
      terms.slippageBps,
    ],
  );

  const byteLength = (encoded.length - 2) / 2;
  if (byteLength !== TERMS_LENGTH) {
    throw new Error(`Invalid terms length: expected ${TERMS_LENGTH}, got ${byteLength}`);
  }

  return encoded;
}

export function termsRecordToEncoded(terms: LiFiTermsRecord): Hex {
  return encodeLiFiTerms({
    lifiDiamond: terms.lifiDiamond,
    inputToken: terms.inputToken,
    outputAssetId: terms.outputAssetId,
    outputRecipient: terms.outputRecipient,
    destinationChainId: BigInt(terms.destinationChainId),
    quoteSigner: terms.quoteSigner,
    periodAmount: BigInt(terms.periodAmount),
    periodDuration: BigInt(terms.periodDuration),
    startDate: BigInt(terms.startDate),
    slippageBps: BigInt(terms.slippageBps),
  });
}

export function hashCalldata(callData: Hex): Hex {
  return keccak256(callData);
}

export function minAmountOutMeetsSlippage(
  minAmountOut: bigint,
  expectedAmountOut: bigint,
  slippageBps: bigint,
): boolean {
  if (expectedAmountOut === 0n) return false;
  const minimumAllowed = (expectedAmountOut * (10_000n - slippageBps)) / 10_000n;
  return minAmountOut >= minimumAllowed;
}
