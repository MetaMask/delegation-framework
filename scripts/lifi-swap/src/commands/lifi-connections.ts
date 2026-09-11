import { flagBool, flagString, parseArgs, parseCommaList } from "../config.js";
import { fetchConnections } from "../lifiApi.js";
import {
  loadAllChains,
  loadTokensForChain,
  resolveChain,
  resolveToken,
} from "../resolve.js";

export async function runLifiConnectionsCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);
  const fromChainQuery = flagString(flags, "from-chain");
  const toChainQuery = flagString(flags, "to-chain");
  if (!fromChainQuery || !toChainQuery) {
    throw new Error(
      "Usage: lifi connections --from-chain <name> --to-chain <name> [--from-token USDC] [--to-token BTC] [--json]",
    );
  }

  const asJson = flagBool(flags, "json");
  const fromTokenQuery = flagString(flags, "from-token");
  const toTokenQuery = flagString(flags, "to-token");

  const chains = await loadAllChains();
  const fromChain = resolveChain(fromChainQuery, chains);
  const toChain = resolveChain(toChainQuery, chains);

  let fromTokenParam: string | undefined;
  let toTokenParam: string | undefined;

  if (fromTokenQuery) {
    const fromTokens = await loadTokensForChain(fromChain);
    fromTokenParam = resolveToken(fromTokenQuery, fromChain, fromTokens).address;
  }
  if (toTokenQuery) {
    const toTokens = await loadTokensForChain(toChain);
    toTokenParam = resolveToken(toTokenQuery, toChain, toTokens).address;
  }

  const { connections } = await fetchConnections({
    fromChain: fromChain.key,
    toChain: toChain.key,
    fromToken: fromTokenParam,
    toToken: toTokenParam,
    allowBridges: parseCommaList(flagString(flags, "allow-bridges")),
    denyBridges: parseCommaList(flagString(flags, "deny-bridges")),
    preferBridges: parseCommaList(flagString(flags, "prefer-bridges")),
    allowExchanges: parseCommaList(flagString(flags, "allow-exchanges")),
    denyExchanges: parseCommaList(flagString(flags, "deny-exchanges")),
    preferExchanges: parseCommaList(flagString(flags, "prefer-exchanges")),
  });

  if (asJson) {
    console.log(JSON.stringify({ fromChain, toChain, connections }, null, 2));
    return;
  }

  console.log(`${fromChain.name} → ${toChain.name}: ${connections.length} connection(s)\n`);

  for (const connection of connections.slice(0, 20)) {
    console.log(
      `fromChainId=${connection.fromChainId} toChainId=${connection.toChainId} fromTokens=${connection.fromTokens.length} toTokens=${connection.toTokens.length}`,
    );
    const fromSample = connection.fromTokens.slice(0, 3).map((t) => t.address).join(", ");
    const toSample = connection.toTokens.slice(0, 3).map((t) => t.address).join(", ");
    console.log(`  from: ${fromSample}${connection.fromTokens.length > 3 ? ", ..." : ""}`);
    console.log(`  to:   ${toSample}${connection.toTokens.length > 3 ? ", ..." : ""}`);
    console.log("");
  }

  if (connections.length > 20) {
    console.log(`... and ${connections.length - 20} more (use --json for full output)`);
  }
}
