import { getAddress, isAddress } from "viem";

import { flagString } from "./config.js";
import { savedExecutionChainId } from "./executionChain.js";
import type { LiFiChain } from "./lifiApi.js";
import {
  loadAllChains,
  loadTokensForChain,
  resolveChain,
  resolveToken,
} from "./resolve.js";
import type { SavedDelegation } from "./types.js";

export type QuoteFetchOverrides = {
  toChain: number;
  toToken: string;
  toAddress: string;
  spoofed: boolean;
  spoofSummary: string;
  expectedRevertHints: string[];
};

type Flags = Record<string, string | boolean>;

function isEvmChain(chain: LiFiChain): boolean {
  return (chain.chainType ?? "EVM").toUpperCase() === "EVM";
}

function formatTermsRecipient(saved: SavedDelegation): string {
  if (saved.metadata?.outputRecipient) {
    return saved.metadata.outputRecipient;
  }
  const hex = saved.terms.outputRecipient;
  const padding = hex.slice(2, 26);
  if (/^0+$/.test(padding)) {
    return getAddress(`0x${hex.slice(-40)}`);
  }
  return hex;
}

function validateSpoofAddress(address: string, chain: LiFiChain): void {
  if (!address.trim()) {
    throw new Error("--spoof-output-address must not be empty");
  }
  if (isEvmChain(chain) && address.startsWith("0x") && !isAddress(address)) {
    throw new Error(`Invalid EVM --spoof-output-address: ${address}`);
  }
}

function buildExpectedRevertHints(params: {
  termsDestChain: number;
  fetchDestChain: number;
  executionChainId: number;
  termsRecipient: string;
  fetchRecipient: string;
  termsToToken: string;
  fetchToToken: string;
}): string[] {
  const hints: string[] = [];
  const termsSameChain = params.termsDestChain === params.executionChainId;
  const fetchSameChain = params.fetchDestChain === params.executionChainId;

  if (params.fetchRecipient.toLowerCase() !== params.termsRecipient.toLowerCase()) {
    hints.push("LiFiSwapEnforcer:calldata-recipient-mismatch");
  }
  if (params.fetchDestChain !== params.termsDestChain) {
    if (termsSameChain && !fetchSameChain) {
      hints.push("LiFiSwapEnforcer:route-dest-chain-mismatch");
    } else {
      hints.push("LiFiSwapEnforcer:calldata-dest-chain-mismatch");
      hints.push("LiFiSwapEnforcer:route-dest-chain-mismatch");
    }
  }
  if (params.fetchToToken.toLowerCase() !== params.termsToToken.toLowerCase()) {
    hints.push("(output token differs — calldata may encode a different asset)");
  }
  if (hints.length === 0) {
    hints.push("(no obvious mismatch — verify spoof flags)");
  }
  return hints;
}

async function resolveSpoofChain(
  query: string,
  chains: LiFiChain[],
): Promise<LiFiChain> {
  return resolveChain(query, chains);
}

async function resolveSpoofToken(
  query: string | undefined,
  chain: LiFiChain,
  saved: SavedDelegation,
  termsDestChain: number,
  spoofDestChain: number,
): Promise<string> {
  if (query) {
    const tokens = await loadTokensForChain(chain);
    return resolveToken(query, chain, tokens).address;
  }
  if (spoofDestChain !== termsDestChain) {
    const symbol = saved.metadata?.outputSymbol;
    if (!symbol) {
      throw new Error(
        "Spoofing output chain requires --spoof-output-token or saved metadata.outputSymbol " +
          "(recreate delegation with route flags to populate metadata).",
      );
    }
    const tokens = await loadTokensForChain(chain);
    return resolveToken(symbol, chain, tokens).address;
  }
  return saved.toToken;
}

export async function resolveExecuteSpoofParams(
  flags: Flags,
  saved: SavedDelegation,
  defaultToAddress: string,
): Promise<QuoteFetchOverrides> {
  const termsDestChain = Number(saved.terms.destinationChainId);
  const executionChainId = savedExecutionChainId(saved);
  const termsRecipient = formatTermsRecipient(saved);

  let toChain = termsDestChain;
  let toToken = saved.toToken;
  let toAddress = defaultToAddress;

  const spoofChainQuery = flagString(flags, "spoof-output-chain");
  const spoofAddress = flagString(flags, "spoof-output-address");
  const spoofTokenQuery = flagString(flags, "spoof-output-token");

  const spoofed = !!(spoofChainQuery || spoofAddress || spoofTokenQuery);
  if (!spoofed) {
    return {
      toChain,
      toToken,
      toAddress,
      spoofed: false,
      spoofSummary: "",
      expectedRevertHints: [],
    };
  }

  const chains = await loadAllChains();
  let outputChain: LiFiChain | undefined;
  if (spoofChainQuery) {
    outputChain = await resolveSpoofChain(spoofChainQuery, chains);
    toChain = outputChain.id;
  }

  toToken = await resolveSpoofToken(
    spoofTokenQuery,
    outputChain ??
      chains.find((c) => c.id === toChain) ??
      (await resolveSpoofChain(String(toChain), chains)),
    saved,
    termsDestChain,
    toChain,
  );

  if (spoofAddress) {
    const chainForValidation =
      outputChain ??
      chains.find((c) => c.id === toChain) ??
      (await resolveSpoofChain(String(toChain), chains));
    validateSpoofAddress(spoofAddress, chainForValidation);
    toAddress = spoofAddress;
  }

  const termsChainLabel =
    saved.metadata?.outputChain ?? String(termsDestChain);
  const fetchChainLabel =
    outputChain?.name ?? chains.find((c) => c.id === toChain)?.name ?? String(toChain);

  const spoofSummary = [
    "Terms (signed quote metadata — unchanged):",
    `  destinationChainId: ${termsDestChain} (${termsChainLabel})`,
    `  outputRecipient:    ${termsRecipient}`,
    `  toToken:            ${saved.toToken}`,
    "LiFi quote fetch (spoofed — calldata source):",
    `  toChain:            ${toChain} (${fetchChainLabel})`,
    `  toAddress:          ${toAddress}`,
    `  toToken:            ${toToken}`,
  ].join("\n");

  const expectedRevertHints = buildExpectedRevertHints({
    termsDestChain,
    fetchDestChain: toChain,
    executionChainId,
    termsRecipient,
    fetchRecipient: toAddress,
    termsToToken: saved.toToken,
    fetchToToken: toToken,
  });

  return {
    toChain,
    toToken,
    toAddress,
    spoofed: true,
    spoofSummary,
    expectedRevertHints,
  };
}
