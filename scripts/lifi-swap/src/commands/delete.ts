import { flagBool, parseArgs } from "../config.js";
import { deleteAllDelegations, deleteDelegation } from "../store.js";

export async function runDeleteCommand(argv: string[]): Promise<void> {
  const { positional, flags } = parseArgs(argv);

  if (flagBool(flags, "all")) {
    const removed = deleteAllDelegations();
    console.log(`Deleted ${removed} saved delegation(s).`);
    return;
  }

  const id = positional[0];
  if (!id) {
    throw new Error("Usage: delegation delete <id> | delegation delete --all");
  }

  deleteDelegation(id);
  console.log(`Deleted delegation "${id}".`);
}
