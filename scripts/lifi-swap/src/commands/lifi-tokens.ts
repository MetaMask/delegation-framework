import { flagBool, flagString, parseArgs } from "../config.js";
import { padColumns } from "../format.js";
import { extractTokensForChain, fetchTokens } from "../lifiApi.js";
import { loadAllChains, loadTokensForChain, resolveChain } from "../resolve.js";

export async function runLifiTokensCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);
  const chainQuery = flagString(flags, "chain");
  if (!chainQuery) {
    throw new Error("Usage: lifi tokens --chain <name|key|id> [--tags stablecoin] [--symbol USDC] [--json]");
  }

  const tags = flagString(flags, "tags");
  const symbolFilter = flagString(flags, "symbol");
  const asJson = flagBool(flags, "json");

  const chains = await loadAllChains();
  const chain = resolveChain(chainQuery, chains);

  let tokens = tags
    ? extractTokensForChain(await fetchTokens({ chains: chain.key, tags }), chain.id)
    : await loadTokensForChain(chain);

  if (symbolFilter) {
    const normalized = symbolFilter.trim().toLowerCase();
    const exact = tokens.filter(
      (t) =>
        t.symbol.toLowerCase() === normalized ||
        t.coinKey?.toLowerCase() === normalized,
    );
    tokens =
      exact.length > 0
        ? exact
        : tokens.filter(
            (t) =>
              t.symbol.toLowerCase().includes(normalized) ||
              t.coinKey?.toLowerCase().includes(normalized) ||
              t.name.toLowerCase().includes(normalized),
          );
  }

  tokens.sort((a, b) => a.symbol.localeCompare(b.symbol));

  if (asJson) {
    console.log(JSON.stringify({ chain, tokens }, null, 2));
    return;
  }

  const rows: string[][] = [["SYMBOL", "ADDRESS", "DECIMALS", "COINKEY", "PRICE_USD", "VERIFIED"]];
  for (const token of tokens) {
    rows.push([
      token.symbol,
      token.address,
      String(token.decimals),
      token.coinKey ?? "",
      token.priceUSD ?? "",
      token.verificationStatus ?? "",
    ]);
  }

  console.log(`${chain.name} (${chain.key}, id=${chain.id})\n`);
  console.log(padColumns(rows));
  console.log(`\n${tokens.length} tokens`);
}
