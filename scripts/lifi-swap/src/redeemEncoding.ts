import type { Delegation } from "@metamask/smart-accounts-kit";
import { encodeDelegations, encodeSingleExecution } from "@metamask/smart-accounts-kit/utils";
import { encodeFunctionData, type Address, type Hex } from "viem";

import { DELEGATION_MANAGER } from "./constants.js";

/** @metamask/smart-accounts-kit ExecutionMode.SingleDefault */
const MODE_SINGLE_DEFAULT: Hex =
  "0x0000000000000000000000000000000000000000000000000000000000000000";

const delegationManagerAbi = [
  {
    type: "function",
    name: "redeemDelegations",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_permissionContexts", type: "bytes[]" },
      { name: "_modes", type: "bytes32[]" },
      { name: "_executionCallDatas", type: "bytes[]" },
    ],
    outputs: [],
  },
] as const;

export type RedeemBatchItem = {
  delegations: Delegation[];
  executionTarget: Address;
  executionValue: bigint;
  executionCalldata: Hex;
};

export type RedeemParams = {
  permissionContexts: Hex[];
  modes: Hex[];
  executionCallDatas: Hex[];
};

export function encodeRedeemBatchItems(items: RedeemBatchItem[]): RedeemParams {
  const permissionContexts: Hex[] = [];
  const modes: Hex[] = [];
  const executionCallDatas: Hex[] = [];

  for (const item of items) {
    permissionContexts.push(encodeDelegations(item.delegations));
    modes.push(MODE_SINGLE_DEFAULT);
    executionCallDatas.push(
      encodeSingleExecution({
        target: item.executionTarget,
        value: item.executionValue,
        callData: item.executionCalldata,
      }),
    );
  }

  return { permissionContexts, modes, executionCallDatas };
}

export function encodeRedeemDelegationsCalldata(params: RedeemParams): Hex {
  return encodeFunctionData({
    abi: delegationManagerAbi,
    functionName: "redeemDelegations",
    args: [params.permissionContexts, params.modes, params.executionCallDatas],
  });
}

/** Subset redeem batches (e.g. fee-only = [0], swap-only = [1]). */
export function sliceRedeemParams(
  params: RedeemParams,
  batchIndices: number[],
): RedeemParams {
  return {
    permissionContexts: batchIndices.map((i) => params.permissionContexts[i]!),
    modes: batchIndices.map((i) => params.modes[i]!),
    executionCallDatas: batchIndices.map((i) => params.executionCallDatas[i]!),
  };
}

export { DELEGATION_MANAGER };
