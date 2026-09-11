import { randomBytes } from "node:crypto";

import {
  Implementation,
  ScopeType,
  createCaveat,
  createDelegation,
  getSmartAccountsEnvironment,
  type Delegation,
  type MetaMaskSmartAccount,
  type SmartAccountsEnvironment,
} from "@metamask/smart-accounts-kit";
import {
  createCaveatBuilder,
  hashDelegation,
} from "@metamask/smart-accounts-kit/utils";
import {
  createPublicClient,
  encodeFunctionData,
  erc20Abi,
  getAddress,
  http,
  maxUint256,
  type Address,
  type Hex,
  type PrivateKeyAccount,
} from "viem";
import { toMetaMaskSmartAccount } from "@metamask/smart-accounts-kit";
import { bytesToHex } from "viem/utils";

import { viemChainFromId } from "./chains.js";
import {
  CHAINLINK_PRICE_RULE_ENFORCER,
  LIFI_SWAP_ENFORCER,
  ROOT_AUTHORITY,
} from "./constants.js";
import { readFeedDecimals } from "./chainlink.js";
import { encodeChainlinkTerms } from "./chainlinkTerms.js";
import { addressToBytes32, encodeLiFiTerms } from "./terms.js";
import type { ChainlinkTermsRecord, LiFiTermsRecord } from "./types.js";

export type SmartAccountContext = {
  account: PrivateKeyAccount;
  smartAccount: MetaMaskSmartAccount;
  publicClient: any;
  environment: SmartAccountsEnvironment;
  delegator: Address;
  chainId: number;
};

export async function createSmartAccountContext(
  privateKey: Hex,
  rpcUrl: string,
  chainId: number,
): Promise<SmartAccountContext> {
  const { privateKeyToAccount } = await import("viem/accounts");
  const account = privateKeyToAccount(privateKey);
  const chain = viemChainFromId(chainId, rpcUrl);
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const environment = getSmartAccountsEnvironment(chainId);

  const smartAccount = await toMetaMaskSmartAccount({
    client: publicClient as Parameters<typeof toMetaMaskSmartAccount>[0]["client"],
    implementation: Implementation.Stateless7702,
    address: account.address,
    signer: { account },
  });

  return {
    account,
    smartAccount,
    publicClient,
    environment,
    delegator: smartAccount.address,
    chainId,
  };
}

function randomSalt(): Hex {
  return bytesToHex(randomBytes(32)) as Hex;
}

export async function needsEip7702Upgrade(
  ctx: SmartAccountContext,
): Promise<boolean> {
  const code = await ctx.publicClient.getCode({ address: ctx.delegator });
  return !code || code === "0x";
}

export async function buildAuthorizationList(ctx: SmartAccountContext) {
  if (!(await needsEip7702Upgrade(ctx))) {
    return undefined;
  }

  const nonce = await ctx.publicClient.getTransactionCount({
    address: ctx.delegator,
    blockTag: "pending",
  });

  const auth = await ctx.account.signAuthorization({
    chainId: ctx.chainId,
    contractAddress: getAddress(ctx.environment.implementations.EIP7702StatelessDeleGatorImpl),
    nonce,
  });

  return [
    {
      address: auth.address,
      chainId: auth.chainId,
      nonce: auth.nonce,
      r: auth.r,
      s: auth.s,
      yParity: auth.yParity ?? 0,
    },
  ];
}

export function buildSwapCaveats(
  environment: SmartAccountsEnvironment,
  lifiDiamond: Address,
  termsBytes: Hex,
) {
  const builder = createCaveatBuilder(environment, {
    allowInsecureUnrestrictedDelegation: true,
  })
    .addCaveat("allowedTargets", { targets: [lifiDiamond] })
    .addCaveat("valueLte", { maxValue: 0n })
    .addCaveat(
      createCaveat(getAddress(LIFI_SWAP_ENFORCER), termsBytes, "0x"),
    );

  return builder.build();
}

export function buildPriceGatedSwapCaveats(
  environment: SmartAccountsEnvironment,
  lifiDiamond: Address,
  chainlinkTermsBytes: Hex,
  lifiTermsBytes: Hex,
) {
  const builder = createCaveatBuilder(environment, {
    allowInsecureUnrestrictedDelegation: true,
  })
    .addCaveat("allowedTargets", { targets: [lifiDiamond] })
    .addCaveat("valueLte", { maxValue: 0n })
    .addCaveat(
      createCaveat(
        getAddress(CHAINLINK_PRICE_RULE_ENFORCER),
        chainlinkTermsBytes,
        "0x",
      ),
    )
    .addCaveat(
      createCaveat(getAddress(LIFI_SWAP_ENFORCER), lifiTermsBytes, "0x"),
    );

  return builder.build();
}

export function buildApproveCaveats(
  environment: SmartAccountsEnvironment,
  inputToken: Address,
  lifiDiamond: Address,
) {
  const approveSelector = encodeFunctionData({
    abi: erc20Abi,
    functionName: "approve",
    args: [lifiDiamond, 0n],
  }).slice(0, 10) as Hex;

  const builder = createCaveatBuilder(environment, {
    allowInsecureUnrestrictedDelegation: true,
  })
    .addCaveat("allowedTargets", { targets: [inputToken] })
    .addCaveat("allowedMethods", { selectors: [approveSelector] })
    .addCaveat("allowedCalldata", {
      startIndex: 4,
      value: addressToBytes32(lifiDiamond),
    })
    .addCaveat("valueLte", { maxValue: 0n });

  return builder.build();
}

async function signDelegationToRelayer(
  ctx: SmartAccountContext,
  targetAddress: Address,
  caveats: ReturnType<typeof buildSwapCaveats>,
  salt: Hex,
): Promise<Delegation> {
  const delegation: Delegation = {
    delegate: targetAddress,
    delegator: ctx.delegator,
    authority: ROOT_AUTHORITY,
    caveats: caveats.map((c) => ({ ...c, args: c.args ?? "0x" })),
    salt,
    signature: "0x",
  };

  const signature = await ctx.smartAccount.signDelegation({ delegation });
  return { ...delegation, signature };
}

export async function createPriceGatedSwapDelegation(
  ctx: SmartAccountContext,
  targetAddress: Address,
  chainlinkTerms: ChainlinkTermsRecord,
  lifiTerms: LiFiTermsRecord,
): Promise<{
  delegation: Delegation;
  delegationHash: Hex;
  chainlinkTerms: ChainlinkTermsRecord;
  chainlinkTermsBytes: Hex;
  lifiTermsBytes: Hex;
}> {
  const expectedDecimals = await readFeedDecimals(
    ctx.publicClient,
    chainlinkTerms.priceFeed,
  );
  const resolvedChainlinkTerms = { ...chainlinkTerms, expectedDecimals };

  const chainlinkTermsBytes = encodeChainlinkTerms({
    priceFeed: resolvedChainlinkTerms.priceFeed,
    ruleKind: resolvedChainlinkTerms.ruleKind,
    expectedDecimals: resolvedChainlinkTerms.expectedDecimals,
    windowSeconds: Number(resolvedChainlinkTerms.windowSeconds),
    thresholdBps: resolvedChainlinkTerms.thresholdBps,
    maxStaleSeconds: Number(resolvedChainlinkTerms.maxStaleSeconds),
    minGapSeconds: Number(resolvedChainlinkTerms.minGapSeconds),
    triggerPrice: BigInt(resolvedChainlinkTerms.triggerPrice),
  });

  const lifiTermsBytes = encodeLiFiTerms({
    lifiDiamond: lifiTerms.lifiDiamond,
    inputToken: lifiTerms.inputToken,
    outputAssetId: lifiTerms.outputAssetId,
    outputRecipient: lifiTerms.outputRecipient,
    destinationChainId: BigInt(lifiTerms.destinationChainId),
    quoteSigner: lifiTerms.quoteSigner,
    periodAmount: BigInt(lifiTerms.periodAmount),
    periodDuration: BigInt(lifiTerms.periodDuration),
    startDate: BigInt(lifiTerms.startDate),
    slippageBps: BigInt(lifiTerms.slippageBps),
  });

  const caveats = buildPriceGatedSwapCaveats(
    ctx.environment,
    lifiTerms.lifiDiamond,
    chainlinkTermsBytes,
    lifiTermsBytes,
  );
  const salt = randomSalt();
  const delegation = await signDelegationToRelayer(ctx, targetAddress, caveats, salt);
  const delegationForHash: Delegation = {
    ...delegation,
    caveats: delegation.caveats.map((c: Delegation["caveats"][number]) => ({ ...c, args: "0x" })),
  };
  const delegationHash = hashDelegation(delegationForHash);

  return {
    delegation: delegationForHash,
    delegationHash,
    chainlinkTerms: resolvedChainlinkTerms,
    chainlinkTermsBytes,
    lifiTermsBytes,
  };
}

export async function createSwapDelegation(
  ctx: SmartAccountContext,
  targetAddress: Address,
  terms: LiFiTermsRecord,
): Promise<{ delegation: Delegation; delegationHash: Hex; termsBytes: Hex }> {
  const termsBytes = encodeLiFiTerms({
    lifiDiamond: terms.lifiDiamond,
    inputToken: terms.inputToken,
    outputAssetId: terms.outputAssetId,
    outputRecipient: terms.outputRecipient,
    destinationChainId: BigInt(terms.destinationChainId),
    quoteSigner: terms.quoteSigner,
    periodAmount: BigInt(terms.periodAmount),
    periodDuration: BigInt(terms.periodDuration),
    startDate: BigInt(terms.startDate),
    slippageBps: BigInt(terms.slippageBps),
  });

  const caveats = buildSwapCaveats(ctx.environment, terms.lifiDiamond, termsBytes);
  const salt = randomSalt();
  const delegation = await signDelegationToRelayer(ctx, targetAddress, caveats, salt);
  const delegationForHash: Delegation = {
    ...delegation,
    caveats: delegation.caveats.map((c: Delegation["caveats"][number]) => ({ ...c, args: "0x" })),
  };
  const delegationHash = hashDelegation(delegationForHash);

  return {
    delegation: delegationForHash,
    delegationHash,
    termsBytes,
  };
}

export async function createApproveDelegation(
  ctx: SmartAccountContext,
  targetAddress: Address,
  inputToken: Address,
  lifiDiamond: Address,
): Promise<Delegation> {
  const caveats = buildApproveCaveats(ctx.environment, inputToken, lifiDiamond);
  return signDelegationToRelayer(ctx, targetAddress, caveats, randomSalt());
}

export async function createFeeDelegation(
  ctx: SmartAccountContext,
  targetAddress: Address,
  paymentToken: Address,
  maxAmount: bigint,
): Promise<Delegation> {
  const delegation = createDelegation({
    to: targetAddress,
    from: ctx.delegator,
    environment: ctx.environment,
    salt: randomSalt(),
    scope: {
      type: ScopeType.Erc20TransferAmount,
      tokenAddress: paymentToken,
      maxAmount,
    },
  });

  const signature = await ctx.smartAccount.signDelegation({ delegation });
  return { ...delegation, signature };
}

export async function readErc20Allowance(
  ctx: SmartAccountContext,
  token: Address,
  spender: Address,
): Promise<bigint> {
  return ctx.publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [ctx.delegator, spender],
  });
}

export function encodeApproveCalldata(spender: Address, amount: bigint = maxUint256): Hex {
  return encodeFunctionData({
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, amount],
  });
}

export function encodeTransferCalldata(to: Address, amount: bigint): Hex {
  return encodeFunctionData({
    abi: erc20Abi,
    functionName: "transfer",
    args: [to, amount],
  });
}

export async function readAvailableBudget(
  ctx: SmartAccountContext,
  delegationHash: Hex,
  termsBytes: Hex,
): Promise<{ available: bigint; isNewPeriod: boolean; currentPeriod: bigint }> {
  const result = await ctx.publicClient.readContract({
    address: LIFI_SWAP_ENFORCER,
    abi: [
      {
        type: "function",
        name: "getAvailableAmount",
        stateMutability: "view",
        inputs: [
          { name: "_delegationHash", type: "bytes32" },
          { name: "_delegationManager", type: "address" },
          { name: "_terms", type: "bytes" },
        ],
        outputs: [
          { name: "availableAmount_", type: "uint256" },
          { name: "isNewPeriod_", type: "bool" },
          { name: "currentPeriod_", type: "uint256" },
        ],
      },
    ],
    functionName: "getAvailableAmount",
    args: [delegationHash, ctx.environment.DelegationManager, termsBytes],
  });

  return {
    available: result[0],
    isNewPeriod: result[1],
    currentPeriod: result[2],
  };
}
