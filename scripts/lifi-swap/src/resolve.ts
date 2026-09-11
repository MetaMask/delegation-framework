import { isAddress } from "viem";

import {
  extractTokensForChain,
  fetchChains,
  fetchTokens,
  type LiFiChain,
  type LiFiToken,
} from "./lifiApi.js";

const DEFAULT_CHAIN_TYPES = "EVM,SVM,UTXO,MVM,TVM";

let chainsCache: LiFiChain[] | undefined;

export async function loadAllChains(
  chainTypes = DEFAULT_CHAIN_TYPES,
): Promise<LiFiChain[]> {
  if (chainsCache) return chainsCache;
  const { chains } = await fetchChains({ chainTypes });
  chainsCache = chains;
  return chains;
}

export function clearChainsCache(): void {
  chainsCache = undefined;
}

function normalizeQuery(query: string): string {
  return query.trim().toLowerCase();
}

function chainMatches(chain: LiFiChain, normalized: string): boolean {
  if (String(chain.id) === normalized) return true;
  if (chain.key.toLowerCase() === normalized) return true;
  if (chain.name.toLowerCase() === normalized) return true;
  if (chain.coin.toLowerCase() === normalized) return true;
  if (chain.metamask?.chainName?.toLowerCase() === normalized) return true;
  return false;
}

function scoreChainMatch(chain: LiFiChain, normalized: string): number {
  if (String(chain.id) === normalized) return 100;
  if (chain.key.toLowerCase() === normalized) return 90;
  if (chain.name.toLowerCase() === normalized) return 80;
  if (chain.metamask?.chainName?.toLowerCase() === normalized) return 70;
  if (chain.coin.toLowerCase() === normalized) return 60;
  return 0;
}

export function resolveChain(query: string, chains: LiFiChain[]): LiFiChain {
  const normalized = normalizeQuery(query);
  if (!normalized) {
    throw new Error("Chain query must not be empty");
  }

  const matches = chains.filter((chain) => chainMatches(chain, normalized));
  if (matches.length === 0) {
    throw new Error(
      `No chain matched "${query}". Run \`npm run lifi -- chains\` to list supported chains.`,
    );
  }

  if (matches.length === 1) {
    return matches[0]!;
  }

  const ranked = [...matches].sort((a, b) => {
    const scoreDiff = scoreChainMatch(b, normalized) - scoreChainMatch(a, normalized);
    if (scoreDiff !== 0) return scoreDiff;
    if (a.mainnet !== b.mainnet) return a.mainnet ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  const topScore = scoreChainMatch(ranked[0]!, normalized);
  const topMatches = ranked.filter((c) => scoreChainMatch(c, normalized) === topScore);
  if (topMatches.length === 1) {
    return topMatches[0]!;
  }

  const listing = topMatches
    .map((c) => `  - ${c.name} (key=${c.key}, id=${c.id}, type=${c.chainType ?? "?"})`)
    .join("\n");
  throw new Error(`Ambiguous chain "${query}". Candidates:\n${listing}`);
}

function isLikelyTokenId(query: string): boolean {
  const trimmed = query.trim();
  if (!trimmed) return false;
  if (isAddress(trimmed)) return true;
  if (trimmed.toLowerCase() === "bitcoin") return true;
  if (/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(trimmed)) return true;
  if (/^0x[0-9a-fA-F]+$/.test(trimmed)) return true;
  return false;
}

function tokenScore(token: LiFiToken, normalizedSymbol: string): number {
  let score = 0;
  if (token.symbol.toLowerCase() === normalizedSymbol) score += 50;
  if (token.coinKey?.toLowerCase() === normalizedSymbol) score += 40;
  if (token.name.toLowerCase() === normalizedSymbol) score += 10;
  if (token.verificationStatus === "verified") score += 25;
  const price = token.priceUSD ? Number(token.priceUSD) : 0;
  if (Number.isFinite(price)) score += Math.min(price, 1000) / 100;
  return score;
}

export function resolveToken(
  query: string,
  chain: LiFiChain,
  tokensOnChain: LiFiToken[],
): LiFiToken {
  const trimmed = query.trim();
  if (!trimmed) {
    throw new Error("Token query must not be empty");
  }

  if (isLikelyTokenId(trimmed)) {
    const byAddress = tokensOnChain.find(
      (t) => t.address.toLowerCase() === trimmed.toLowerCase(),
    );
    if (byAddress) return byAddress;

    if (chain.nativeToken && chain.nativeToken.address.toLowerCase() === trimmed.toLowerCase()) {
      return chain.nativeToken;
    }

    return {
      address: trimmed,
      chainId: chain.id,
      symbol: trimmed,
      name: trimmed,
      decimals: chain.nativeToken?.decimals ?? 18,
      coinKey: chain.nativeToken?.coinKey,
    };
  }

  const normalized = normalizeQuery(trimmed);
  const matches = tokensOnChain.filter(
    (t) =>
      t.symbol.toLowerCase() === normalized ||
      t.coinKey?.toLowerCase() === normalized ||
      t.name.toLowerCase() === normalized,
  );

  if (matches.length === 0) {
    if (
      chain.nativeToken &&
      (chain.nativeToken.symbol.toLowerCase() === normalized ||
        chain.nativeToken.coinKey?.toLowerCase() === normalized)
    ) {
      return chain.nativeToken;
    }
    throw new Error(
      `No token matched "${query}" on ${chain.name}. Run \`npm run lifi -- tokens --chain ${chain.name}\`.`,
    );
  }

  const ranked = [...matches].sort((a, b) => tokenScore(b, normalized) - tokenScore(a, normalized));
  const topScore = tokenScore(ranked[0]!, normalized);
  const topMatches = ranked.filter((t) => tokenScore(t, normalized) === topScore);

  if (topMatches.length === 1) {
    return topMatches[0]!;
  }

  const listing = topMatches
    .slice(0, 8)
    .map(
      (t) =>
        `  - ${t.symbol} ${t.address} (${t.name}${t.verificationStatus ? `, ${t.verificationStatus}` : ""})`,
    )
    .join("\n");
  throw new Error(`Ambiguous token "${query}" on ${chain.name}. Candidates:\n${listing}`);
}

export async function loadTokensForChain(chain: LiFiChain): Promise<LiFiToken[]> {
  const response = await fetchTokens({ chains: chain.key });
  const tokens = extractTokensForChain(response, chain.id);
  if (chain.nativeToken) {
    const hasNative = tokens.some(
      (t) => t.address.toLowerCase() === chain.nativeToken!.address.toLowerCase(),
    );
    if (!hasNative) {
      return [chain.nativeToken, ...tokens];
    }
  }
  return tokens;
}

export async function resolveChainByName(query: string): Promise<LiFiChain> {
  const chains = await loadAllChains();
  return resolveChain(query, chains);
}

export async function resolveTokenOnChain(
  query: string,
  chain: LiFiChain,
): Promise<LiFiToken> {
  const tokens = await loadTokensForChain(chain);
  return resolveToken(query, chain, tokens);
}
