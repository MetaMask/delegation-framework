import { flagString, loadCliConfig, parseArgs } from "../config.js";
import { formatChainlinkReport, resolveChainlinkArgs } from "../chainlink.js";
import { createSmartAccountContext } from "../delegations.js";
import { savedExecutionChainId } from "../executionChain.js";
import { loadDelegation } from "../store.js";

export async function runCheckChainlinkCommand(argv: string[]): Promise<void> {
  const { positional, flags } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error("Usage: chainlink check <id> [--reference-round-id <id>]");
  }

  const saved = loadDelegation(id);
  if (!saved.chainlinkTerms) {
    throw new Error(
      `Delegation "${id}" has no chainlinkTerms. Create with: npm run delegation -- create-chainlink`,
    );
  }

  const cli = loadCliConfig();
  const executionChainId = savedExecutionChainId(saved);
  const ctx = await createSmartAccountContext(cli.privateKey, cli.rpcUrl, executionChainId);

  const overrideRaw = flagString(flags, "reference-round-id");
  const overrideRoundId = overrideRaw !== undefined ? BigInt(overrideRaw) : undefined;

  const result = await resolveChainlinkArgs(
    ctx.publicClient,
    saved.chainlinkTerms,
    overrideRoundId,
  );

  console.log(formatChainlinkReport(saved.chainlinkTerms, result));

  if (!result.passed) {
    process.exitCode = 1;
  }
}
