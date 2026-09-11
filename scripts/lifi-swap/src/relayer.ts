import { bytesToHex } from "viem/utils";
import type { Address, Hex } from "viem";
import type { Delegation } from "@metamask/smart-accounts-kit";

import { DEFAULT_RELAYER_URL } from "./constants.js";
import { toRelayerJson } from "./encodings.js";
import type { SavedDelegation } from "./types.js";

export type JsonRpc<T> =
  | { jsonrpc: "2.0"; id: number | string; result: T }
  | { jsonrpc: "2.0"; id: number | string; error: { code: number; message: string; data?: unknown } };

export type ChainCapabilities = {
  feeCollector: Hex;
  targetAddress: Hex;
  tokens: { address: Hex; symbol?: string; decimals: number | string }[];
};

export type Estimate7710Result = {
  success: boolean;
  paymentTokenAddress?: Hex;
  paymentChain?: number;
  gasUsed: Record<string, string>;
  requiredPaymentAmount?: string;
  context?: string;
  contextByChainId?: Record<string, string>;
  error?: string;
};

export type RelayerExecution = {
  target: Hex;
  value: string;
  data: Hex;
};

export type Send7710Params = {
  chainId: string;
  transactions: Array<{
    permissionContext: unknown[];
    executions: RelayerExecution[];
  }>;
  authorizationList?: unknown[];
  context?: string;
  memo?: string;
};

export async function rpc<T>(
  method: string,
  params: unknown,
  relayerUrl: string = DEFAULT_RELAYER_URL,
  id: number = 1,
): Promise<T> {
  const response = await fetch(relayerUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
  });

  const json = (await response.json()) as JsonRpc<T>;
  if (!response.ok) {
    throw new Error(`Relayer HTTP ${response.status}: ${JSON.stringify(json)}`);
  }
  if ("error" in json) {
    throw new Error(`[${json.error.code}] ${json.error.message} ${JSON.stringify(json.error.data ?? "")}`);
  }
  return json.result;
}

export type FeeDataResult = {
  chainId: string;
  token: { address: Hex; decimals: number; symbol?: string; name?: string };
  rate: number;
  minFee: string;
  expiry: number;
  gasPrice: Hex;
  feeCollector: Hex;
  targetAddress?: Hex;
  context?: string;
};

export async function getChainCapabilities(
  chainId: number,
  relayerUrl: string,
): Promise<ChainCapabilities> {
  const caps = await getCapabilities(chainId, relayerUrl);
  const chainCaps = caps[String(chainId)];
  if (!chainCaps) {
    throw new Error(`Relayer capabilities missing for chain ${chainId}`);
  }
  return chainCaps;
}

export async function getFeeData(
  chainId: number,
  token: Hex,
  relayerUrl: string,
): Promise<FeeDataResult> {
  return rpc<FeeDataResult>("relayer_getFeeData", { chainId: String(chainId), token }, relayerUrl);
}

export function assertDelegationTarget(
  delegation: Delegation,
  targetAddress: Address,
  label: string,
  delegationId: string,
): void {
  if (delegation.delegate.toLowerCase() !== targetAddress.toLowerCase()) {
    throw new Error(
      `${label} delegate (${delegation.delegate}) does not match relayer targetAddress (${targetAddress}). ` +
        `Recreate: npm run delegation -- create --id ${delegationId} --force`,
    );
  }
}

export function assertSavedRelayerTarget(
  saved: SavedDelegation,
  targetAddress: Address,
): void {
  const savedTarget =
    saved.relayerTargetAddress ?? (saved.swapDelegation.delegate as Address);
  if (savedTarget.toLowerCase() !== targetAddress.toLowerCase()) {
    throw new Error(
      `Relayer targetAddress changed (saved=${savedTarget}, current=${targetAddress}). ` +
        `Recreate: npm run delegation -- create --id ${saved.id} --force`,
    );
  }
  assertDelegationTarget(saved.swapDelegation, targetAddress, "Swap delegation", saved.id);
  if (saved.approveDelegation) {
    assertDelegationTarget(saved.approveDelegation, targetAddress, "Approve delegation", saved.id);
  }
}

export async function getCapabilities(
  chainId: number,
  relayerUrl: string,
): Promise<Record<string, ChainCapabilities>> {
  return rpc("relayer_getCapabilities", [String(chainId)], relayerUrl);
}

export async function estimate7710Transaction(
  params: Send7710Params,
  relayerUrl: string,
): Promise<Estimate7710Result> {
  return rpc<Estimate7710Result>("relayer_estimate7710Transaction", params, relayerUrl, 0);
}

export async function send7710Transaction(
  params: Send7710Params,
  relayerUrl: string,
): Promise<Hex> {
  return rpc<Hex>("relayer_send7710Transaction", params, relayerUrl);
}

export async function getRelayerStatus(
  taskId: Hex,
  relayerUrl: string,
  logs = true,
): Promise<{
  status: number;
  hash?: Hex;
  message?: string;
  receipt?: unknown;
}> {
  return rpc("relayer_getStatus", { id: taskId, logs }, relayerUrl);
}

export async function pollUntilTerminal(
  taskId: Hex,
  relayerUrl: string,
  timeoutMs = 5 * 60_000,
): Promise<{ ok: boolean; hash?: Hex; reason?: string; receipt?: unknown }> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await getRelayerStatus(taskId, relayerUrl);
    if (result.status === 200) {
      return { ok: true, hash: result.hash, receipt: result.receipt };
    }
    if (result.status === 400) {
      return { ok: false, reason: result.message };
    }
    if (result.status === 500) {
      return { ok: false, reason: "reverted", receipt: result.receipt };
    }
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  throw new Error(`Timeout waiting for relayer task ${taskId}`);
}

export function serializeDelegations(delegations: Delegation[]): unknown[] {
  return delegations.map((d) => toRelayerJson(d));
}

export function findUsdcToken(caps: ChainCapabilities) {
  const token = caps.tokens.find((t) => t.symbol?.toUpperCase() === "USDC");
  if (!token) {
    throw new Error("USDC payment token not found in relayer capabilities");
  }
  return token;
}

export { toRelayerJson };
