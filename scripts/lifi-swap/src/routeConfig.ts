import { getAddress, isAddress, type Address } from "viem";

import { BASE_CHAIN_ID } from "./constants.js";
import { flagString } from "./config.js";
import type { LiFiChain, LiFiToken } from "./lifiApi.js";
import {
  loadAllChains,
  loadTokensForChain,
  resolveChain,
  resolveToken,
} from "./resolve.js";

export type ResolvedRoute = {
  inputChain: LiFiChain;
  outputChain: LiFiChain;
  inputToken: LiFiToken;
  outputToken: LiFiToken;
  fromChainId: number;
  toChainId: number;
  /** LiFi API token address/id string */
  fromToken: string;
  toToken: string;
};

type Flags = Record<string, string | boolean>;

function hasRouteFlags(flags: Flags): boolean {
  return (
    flagString(flags, "input-chain") !== undefined ||
    flagString(flags, "input-token") !== undefined ||
    flagString(flags, "output-chain") !== undefined ||
    flagString(flags, "output-token") !== undefined
  );
}

function requireRouteFlag(flags: Flags, key: string): string {
  const value = flagString(flags, key);
  if (!value) {
    throw new Error(
      `Missing --${key}. Provide all route flags: --input-chain, --input-token, --output-chain, --output-token`,
    );
  }
  return value;
}

/** Resolve human-readable chain/token flags (same UX as `lifi quote`). */
export async function resolveRouteFromFlags(flags: Flags): Promise<ResolvedRoute> {
  const inputChainQuery = requireRouteFlag(flags, "input-chain");
  const outputChainQuery = requireRouteFlag(flags, "output-chain");
  const inputTokenQuery = requireRouteFlag(flags, "input-token");
  const outputTokenQuery = requireRouteFlag(flags, "output-token");

  const chains = await loadAllChains();
  const inputChain = resolveChain(inputChainQuery, chains);
  const outputChain = resolveChain(outputChainQuery, chains);

  const inputTokens = await loadTokensForChain(inputChain);
  const outputTokens = await loadTokensForChain(outputChain);
  const inputToken = resolveToken(inputTokenQuery, inputChain, inputTokens);
  const outputToken = resolveToken(outputTokenQuery, outputChain, outputTokens);

  return {
    inputChain,
    outputChain,
    inputToken,
    outputToken,
    fromChainId: inputChain.id,
    toChainId: outputChain.id,
    fromToken: inputToken.address,
    toToken: outputToken.address,
  };
}

/** Legacy path: LIFI_FROM_TOKEN / LIFI_TO_TOKEN / LIFI_TO_CHAIN from .env (input chain = Base). */
export async function resolveRouteFromEnv(): Promise<ResolvedRoute> {
  const fromTokenRaw = process.env.LIFI_FROM_TOKEN;
  const toTokenRaw = process.env.LIFI_TO_TOKEN;
  if (!fromTokenRaw || !toTokenRaw) {
    throw new Error(
      "Provide route flags (--input-chain, --input-token, --output-chain, --output-token) " +
        "or set LIFI_FROM_TOKEN and LIFI_TO_TOKEN in .env",
    );
  }

  const toChainId = Number(process.env.LIFI_TO_CHAIN ?? BASE_CHAIN_ID);
  const chains = await loadAllChains();
  const inputChain = resolveChain(String(BASE_CHAIN_ID), chains);
  const outputChain =
    chains.find((c) => c.id === toChainId) ??
    resolveChain(String(toChainId), chains);

  const inputTokens = await loadTokensForChain(inputChain);
  const outputTokens = await loadTokensForChain(outputChain);
  const inputToken = resolveToken(fromTokenRaw, inputChain, inputTokens);
  const outputToken = resolveToken(toTokenRaw, outputChain, outputTokens);

  return {
    inputChain,
    outputChain,
    inputToken,
    outputToken,
    fromChainId: inputChain.id,
    toChainId: outputChain.id,
    fromToken: inputToken.address,
    toToken: outputToken.address,
  };
}

/** Flags-first route resolution with legacy .env fallback. */
export async function resolveCreateRoute(flags: Flags): Promise<ResolvedRoute> {
  if (hasRouteFlags(flags)) {
    return resolveRouteFromFlags(flags);
  }
  return resolveRouteFromEnv();
}

/** EVM input token address for enforcer terms (native → zero address). */
export function inputTokenAsAddress(token: LiFiToken): Address {
  if (!isAddress(token.address)) {
    throw new Error(
      `Input token "${token.symbol}" (${token.address}) is not an EVM address; ` +
        "source-chain input must be an EVM token for LiFiSwapEnforcer.",
    );
  }
  return getAddress(token.address);
}

export function formatResolvedRoute(route: ResolvedRoute): string {
  return [
    `Resolved input:  ${route.inputToken.symbol} @ ${route.fromToken} (chain ${route.fromChainId} ${route.inputChain.name})`,
    `Resolved output: ${route.outputToken.symbol} @ ${route.toToken} (chain ${route.toChainId} ${route.outputChain.name})`,
  ].join("\n");
}

/** LiFi diamond on the source (execution) chain — from chains API or optional override. */
export function resolveLiFiDiamond(inputChain: LiFiChain, override?: Address): Address {
  if (override) {
    return getAddress(override);
  }
  const raw = inputChain.diamondAddress;
  if (!raw || !isAddress(raw)) {
    throw new Error(
      `LiFi diamond not available for ${inputChain.name} (id ${inputChain.id}). ` +
        "Pass --lifi-diamond or set LIFI_DIAMOND in .env. " +
        "Run `npm run lifi -- chains` to verify chain metadata.",
    );
  }
  return getAddress(raw);
}

export function resolveOutputRecipient(
  route: ResolvedRoute,
  delegator: Address,
  flags: Flags,
  outputRecipientEnv?: string,
): string {
  const explicit =
    flagString(flags, "output-address") ??
    flagString(flags, "output-recipient") ??
    outputRecipientEnv;
  if (explicit) return explicit;
  if (route.fromChainId === route.toChainId) return delegator;
  throw new Error(
    "Cross-chain create requires --output-address (destination recipient). " +
      "Same-chain swaps default to the delegator smart account.",
  );
}
