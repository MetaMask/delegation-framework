import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  padHex,
  toHex,
  type Address,
  type Hex,
  type StateOverride,
} from "viem";

import type { SmartAccountContext } from "./delegations.js";

export type { StateOverride };

export type Erc20FundingRequirement = {
  token: Address;
  holder: Address;
  spender: Address;
  minBalance: bigint;
  minAllowance: bigint;
};

type StateMapping = NonNullable<StateOverride[number]["stateDiff"]>;

type AccountOverride = StateOverride[number];

const OZ_BALANCES_SLOT = 0n;
const OZ_ALLOWANCES_SLOT = 1n;

function mappingSlot(key: Address, slot: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [key, slot],
    ),
  );
}

function allowanceSlot(owner: Address, spender: Address): Hex {
  const inner = mappingSlot(owner, OZ_ALLOWANCES_SLOT);
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "bytes32" }],
      [spender, inner],
    ),
  );
}

function balanceSlot(holder: Address): Hex {
  return mappingSlot(holder, OZ_BALANCES_SLOT);
}

function uint256StorageValue(value: bigint): Hex {
  return padHex(toHex(value), { size: 32 });
}

function stateDiffFromEntries(entries: Record<Hex, Hex>): StateMapping {
  return Object.entries(entries).map(([slot, value]) => ({
    slot: slot as Hex,
    value,
  }));
}

function mergeStateDiff(a: StateMapping | undefined, b: StateMapping | undefined): StateMapping {
  const bySlot = new Map<string, Hex>();
  for (const entry of a ?? []) {
    bySlot.set(entry.slot.toLowerCase(), entry.value);
  }
  for (const entry of b ?? []) {
    bySlot.set(entry.slot.toLowerCase(), entry.value);
  }
  return [...bySlot.entries()].map(([slot, value]) => ({
    slot: slot as Hex,
    value,
  }));
}

export function buildDelegatorShimOverride(
  delegator: Address,
  shimBytecode: Hex,
): StateOverride {
  return [{ address: getAddress(delegator), code: shimBytecode }];
}

export async function readErc20BalanceAndAllowance(
  ctx: SmartAccountContext,
  token: Address,
  holder: Address,
  spender: Address,
): Promise<{ balance: bigint; allowance: bigint }> {
  const [balance, allowance] = await Promise.all([
    ctx.publicClient.readContract({
      address: token,
      abi: [
        {
          type: "function",
          name: "balanceOf",
          stateMutability: "view",
          inputs: [{ name: "account", type: "address" }],
          outputs: [{ type: "uint256" }],
        },
      ],
      functionName: "balanceOf",
      args: [holder],
    }) as Promise<bigint>,
    ctx.publicClient.readContract({
      address: token,
      abi: [
        {
          type: "function",
          name: "allowance",
          stateMutability: "view",
          inputs: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
          ],
          outputs: [{ type: "uint256" }],
        },
      ],
      functionName: "allowance",
      args: [holder, spender],
    }) as Promise<bigint>,
  ]);
  return { balance, allowance };
}

export function buildErc20FundingOverride(
  req: Erc20FundingRequirement,
  current: { balance: bigint; allowance: bigint },
): StateOverride {
  const balance = req.minBalance > current.balance ? req.minBalance : current.balance;
  const allowance =
    req.minAllowance > current.allowance ? req.minAllowance : current.allowance;

  return [
    {
      address: getAddress(req.token),
      stateDiff: stateDiffFromEntries({
        [balanceSlot(req.holder)]: uint256StorageValue(balance),
        [allowanceSlot(req.holder, req.spender)]: uint256StorageValue(allowance),
      }),
    },
  ];
}

export function mergeStateOverrides(...overrides: StateOverride[]): StateOverride {
  const byAddress = new Map<string, AccountOverride>();

  for (const list of overrides) {
    for (const entry of list) {
      const key = getAddress(entry.address).toLowerCase();
      const existing = byAddress.get(key);
      if (!existing) {
        const next: AccountOverride = {
          address: getAddress(entry.address),
          ...(entry.code !== undefined ? { code: entry.code } : {}),
          ...(entry.balance !== undefined ? { balance: entry.balance } : {}),
          ...(entry.nonce !== undefined ? { nonce: entry.nonce } : {}),
          ...(entry.stateDiff !== undefined && entry.stateDiff.length > 0
            ? { stateDiff: entry.stateDiff }
            : {}),
        };
        byAddress.set(key, next);
        continue;
      }
      const mergedDiff = mergeStateDiff(existing.stateDiff, entry.stateDiff);
      byAddress.set(key, {
        address: getAddress(entry.address),
        code: entry.code ?? existing.code,
        balance: entry.balance ?? existing.balance,
        nonce: entry.nonce ?? existing.nonce,
        ...(mergedDiff.length > 0 ? { stateDiff: mergedDiff } : {}),
      });
    }
  }

  return [...byAddress.values()];
}
