import { BASE_CHAIN_ID } from "./constants.js";
import type { SavedDelegation } from "./types.js";

/** Source chain where the delegation is redeemed (saved at create; fallback Base for old files). */
export function savedExecutionChainId(saved: SavedDelegation): number {
  return saved.chainId ?? BASE_CHAIN_ID;
}
