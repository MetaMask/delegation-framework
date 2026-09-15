import type { Delegation } from "@metamask/smart-accounts-kit";
import type { Address, Hex } from "viem";

import {
  createFeeDelegation,
  encodeTransferCalldata,
  type SmartAccountContext,
} from "./delegations.js";
import { relayerExecution } from "./encodings.js";
import { BOGUS_DELEGATION_SIGNATURE } from "./pocConstants.js";
import { encodeRedeemBatchItems, type RedeemParams } from "./redeemEncoding.js";
import { serializeDelegations, type Send7710Params } from "./relayer.js";

export type EstimateBundle = {
  feeDelegation: Delegation;
  swapDelegation: Delegation;
  sendParams: Send7710Params;
  redeemParams: RedeemParams;
  feeAmount: bigint;
};

function cloneDelegationWithSignature(
  delegation: Delegation,
  signature: Hex,
): Delegation {
  return { ...delegation, signature };
}

export async function buildEstimateBundle(options: {
  ctx: SmartAccountContext;
  chainId: number;
  targetAddress: Address;
  feeCollector: Address;
  paymentToken: Address;
  feeAmount: bigint;
  patchedSwapDelegation: Delegation;
  lifiDiamond: Address;
  diamondCalldata: Hex;
  signatureMode: "valid" | "bogus";
  authorizationList?: unknown[];
}): Promise<EstimateBundle> {
  const {
    ctx,
    chainId,
    targetAddress,
    feeCollector,
    paymentToken,
    feeAmount,
    patchedSwapDelegation,
    lifiDiamond,
    diamondCalldata,
    signatureMode,
    authorizationList,
  } = options;

  let feeDelegation = await createFeeDelegation(
    ctx,
    targetAddress,
    paymentToken,
    feeAmount,
  );
  let swapDelegation = patchedSwapDelegation;

  if (signatureMode === "bogus") {
    feeDelegation = cloneDelegationWithSignature(
      feeDelegation,
      BOGUS_DELEGATION_SIGNATURE,
    );
    swapDelegation = cloneDelegationWithSignature(
      patchedSwapDelegation,
      BOGUS_DELEGATION_SIGNATURE,
    );
  }

  const feeTransferCalldata = encodeTransferCalldata(feeCollector, feeAmount);

  const sendParams: Send7710Params = {
    chainId: String(chainId),
    ...(authorizationList ? { authorizationList } : {}),
    transactions: [
      {
        permissionContext: serializeDelegations([feeDelegation]),
        executions: [
          relayerExecution(paymentToken, 0n, feeTransferCalldata),
        ],
      },
      {
        permissionContext: serializeDelegations([swapDelegation]),
        executions: [relayerExecution(lifiDiamond, 0n, diamondCalldata)],
      },
    ],
  };

  const redeemParams = encodeRedeemBatchItems([
    {
      delegations: [feeDelegation],
      executionTarget: paymentToken,
      executionValue: 0n,
      executionCalldata: feeTransferCalldata,
    },
    {
      delegations: [swapDelegation],
      executionTarget: lifiDiamond,
      executionValue: 0n,
      executionCalldata: diamondCalldata,
    },
  ]);

  return {
    feeDelegation,
    swapDelegation,
    sendParams,
    redeemParams,
    feeAmount,
  };
}
