import { flagBool, flagString, parseArgs } from "../config.js";
import { padColumns } from "../format.js";
import { fetchTools } from "../lifiApi.js";
import { loadAllChains, resolveChain } from "../resolve.js";

function parseChainsList(raw: string | undefined): string[] | undefined {
  if (!raw) return undefined;
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

async function resolveChainsFilter(
  queries: string[] | undefined,
): Promise<string[] | undefined> {
  if (!queries || queries.length === 0) return undefined;
  const allChains = await loadAllChains();
  return queries.map((query) => {
    if (/^\d+$/.test(query)) return query;
    return String(resolveChain(query, allChains).id);
  });
}

export async function runLifiToolsCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);
  const chains = await resolveChainsFilter(parseChainsList(flagString(flags, "chains")));
  const asJson = flagBool(flags, "json");

  const tools = await fetchTools({ chains });

  if (asJson) {
    console.log(JSON.stringify(tools, null, 2));
    return;
  }

  console.log("Bridges:\n");
  const bridgeRows: string[][] = [["KEY", "NAME", "ROUTES"]];
  for (const bridge of tools.bridges.sort((a, b) => a.name.localeCompare(b.name))) {
    bridgeRows.push([
      bridge.key,
      bridge.name,
      String(bridge.supportedChains?.length ?? 0),
    ]);
  }
  console.log(padColumns(bridgeRows));

  console.log("\nExchanges:\n");
  const exchangeRows: string[][] = [["KEY", "NAME", "CHAINS"]];
  for (const exchange of tools.exchanges.sort((a, b) => a.name.localeCompare(b.name))) {
    exchangeRows.push([
      exchange.key,
      exchange.name,
      String(exchange.supportedChains?.length ?? 0),
    ]);
  }
  console.log(padColumns(exchangeRows));

  console.log(`\n${tools.bridges.length} bridges, ${tools.exchanges.length} exchanges`);
}
