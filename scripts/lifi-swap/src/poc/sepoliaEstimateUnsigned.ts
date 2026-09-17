/**
 * Temporary probe: POST relayer_estimate7710Transaction twice on Sepolia
 * (signed vs bytes32(0) placeholder signature) against the 1Shot dev relayer.
 *
 *   cd scripts/lifi-swap && npx tsx src/poc/sepoliaEstimateUnsigned.ts
 *   npm run poc:sepolia-estimate
 */
import {
  isHex,
  getAddress,
  formatEther,
  formatUnits,
  parseUnits,
  erc20Abi,
  type Hex,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

import "../config.js";
import {
  buildAuthorizationList,
  createFeeDelegation,
  createSmartAccountContext,
  encodeTransferCalldata,
  needsEip7702Upgrade,
} from "../delegations.js";
import { relayerExecution } from "../encodings.js";
import {
  findUsdcToken,
  getChainCapabilities,
  getFeeData,
  serializeDelegations,
  type Estimate7710Result,
  type Send7710Params,
} from "../relayer.js";

const CHAIN_ID = 11155111;
const RELAYER_URL = "https://relayer.1shotapi.dev/relayers";
const WORK_RECIPIENT = getAddress("0x4a0C5B7c1262d5D76B26235F7D96E86C24de3532");
const WORK_AMOUNT = 10_000n;

/** Same placeholder as 1shot-okx-relayer DelegationSignatureUtils (unsigned estimate). */
const PLACEHOLDER_DELEGATION_SIGNATURE: Hex =
  "0x0000000000000000000000000000000000000000000000000000000000000000";

function parsePrivateKey(): Hex {
  const raw = process.env.PRIVATE_KEY;
  if (!raw) {
    throw new Error("Missing PRIVATE_KEY in scripts/lifi-swap/.env");
  }
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(normalized)) {
    throw new Error("PRIVATE_KEY must be a hex string");
  }
  return normalized;
}

function sepoliaRpcUrl(): string {
  return process.env.SEPOLIA_RPC_URL ?? sepolia.rpcUrls.default.http[0]!;
}

/** relayer_getFeeData returns minFee in token units (e.g. "0.01"), not always atoms. */
function minFeeToAtoms(minFee: string | number, decimals: number): bigint {
  if (typeof minFee === "number") {
    if (Number.isInteger(minFee)) {
      return BigInt(minFee);
    }
    return parseUnits(minFee.toString(), decimals);
  }
  const trimmed = minFee.trim();
  if (trimmed.includes(".")) {
    return parseUnits(trimmed, decimals);
  }
  return BigInt(trimmed);
}

type RpcEnvelope = {
  httpOk: boolean;
  status: number;
  ms: number;
  jsonrpcError?: { code: number; message: string; data?: unknown };
  result?: Estimate7710Result;
  raw: unknown;
};

async function postEstimate(params: Send7710Params): Promise<RpcEnvelope> {
  const started = Date.now();
  const response = await fetch(RELAYER_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 0,
      method: "relayer_estimate7710Transaction",
      params,
    }),
  });
  const ms = Date.now() - started;
  const raw: unknown = await response.json();
  const envelope: RpcEnvelope = {
    httpOk: response.ok,
    status: response.status,
    ms,
    raw,
  };
  if (raw && typeof raw === "object") {
    const body = raw as {
      error?: { code: number; message: string; data?: unknown };
      result?: Estimate7710Result;
    };
    if (body.error) envelope.jsonrpcError = body.error;
    if (body.result) envelope.result = body.result;
  }
  return envelope;
}

function truncateHex(value: string, keep = 18): string {
  if (value.length <= keep + 3) return value;
  return `${value.slice(0, keep)}… (${value.length} chars)`;
}

function resultForPrint(result: Estimate7710Result | undefined): unknown {
  if (!result) return undefined;
  const out: Record<string, unknown> = { ...result };
  if (typeof out.context === "string") {
    out.context = truncateHex(out.context);
  }
  if (out.contextByChainId && typeof out.contextByChainId === "object") {
    const map: Record<string, string> = {};
    for (const [key, value] of Object.entries(
      out.contextByChainId as Record<string, unknown>,
    )) {
      map[key] = typeof value === "string" ? truncateHex(value) : String(value);
    }
    out.contextByChainId = map;
  }
  return out;
}

function firstSignature(params: Send7710Params): string {
  const first = params.transactions[0]?.permissionContext[0];
  if (!first || typeof first !== "object") return "<missing>";
  const signature = (first as { signature?: unknown }).signature;
  return typeof signature === "string" ? signature : String(signature ?? "<missing>");
}

function withPlaceholderSignatures(params: Send7710Params): Send7710Params {
  return {
    chainId: params.chainId,
    transactions: params.transactions.map((tx) => ({
      permissionContext: tx.permissionContext.map((entry) => {
        if (!entry || typeof entry !== "object") return entry;
        return {
          ...(entry as Record<string, unknown>),
          signature: PLACEHOLDER_DELEGATION_SIGNATURE,
        };
      }),
      executions: tx.executions,
    })),
  };
}

function isPlaceholderSignature(signature: string): boolean {
  const trimmed = signature.trim();
  if (trimmed === "") return true;
  let normalized = trimmed.toLowerCase();
  if (!normalized.startsWith("0x")) normalized = `0x${normalized}`;
  return normalized === PLACEHOLDER_DELEGATION_SIGNATURE.toLowerCase();
}

function requestSanity(params: Send7710Params): Record<string, unknown> {
  const signature = firstSignature(params);
  return {
    chainId: params.chainId,
    transactionCount: params.transactions.length,
    executionTargets: params.transactions.flatMap((tx) =>
      tx.executions.map((ex) => ex.target),
    ),
    executionValues: params.transactions.flatMap((tx) =>
      tx.executions.map((ex) => ex.value),
    ),
    signaturePlaceholder: isPlaceholderSignature(signature),
    signatureLength: signature.length,
    signaturePrefix: truncateHex(signature),
    authorizationListCount: params.authorizationList?.length ?? 0,
  };
}

function printSection(title: string): void {
  console.log(`\n=== ${title} ===`);
}

function printEstimate(label: string, params: Send7710Params, envelope: RpcEnvelope): void {
  printSection(label);
  console.log("request sanity:", JSON.stringify(requestSanity(params), null, 2));
  console.log("http.status:", envelope.status);
  console.log("http.ok:", envelope.httpOk);
  console.log("wallTimeMs:", envelope.ms);
  if (envelope.jsonrpcError) {
    console.log("jsonrpc.error:", JSON.stringify(envelope.jsonrpcError, null, 2));
  }
  const result = envelope.result;
  console.log("success:", result?.success);
  console.log("error:", result?.error ?? null);
  console.log("gasUsed:", JSON.stringify(result?.gasUsed ?? {}, null, 2));
  console.log("requiredPaymentAmount:", result?.requiredPaymentAmount ?? null);
  console.log("paymentTokenAddress:", result?.paymentTokenAddress ?? null);
  console.log("paymentChain:", result?.paymentChain ?? null);
  console.log(
    "context:",
    typeof result?.context === "string" ? truncateHex(result.context) : null,
  );
  console.log("result:", JSON.stringify(resultForPrint(result), null, 2));
}

function chainGas(result: Estimate7710Result | undefined): string | undefined {
  return result?.gasUsed?.[String(CHAIN_ID)];
}

async function main(): Promise<void> {
  const privateKey = parsePrivateKey();
  const rpcUrl = sepoliaRpcUrl();
  const account = privateKeyToAccount(privateKey);
  const ctx = await createSmartAccountContext(privateKey, rpcUrl, CHAIN_ID);

  const caps = await getChainCapabilities(CHAIN_ID, RELAYER_URL);
  const usdc = findUsdcToken(caps);
  const usdcAddress = getAddress(usdc.address);
  const feeCollector = getAddress(caps.feeCollector);
  const targetAddress = getAddress(caps.targetAddress);
  const decimals = Number(usdc.decimals);
  const feeData = await getFeeData(CHAIN_ID, usdcAddress as Hex, RELAYER_URL);
  const feeAmount = minFeeToAtoms(feeData.minFee as string | number, decimals);
  const maxAmount = feeAmount + WORK_AMOUNT;

  const [ethBalance, usdcBalance, code, needsUpgrade] = await Promise.all([
    ctx.publicClient.getBalance({ address: ctx.delegator }),
    ctx.publicClient.readContract({
      address: usdcAddress,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [ctx.delegator],
    }) as Promise<bigint>,
    ctx.publicClient.getCode({ address: ctx.delegator }),
    needsEip7702Upgrade(ctx),
  ]);
  const codeHex = code && code !== "0x" ? code : "0x";
  const hasContractCode = codeHex !== "0x";

  printSection("setup");
  console.log("relayerUrl:", RELAYER_URL);
  console.log("rpcUrl:", rpcUrl);
  console.log("chainId:", CHAIN_ID);
  console.log("eoa:", account.address);
  console.log("delegator:", ctx.delegator);
  console.log("usdc:", usdcAddress);
  console.log("usdc.symbol:", usdc.symbol ?? "USDC");
  console.log("usdc.decimals:", decimals);
  console.log("feeCollector:", feeCollector);
  console.log("targetAddress:", targetAddress);
  console.log("minFee:", feeData.minFee, `(${formatUnits(feeAmount, decimals)} USDC)`);
  console.log("feeAmount:", feeAmount.toString());
  console.log("workAmount:", WORK_AMOUNT.toString(), `(${formatUnits(WORK_AMOUNT, decimals)} USDC)`);
  console.log("workRecipient:", WORK_RECIPIENT);
  console.log("delegationMaxAmount:", maxAmount.toString());
  console.log("ethBalance:", ethBalance.toString(), `(${formatEther(ethBalance)} ETH)`);
  console.log("usdcBalance:", usdcBalance.toString(), `(${formatUnits(usdcBalance, decimals)} USDC)`);
  console.log("getCode.present:", hasContractCode);
  console.log("getCode.byteLength:", hasContractCode ? (codeHex.length - 2) / 2 : 0);
  console.log("needsEip7702Upgrade:", needsUpgrade);
  if (!hasContractCode) {
    console.log(
      "note: unsigned estimate requires on-chain 7702/smart-account code; case 2 is expected to fail until the account is upgraded.",
    );
  }
  if (usdcBalance < maxAmount) {
    console.log(
      `note: USDC balance ${usdcBalance} < fee+work ${maxAmount}; simulation may revert (shim does not fake balances).`,
    );
  }

  const delegation = await createFeeDelegation(
    ctx,
    targetAddress,
    usdcAddress,
    maxAmount,
  );

  const signedParams: Send7710Params = {
    chainId: String(CHAIN_ID),
    transactions: [
      {
        permissionContext: serializeDelegations([delegation]),
        executions: [
          relayerExecution(
            usdcAddress as Hex,
            0n,
            encodeTransferCalldata(feeCollector, feeAmount),
          ),
          relayerExecution(
            usdcAddress as Hex,
            0n,
            encodeTransferCalldata(WORK_RECIPIENT, WORK_AMOUNT),
          ),
        ],
      },
    ],
  };

  if (needsUpgrade) {
    signedParams.authorizationList = await buildAuthorizationList(ctx);
    console.log(
      "authorizationList: included on signed estimate (delegator has no code).",
    );
  }

  const placeholderParams = withPlaceholderSignatures(signedParams);

  const signedEnvelope = await postEstimate(signedParams);
  printEstimate("1. signed estimate", signedParams, signedEnvelope);

  const placeholderEnvelope = await postEstimate(placeholderParams);
  printEstimate(
    "2. placeholder estimate (signature bytes32(0))",
    placeholderParams,
    placeholderEnvelope,
  );

  printSection("comparison");
  const signedGas = chainGas(signedEnvelope.result);
  const placeholderGas = chainGas(placeholderEnvelope.result);
  console.log(
    JSON.stringify(
      {
        signed: {
          success: signedEnvelope.result?.success ?? false,
          jsonrpcError: signedEnvelope.jsonrpcError?.message ?? null,
          error: signedEnvelope.result?.error ?? null,
          gasUsed: signedGas ?? null,
          requiredPaymentAmount: signedEnvelope.result?.requiredPaymentAmount ?? null,
          wallTimeMs: signedEnvelope.ms,
        },
        placeholder: {
          success: placeholderEnvelope.result?.success ?? false,
          jsonrpcError: placeholderEnvelope.jsonrpcError?.message ?? null,
          error: placeholderEnvelope.result?.error ?? null,
          gasUsed: placeholderGas ?? null,
          requiredPaymentAmount: placeholderEnvelope.result?.requiredPaymentAmount ?? null,
          wallTimeMs: placeholderEnvelope.ms,
        },
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
