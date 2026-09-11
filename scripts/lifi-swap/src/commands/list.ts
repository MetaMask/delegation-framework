import { listDelegations } from "../store.js";

export async function runListCommand(): Promise<void> {
  const entries = listDelegations();
  if (entries.length === 0) {
    console.log("No saved delegations.");
    return;
  }

  console.log("Saved delegations:\n");
  for (const entry of entries) {
    console.log(`- ${entry.id}`);
    console.log(`  name:            ${entry.name}`);
    console.log(`  createdAt:       ${entry.createdAt}`);
    console.log(`  delegationHash:  ${entry.delegationHash}`);
    console.log(`  periodAmount:    ${entry.periodAmount}`);
    console.log(`  periodDuration:  ${entry.periodDuration}s`);
    if (entry.delegationType) {
      console.log(`  type:            ${entry.delegationType}`);
    }
    if (entry.chainlinkRuleKind) {
      console.log(`  chainlinkRule:   ${entry.chainlinkRuleKind}`);
    }
    console.log("");
  }
}
