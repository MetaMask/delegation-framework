import {
  encodeAbiParameters,
  hashMessage,
  keccak256,
  parseAbiParameters,
  recoverAddress,
  type Address,
  type Hex,
  type PrivateKeyAccount,
} from "viem";

import type { LiFiQuoteResponse } from "./lifiApi.js";
import type { SignedLiFiQuote } from "./types.js";
import { RouteKind } from "./types.js";

function quoteTuple(quote: SignedLiFiQuote) {
  return [
    quote.delegator,
    quote.lifiDiamond,
    quote.inputToken,
    quote.outputAssetId,
    quote.outputRecipient,
    quote.destinationChainId,
    quote.inputAmount,
    quote.expectedAmountOut,
    quote.minAmountOut,
    quote.calldataHash,
    quote.expiration,
  ] as const;
}

export function hashQuote(
  quote: SignedLiFiQuote,
  delegationHash: Hex,
  chainId: number,
): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(address,address,address,bytes32,bytes32,uint256,uint256,uint256,uint256,bytes32,uint256), uint256, bytes32, uint256",
      ),
      [quoteTuple(quote), quote.expiration, delegationHash, BigInt(chainId)],
    ),
  );
}

export async function signQuote(
  account: PrivateKeyAccount,
  quote: SignedLiFiQuote,
  delegationHash: Hex,
  chainId: number,
): Promise<Hex> {
  const digest = hashQuote(quote, delegationHash, chainId);
  return account.signMessage({ message: { raw: digest } });
}

/**
 * Encodes the enforcer `_args` blob: `(RouteKind, SignedLiFiQuote, bytes signature)`.
 * The RouteKind is prepended (not part of the signed hashQuote) so the enforcer can branch on it.
 */
export function encodeQuoteArgs(routeKind: RouteKind, quote: SignedLiFiQuote, signature: Hex): Hex {
  return encodeAbiParameters(
    parseAbiParameters(
      "uint8, (address,address,address,bytes32,bytes32,uint256,uint256,uint256,uint256,bytes32,uint256), bytes",
    ),
    [Number(routeKind), quoteTuple(quote), signature],
  );
}

/**
 * Derives the RouteKind from a LiFi quote response. This is a required encode input (the enforcer needs
 * the enum to pick its decode path); it is NOT a client-side gate that duplicates the enforcer's on-chain
 * checks. Throws only when no RouteKind can encode the route (e.g. an unsupported non-EVM bridge such as
 * Relay, whose BTC recipient is not present in calldata).
 */
export function deriveRouteKind(quote: LiFiQuoteResponse, executionChainId: number): RouteKind {
  const action = quote.action;
  const toChainId = action?.toChainId;
  const fromChainId = action?.fromChainId ?? executionChainId;
  // Same-chain EVM swap.
  if (toChainId != null && toChainId === fromChainId) {
    return RouteKind.SameChain;
  }
  const toToken = action?.toToken;
  const isNonEvm =
    !!toToken && (!toToken.address.startsWith("0x") || BigInt(toToken.chainId) >= 2_000_000_000_000_00);
  if (isNonEvm) {
    const tool = quote.tool ?? "";
    if (tool === "near") return RouteKind.NearBtc;
    if (tool === "layerswap") return RouteKind.LayerSwapBtc;
    throw new Error(`Unsupported non-EVM bridge for recipient enforcement: ${tool || "(unknown)"}`);
  }
  return RouteKind.EvmBridge;
}

export async function verifyQuoteSigner(
  quote: SignedLiFiQuote,
  delegationHash: Hex,
  chainId: number,
  signature: Hex,
  expectedSigner: Address,
): Promise<boolean> {
  const digest = hashQuote(quote, delegationHash, chainId);
  const ethSigned = hashMessage({ raw: digest });
  const recovered = await recoverAddress({ hash: ethSigned, signature });
  return recovered.toLowerCase() === expectedSigner.toLowerCase();
}
