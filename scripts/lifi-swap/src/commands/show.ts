import { parseArgs } from "../config.js";
import {
  createSmartAccountContext,
  readAvailableBudget,
} from "../delegations.js";
import { loadDelegation } from "../store.js";
import { termsRecordToEncoded } from "../terms.js";

export async function runShowCommand(argv: string[]): Promise<void> {
  const { positional } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error("Usage: delegation show <id>");
  }

  const saved = loadDelegation(id);
  const { loadCliConfig } = await import("../config.js");
  const { savedExecutionChainId } = await import("../executionChain.js");
  const cli = loadCliConfig();
  const executionChainId = savedExecutionChainId(saved);
  const ctx = await createSmartAccountContext(cli.privateKey, cli.rpcUrl, executionChainId);

  if (ctx.account.address.toLowerCase() !== saved.terms.quoteSigner.toLowerCase()) {
    throw new Error("PRIVATE_KEY does not match saved quoteSigner");
  }

  const termsBytes = termsRecordToEncoded(saved.terms);
  const budget = await readAvailableBudget(ctx, saved.delegationHash, termsBytes);

  console.log(JSON.stringify(saved, null, 2));

  if (saved.chainlinkTerms) {
    const { termsRecordToEncoded } = await import("../chainlinkTerms.js");
    console.log("\nChainlink terms:");
    console.log(`  ruleKind:         ${saved.chainlinkTerms.ruleKind}`);
    console.log(`  priceFeed:        ${saved.chainlinkTerms.priceFeed}`);
    console.log(`  windowSeconds:    ${saved.chainlinkTerms.windowSeconds}`);
    console.log(`  thresholdBps:     ${saved.chainlinkTerms.thresholdBps}`);
    console.log(`  triggerPrice:     ${saved.chainlinkTerms.triggerPrice}`);
    console.log(`  maxStaleSeconds:  ${saved.chainlinkTerms.maxStaleSeconds}`);
    console.log(`  minGapSeconds:    ${saved.chainlinkTerms.minGapSeconds}`);
    console.log(`  expectedDecimals: ${saved.chainlinkTerms.expectedDecimals}`);
    console.log(`  termsBytes:       ${termsRecordToEncoded(saved.chainlinkTerms)}`);
  }

  console.log("\nOn-chain budget:");
  console.log(`  availableAmount:  ${budget.available.toString()}`);
  console.log(`  isNewPeriod:      ${budget.isNewPeriod}`);
  console.log(`  currentPeriod:    ${budget.currentPeriod.toString()}`);
}
