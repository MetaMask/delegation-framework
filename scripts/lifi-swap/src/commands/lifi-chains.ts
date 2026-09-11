import { flagBool, flagString, parseArgs } from "../config.js";
import { fetchChains } from "../lifiApi.js";
import { padColumns } from "../format.js";

export async function runLifiChainsCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);
  const chainTypes = flagString(flags, "chain-types") ?? "EVM,SVM,UTXO,MVM,TVM";
  const asJson = flagBool(flags, "json");

  const { chains } = await fetchChains({ chainTypes });

  if (asJson) {
    console.log(JSON.stringify({ chains }, null, 2));
    return;
  }

  const rows: string[][] = [["KEY", "ID", "NAME", "TYPE", "COIN", "MAINNET"]];
  for (const chain of chains.sort((a, b) => a.name.localeCompare(b.name))) {
    rows.push([
      chain.key,
      String(chain.id),
      chain.name,
      chain.chainType ?? "",
      chain.coin,
      chain.mainnet ? "yes" : "no",
    ]);
  }

  console.log(padColumns(rows));
  console.log(`\n${chains.length} chains`);
}
