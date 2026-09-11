import type { Delegation } from "@metamask/smart-accounts-kit";
import { encodeSingleExecution } from "@metamask/smart-accounts-kit/utils";
import { bytesToHex } from "viem/utils";
import type { Hex } from "viem";

import { CHAINLINK_PRICE_RULE_ENFORCER, LIFI_SWAP_ENFORCER } from "./constants.js";

export { encodeSingleExecution };

export function toRelayerJson(value: unknown): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === "bigint") return `0x${value.toString(16)}`;
  if (value instanceof Uint8Array) return bytesToHex(value);
  if (Array.isArray(value)) return value.map(toRelayerJson);
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
      out[key] = toRelayerJson(entry);
    }
    return out;
  }
  return value;
}

export function patchCaveatArgs(
  delegation: Delegation,
  enforcerAddress: string,
  args: Hex,
): Delegation {
  const normalized = enforcerAddress.toLowerCase();
  const caveats = delegation.caveats.map((caveat) => {
    if (caveat.enforcer.toLowerCase() !== normalized) {
      return caveat;
    }
    return { ...caveat, args };
  });

  const hasCaveat = caveats.some(
    (c) => c.enforcer.toLowerCase() === normalized,
  );
  if (!hasCaveat) {
    throw new Error(`Saved delegation is missing enforcer caveat: ${enforcerAddress}`);
  }

  return { ...delegation, caveats };
}

export function patchChainlinkArgs(delegation: Delegation, args: Hex): Delegation {
  return patchCaveatArgs(delegation, CHAINLINK_PRICE_RULE_ENFORCER, args);
}

export function patchSwapDelegationArgs(
  delegation: Delegation,
  args: Hex,
): Delegation {
  return patchCaveatArgs(delegation, LIFI_SWAP_ENFORCER, args);
}

export function relayerExecution(target: Hex, value: bigint, data: Hex) {
  return {
    target,
    value: value.toString(),
    data,
  };
}
