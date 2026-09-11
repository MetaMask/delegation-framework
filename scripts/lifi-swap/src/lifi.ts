import { getAddress, isAddress, type Address, type Hex } from "viem";

import { savedExecutionChainId } from "./executionChain.js";
import {
  fetchQuote,
  type LiFiChain,
  type LiFiExecutableQuote,
  type LiFiQuoteResponse,
} from "./lifiApi.js";
import { addressToBytes32, encodeLiFiNonEvmBytes32 } from "./terms.js";
import type { SavedDelegation } from "./types.js";

export type { LiFiExecutableQuote, LiFiQuoteResponse } from "./lifiApi.js";

export function isEvmSameChainDest(toChain: number, sourceChain: number): boolean {
  return toChain === sourceChain;
}

export function isEvmLiFiChain(chain: LiFiChain): boolean {
  return (chain.chainType ?? "EVM").toUpperCase() === "EVM";
}

/** Padded EVM bytes32 for output asset + recipient (same-chain and cross-chain EVM). */
export function encodeEvmTermsFields(
  toToken: string,
  outputRecipient: string,
): { outputAssetId: Hex; outputRecipient: Hex } {
  if (!isAddress(toToken)) {
    throw new Error(`Output token must be an EVM address: ${toToken}`);
  }
  if (!isAddress(outputRecipient)) {
    throw new Error(`Output recipient must be an EVM address: ${outputRecipient}`);
  }
  return {
    outputAssetId: addressToBytes32(getAddress(toToken)),
    outputRecipient: addressToBytes32(getAddress(outputRecipient)),
  };
}

function isCrossChainEvmRoute(params: {
  toChain: number;
  sourceChain: number;
  outputChain?: LiFiChain;
  outputRecipient: string;
  toToken: string;
}): boolean {
  if (isEvmSameChainDest(params.toChain, params.sourceChain)) {
    return false;
  }
  if (!params.outputChain || !isEvmLiFiChain(params.outputChain)) {
    return false;
  }
  if (!isAddress(params.outputRecipient)) {
    return false;
  }
  if (!isAddress(params.toToken)) {
    throw new Error(
      `Cross-chain EVM route requires an EVM output token address on ${params.outputChain.name}: ${params.toToken}`,
    );
  }
  return true;
}

export function resolveTermsEncodings(params: {
  toChain: number;
  sourceChain: number;
  toToken: string;
  outputRecipient: string;
  outputChain?: LiFiChain;
  outputAssetIdOverride?: Hex;
  outputRecipientBytes32Override?: Hex;
}): { outputAssetId: Hex; outputRecipient: Hex } {
  if (
    isEvmSameChainDest(params.toChain, params.sourceChain) ||
    isCrossChainEvmRoute(params)
  ) {
    return encodeEvmTermsFields(params.toToken, params.outputRecipient);
  }

  if (
    params.outputChain &&
    isEvmLiFiChain(params.outputChain) &&
    !isAddress(params.outputRecipient)
  ) {
    throw new Error(
      `Cross-chain route to EVM chain ${params.outputChain.name} requires a 0x output recipient; ` +
        `got non-EVM address "${params.outputRecipient}".`,
    );
  }

  return {
    outputAssetId:
      params.outputAssetIdOverride ?? encodeLiFiNonEvmBytes32(params.toToken),
    outputRecipient:
      params.outputRecipientBytes32Override ??
      encodeLiFiNonEvmBytes32(params.outputRecipient),
  };
}

export function resolveQuoteToAddress(saved: SavedDelegation, delegator: Address): string {
  if (saved.metadata?.outputRecipient) {
    return saved.metadata.outputRecipient;
  }
  if (
    isEvmSameChainDest(
      Number(saved.terms.destinationChainId),
      savedExecutionChainId(saved),
    )
  ) {
    return delegator;
  }
  throw new Error(
    "Missing output recipient in saved delegation metadata; recreate with --output-recipient or LIFI_OUTPUT_RECIPIENT",
  );
}

export async function fetchLiFiQuote(params: {
  fromChain: number;
  toChain: number;
  fromToken: string;
  toToken: string;
  fromAmount: bigint;
  fromAddress: Address;
  slippage: number;
  toAddress?: string;
  allowBridges?: string[];
  denyBridges?: string[];
}): Promise<LiFiExecutableQuote> {
  const quote = await fetchQuote({
    fromChain: params.fromChain,
    toChain: params.toChain,
    fromToken: params.fromToken,
    toToken: params.toToken,
    fromAmount: params.fromAmount,
    fromAddress: params.fromAddress,
    slippage: params.slippage,
    toAddress: params.toAddress,
    allowBridges: params.allowBridges,
    denyBridges: params.denyBridges,
  });

  if (!quote.transactionRequest) {
    throw new Error("LiFi quote missing transactionRequest");
  }
  if (!quote.estimate) {
    throw new Error("LiFi quote missing estimate");
  }

  return quote as LiFiExecutableQuote;
}

export function parseQuoteAmounts(quote: LiFiExecutableQuote): {
  expectedAmountOut: bigint;
  minAmountOut: bigint;
} {
  return {
    expectedAmountOut: BigInt(quote.estimate.toAmount),
    minAmountOut: BigInt(quote.estimate.toAmountMin),
  };
}

export function assertQuoteValueZero(quote: LiFiExecutableQuote): void {
  const value = BigInt(quote.transactionRequest.value);
  if (value !== 0n) {
    throw new Error("LiFi quote requires msg.value > 0; LiFiSwapEnforcer v1 only supports value=0");
  }
}

export function assertQuoteDiamond(quote: LiFiExecutableQuote, expectedDiamond: Address): void {
  const actual = getAddress(quote.transactionRequest.to);
  if (actual.toLowerCase() !== expectedDiamond.toLowerCase()) {
    throw new Error(`LiFi diamond mismatch: quote=${actual}, terms=${expectedDiamond}`);
  }
}
