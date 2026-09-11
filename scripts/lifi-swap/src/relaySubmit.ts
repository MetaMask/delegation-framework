import type { Hex } from "viem";

import { MOCK_FEE_USDC_ATOMS } from "./constants.js";
import { buildAuthorizationList, type SmartAccountContext } from "./delegations.js";
import {
  estimate7710Transaction,
  getFeeData,
  send7710Transaction,
  type Estimate7710Result,
  type Send7710Params,
} from "./relayer.js";

export type EstimatePrepareResult = {
  sendParams: Send7710Params;
  estimate: Estimate7710Result;
  authorizationList?: unknown[];
  requiredFee: bigint;
};

export function logEstimateResult(estimate: Estimate7710Result, prefix = ""): void {
  const label = prefix ? `${prefix} ` : "";
  console.log(`${label}requiredPaymentAmount: ${estimate.requiredPaymentAmount}`);
  console.log(`${label}gasUsed: ${JSON.stringify(estimate.gasUsed)}`);
}

async function resolveMockFee(
  chainId: number,
  paymentToken: Hex,
  relayerUrl: string,
): Promise<bigint> {
  try {
    const feeData = await getFeeData(chainId, paymentToken, relayerUrl);
    return BigInt(feeData.minFee);
  } catch {
    return MOCK_FEE_USDC_ATOMS;
  }
}

function withAuthorizationList(
  params: Send7710Params,
  authorizationList?: unknown[],
): Send7710Params {
  if (!authorizationList) return params;
  return { ...params, authorizationList };
}

export async function estimateAndPrepareSend(options: {
  ctx: SmartAccountContext;
  chainId: number;
  paymentToken: Hex;
  relayerUrl: string;
  buildSendParams: (feeAmount: bigint) => Promise<Send7710Params> | Send7710Params;
}): Promise<EstimatePrepareResult> {
  const { ctx, chainId, paymentToken, relayerUrl, buildSendParams } = options;

  const authorizationList = await buildAuthorizationList(ctx);
  let mockFee = await resolveMockFee(chainId, paymentToken, relayerUrl);

  let sendParams = withAuthorizationList(await buildSendParams(mockFee), authorizationList);
  let estimate = await estimate7710Transaction(sendParams, relayerUrl);
  if (!estimate.success) {
    throw new Error(estimate.error ?? "Relayer estimate failed");
  }

  let requiredFee = BigInt(estimate.requiredPaymentAmount ?? mockFee.toString());
  if (requiredFee !== mockFee) {
    mockFee = requiredFee;
    sendParams = withAuthorizationList(await buildSendParams(requiredFee), authorizationList);
    estimate = await estimate7710Transaction(sendParams, relayerUrl);
    if (!estimate.success) {
      throw new Error(estimate.error ?? "Relayer re-estimate failed");
    }
    requiredFee = BigInt(estimate.requiredPaymentAmount ?? requiredFee.toString());
  }

  return {
    sendParams,
    estimate,
    authorizationList,
    requiredFee,
  };
}

export async function sendPreparedTransaction(
  prepared: EstimatePrepareResult,
  relayerUrl: string,
  extras: { memo?: string } = {},
): Promise<Hex> {
  if (!prepared.estimate.context) {
    throw new Error("Relayer estimate missing context for price lock");
  }
  return send7710Transaction(
    {
      ...prepared.sendParams,
      context: prepared.estimate.context,
      ...extras,
    },
    relayerUrl,
  );
}
