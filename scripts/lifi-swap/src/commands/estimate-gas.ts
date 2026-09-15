import type { Address, Hex } from "viem";

import { buildEstimateBundle } from "../buildEstimateBundle.js";
import { formatRevert } from "../decodeRevert.js";
import {
  flagBigInt,
  flagBool,
  flagString,
  loadCliConfig,
  parseArgs,
  parseCommaList,
} from "../config.js";
import { DELEGATION_MANAGER, MOCK_FEE_USDC_ATOMS } from "../constants.js";
import {
  buildAuthorizationList,
  createSmartAccountContext,
  type SmartAccountContext,
} from "../delegations.js";
import { savedExecutionChainId } from "../executionChain.js";
import { formatExecuteQuoteSummary } from "../format.js";
import { prepareSwapRedemption } from "../prepareSwapRedemption.js";
import { DELEGATOR_ESTIMATE_SHIM_CODE } from "../poc/delegatorEstimateShimBytecode.js";
import { BOGUS_DELEGATION_SIGNATURE } from "../pocConstants.js";
import {
  encodeRedeemDelegationsCalldata,
  sliceRedeemParams,
  type RedeemParams,
} from "../redeemEncoding.js";
import {
  estimate7710Transaction,
  assertSavedRelayerTarget,
  findUsdcToken,
  getChainCapabilities,
  getFeeData,
  type Estimate7710Result,
} from "../relayer.js";
import {
  buildDelegatorShimOverride,
  buildErc20FundingOverride,
  mergeStateOverrides,
  readErc20BalanceAndAllowance,
  type StateOverride,
} from "../stateOverride.js";
import { loadDelegation } from "../store.js";

async function runBatchRpcDebug(options: {
  label: string;
  ctx: SmartAccountContext;
  redeemAccount: Address;
  redeemParams: RedeemParams;
  batchIndices: number[];
  stateOverride: StateOverride;
}): Promise<void> {
  const { label, ctx, redeemAccount, redeemParams, batchIndices, stateOverride } =
    options;
  const sliced = sliceRedeemParams(redeemParams, batchIndices);
  const calldata = encodeRedeemDelegationsCalldata(sliced);
  const result = await runRpcRedeemSimulation({
    ctx,
    redeemAccount,
    redeemCalldata: calldata,
    stateOverride,
  });
  console.log(
    result.ok
      ? `  ${label}: success`
      : `  ${label}: ${result.revert}`,
  );
}

async function runRpcRedeemSimulation(options: {
  ctx: SmartAccountContext;
  redeemAccount: Address;
  redeemCalldata: Hex;
  stateOverride?: StateOverride;
}): Promise<{ ok: boolean; revert?: string }> {
  const { ctx, redeemAccount, redeemCalldata, stateOverride } = options;
  try {
    await ctx.publicClient.call({
      account: redeemAccount,
      to: DELEGATION_MANAGER,
      data: redeemCalldata,
      stateOverride,
    });
    return { ok: true };
  } catch (error) {
    return { ok: false, revert: formatRevert(error) };
  }
}

async function estimateRpcGas(options: {
  ctx: SmartAccountContext;
  redeemAccount: Address;
  redeemCalldata: Hex;
  stateOverride: StateOverride;
}): Promise<bigint> {
  const { ctx, redeemAccount, redeemCalldata, stateOverride } = options;
  return ctx.publicClient.estimateGas({
    account: redeemAccount,
    to: DELEGATION_MANAGER,
    data: redeemCalldata,
    stateOverride,
  });
}

async function buildFundingOverrides(
  ctx: SmartAccountContext,
  delegator: Address,
  inputToken: Address,
  lifiDiamond: Address,
  fromAmount: bigint,
  paymentToken: Address,
  feeAmount: bigint,
): Promise<{ overrides: StateOverride; logs: string[] }> {
  const logs: string[] = [];
  const inputFunding = await readErc20BalanceAndAllowance(
    ctx,
    inputToken,
    delegator,
    lifiDiamond,
  );
  logs.push(
    `inputToken balance=${inputFunding.balance} allowance→diamond=${inputFunding.allowance}`,
  );

  const overrides = [
    buildErc20FundingOverride(
      {
        token: inputToken,
        holder: delegator,
        spender: lifiDiamond,
        minBalance: fromAmount,
        minAllowance: fromAmount,
      },
      inputFunding,
    ),
  ];

  if (paymentToken.toLowerCase() !== inputToken.toLowerCase()) {
    const feeFunding = await readErc20BalanceAndAllowance(
      ctx,
      paymentToken,
      delegator,
      paymentToken,
    );
    logs.push(
      `feeToken balance=${feeFunding.balance} (fee transfer uses transfer(), no allowance)`,
    );
    overrides.push(
      buildErc20FundingOverride(
        {
          token: paymentToken,
          holder: delegator,
          spender: paymentToken,
          minBalance: feeAmount,
          minAllowance: 0n,
        },
        feeFunding,
      ),
    );
  } else {
    const combined = fromAmount + feeAmount;
    overrides[0] = buildErc20FundingOverride(
      {
        token: inputToken,
        holder: delegator,
        spender: lifiDiamond,
        minBalance: combined,
        minAllowance: fromAmount,
      },
      inputFunding,
    );
  }

  return { overrides: mergeStateOverrides(...overrides), logs };
}

async function relayerEstimateLoop(options: {
  ctx: SmartAccountContext;
  chainId: number;
  paymentToken: Address;
  relayerUrl: string;
  buildAtFee: (feeAmount: bigint) => ReturnType<typeof buildEstimateBundle>;
}): Promise<{
  estimate: Estimate7710Result;
  feeAmount: bigint;
  validBundle: Awaited<ReturnType<typeof buildEstimateBundle>>;
}> {
  const { ctx, chainId, paymentToken, relayerUrl, buildAtFee } = options;

  let mockFee = MOCK_FEE_USDC_ATOMS;
  try {
    const feeData = await getFeeData(chainId, paymentToken, relayerUrl);
    mockFee = BigInt(feeData.minFee);
  } catch {
    // use default mock
  }

  let feeAmount = mockFee;
  let validBundle = await buildAtFee(feeAmount);
  let estimate = await estimate7710Transaction(validBundle.sendParams, relayerUrl);
  if (!estimate.success) {
    throw new Error(estimate.error ?? "Relayer estimate failed");
  }

  const required = BigInt(estimate.requiredPaymentAmount ?? feeAmount.toString());
  if (required !== feeAmount) {
    feeAmount = required;
    validBundle = await buildAtFee(feeAmount);
    estimate = await estimate7710Transaction(validBundle.sendParams, relayerUrl);
    if (!estimate.success) {
      throw new Error(estimate.error ?? "Relayer re-estimate failed");
    }
  }

  return { estimate, feeAmount, validBundle };
}

function printComparison(options: {
  chainId: number;
  relayerEstimate?: Estimate7710Result;
  rpcGas?: bigint;
  feeAmount: bigint;
  incomplete: boolean;
}): void {
  const { chainId, relayerEstimate, rpcGas, feeAmount, incomplete } = options;
  console.log("\n=== Gas estimate comparison ===");
  if (relayerEstimate?.success) {
    const relayerGasKey = String(chainId);
    const relayerGas = BigInt(relayerEstimate.gasUsed?.[relayerGasKey] ?? "0");
    console.log(
      `relayer_estimate7710Transaction.gasUsed[${relayerGasKey}]: ${relayerGas.toString()}`,
    );
    console.log(
      `relayer requiredPaymentAmount: ${relayerEstimate.requiredPaymentAmount ?? feeAmount.toString()}`,
    );
    if (rpcGas !== undefined) {
      const delta = rpcGas - relayerGas;
      const pct =
        relayerGas > 0n
          ? Number((delta * 10000n) / relayerGas) / 100
          : 0;
      console.log(`rpc eth_estimateGas (redeemDelegations + shim):     ${rpcGas.toString()}`);
      console.log(`delta (rpc - relayer):                              ${delta.toString()} (${pct}%)`);
    } else {
      console.log("rpc eth_estimateGas: (skipped)");
    }
  } else {
    console.log("relayer estimate: FAILED or skipped");
    if (relayerEstimate?.error) {
      console.log(`  error: ${relayerEstimate.error}`);
    }
    if (rpcGas !== undefined) {
      console.log(`rpc eth_estimateGas (redeemDelegations + shim): ${rpcGas.toString()}`);
    }
  }
  if (incomplete) {
    console.log("comparison: INCOMPLETE (relayer and/or RPC path did not both succeed)");
  }
}

export async function runEstimateGasCommand(argv: string[]): Promise<void> {
  const { positional, flags } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error(
      "Usage: estimate-gas <id> [--amount <atoms>] [--skip-control] [--skip-relayer] [--skip-rpc] [--skip-rpc-debug]",
    );
  }

  const skipControl = flagBool(flags, "skip-control");
  const skipRelayer = flagBool(flags, "skip-relayer");
  const skipRpc = flagBool(flags, "skip-rpc");
  const skipRpcDebug = flagBool(flags, "skip-rpc-debug");
  const verbose = flagBool(flags, "verbose");
  const skipChainlink = flagBool(flags, "skip-chainlink");
  const requireChainlink = flagBool(flags, "require-chainlink");
  const referenceRoundRaw = flagString(flags, "reference-round-id");
  const referenceRoundId =
    referenceRoundRaw !== undefined ? BigInt(referenceRoundRaw) : undefined;
  const feeAtomsOverride = flagBigInt(flags, "fee-atoms");
  const cli = loadCliConfig({
    fromAmount: flagBigInt(flags, "amount"),
  });
  const allowBridges = parseCommaList(flagString(flags, "allow-bridges"));
  const denyBridges = parseCommaList(flagString(flags, "deny-bridges"));

  const saved = loadDelegation(id);
  const executionChainId = savedExecutionChainId(saved);
  const ctx = await createSmartAccountContext(cli.privateKey, cli.rpcUrl, executionChainId);

  if (ctx.account.address.toLowerCase() !== saved.terms.quoteSigner.toLowerCase()) {
    throw new Error("PRIVATE_KEY account must match saved terms.quoteSigner");
  }

  const chainCaps = await getChainCapabilities(executionChainId, cli.relayerUrl);
  assertSavedRelayerTarget(saved, chainCaps.targetAddress);
  const paymentToken = findUsdcToken(chainCaps);
  const redeemAccount = (saved.relayerTargetAddress ??
    saved.swapDelegation.delegate) as Address;

  const prep = await prepareSwapRedemption({
    saved,
    ctx,
    fromAmount: cli.fromAmount,
    slippage: cli.slippage,
    flags: flags as Record<string, string | boolean>,
    skipChainlink,
    requireChainlink,
    referenceRoundId,
    allowBridges,
    denyBridges,
  });

  console.log(
    formatExecuteQuoteSummary({
      lifiQuote: prep.lifiQuote,
      saved,
      quoteFetch: prep.quoteFetch,
      executionChainId,
      fromAmount: cli.fromAmount,
      fromAddress: ctx.delegator,
      apiSlippage: cli.slippage,
      allowBridges,
      denyBridges,
      verbose,
    }),
  );
  console.log("");

  const authorizationList = await buildAuthorizationList(ctx);

  const buildAtFee = (feeAmount: bigint) =>
    buildEstimateBundle({
      ctx,
      chainId: executionChainId,
      targetAddress: chainCaps.targetAddress,
      feeCollector: chainCaps.feeCollector,
      paymentToken: paymentToken.address,
      feeAmount,
      patchedSwapDelegation: prep.patchedSwapDelegation,
      lifiDiamond: saved.terms.lifiDiamond,
      diamondCalldata: prep.diamondCalldata,
      signatureMode: "valid",
      authorizationList,
    });

  let relayerEstimate: Estimate7710Result | undefined;
  let finalFeeAmount = feeAtomsOverride ?? MOCK_FEE_USDC_ATOMS;
  let validRedeemParams: RedeemParams | undefined;

  console.log("--- Context ---");
  console.log(`delegationId:        ${id}`);
  console.log(`chainId:             ${executionChainId}`);
  console.log(`delegator:           ${saved.delegator}`);
  console.log(`redeemFrom (delegate): ${redeemAccount}`);
  console.log(`delegationManager:   ${DELEGATION_MANAGER}`);
  const delegatorCode = await ctx.publicClient.getCode({ address: saved.delegator });
  console.log(`delegatorCodeLength: ${delegatorCode?.length ?? 0} (pre-override)`);
  console.log(`bogusSignature:      ${BOGUS_DELEGATION_SIGNATURE.slice(0, 18)}…`);

  if (!skipRelayer) {
    console.log("\n--- Path A: relayer_estimate7710Transaction (valid signatures) ---");
    try {
      const relayerResult = await relayerEstimateLoop({
        ctx,
        chainId: executionChainId,
        paymentToken: paymentToken.address,
        relayerUrl: cli.relayerUrl,
        buildAtFee,
      });
      relayerEstimate = relayerResult.estimate;
      finalFeeAmount = relayerResult.feeAmount;
      validRedeemParams = relayerResult.validBundle.redeemParams;
      console.log(`success:             ${relayerEstimate.success}`);
      console.log(
        `gasUsed:             ${JSON.stringify(relayerEstimate.gasUsed)}`,
      );
      console.log(
        `requiredPaymentAmount: ${relayerEstimate.requiredPaymentAmount}`,
      );
    } catch (error) {
      console.log(`success:             false`);
      console.log(`error:               ${error instanceof Error ? error.message : error}`);
      relayerEstimate = { success: false, gasUsed: {}, error: String(error) };
    }
  }

  let rpcGas: bigint | undefined;
  let incomplete = false;

  if (!skipRpc) {
    console.log("\n--- Path B: RPC redeemDelegations (bogus signatures + state override) ---");

    const bogusBundle = await buildEstimateBundle({
      ctx,
      chainId: executionChainId,
      targetAddress: chainCaps.targetAddress,
      feeCollector: chainCaps.feeCollector,
      paymentToken: paymentToken.address,
      feeAmount: finalFeeAmount,
      patchedSwapDelegation: prep.patchedSwapDelegation,
      lifiDiamond: saved.terms.lifiDiamond,
      diamondCalldata: prep.diamondCalldata,
      signatureMode: "bogus",
      authorizationList,
    });

    const redeemCalldata = encodeRedeemDelegationsCalldata(bogusBundle.redeemParams);

    const { overrides: fundingOverrides, logs: fundingLogs } =
      await buildFundingOverrides(
        ctx,
        saved.delegator as Address,
        saved.terms.inputToken,
        saved.terms.lifiDiamond,
        cli.fromAmount,
        paymentToken.address,
        finalFeeAmount,
      );

    for (const line of fundingLogs) {
      console.log(`on-chain ${line}`);
    }

    const shimOverride = buildDelegatorShimOverride(
      saved.delegator as Address,
      DELEGATOR_ESTIMATE_SHIM_CODE,
    );
    const fullOverride = mergeStateOverrides(shimOverride, fundingOverrides);

    if (!skipControl) {
      console.log("\nControl (bogus sig, ERC-20 overrides only, NO delegator shim):");
      const control = await runRpcRedeemSimulation({
        ctx,
        redeemAccount,
        redeemCalldata,
        stateOverride: fundingOverrides,
      });
      console.log(
        control.ok
          ? "  unexpected SUCCESS (expected signature revert)"
          : `  reverted as expected: ${control.revert}`,
      );
    }

    const pocCall = await runRpcRedeemSimulation({
      ctx,
      redeemAccount,
      redeemCalldata,
      stateOverride: fullOverride,
    });
    console.log(
      pocCall.ok
        ? "PoC eth_call (shim + bogus sig): success"
        : `PoC eth_call FAILED: ${pocCall.revert}`,
    );

    if (pocCall.ok) {
      try {
        rpcGas = await estimateRpcGas({
          ctx,
          redeemAccount,
          redeemCalldata,
          stateOverride: fullOverride,
        });
        console.log(`PoC eth_estimateGas: ${rpcGas.toString()}`);
      } catch (error) {
        console.log(`PoC eth_estimateGas FAILED: ${formatRevert(error)}`);
        console.log(
          "Hint: your RPC provider may not support stateOverride on eth_estimateGas.",
        );
        incomplete = true;
      }
    } else {
      incomplete = true;
      if (!skipRpcDebug) {
        console.log("\nRPC batch isolation (shim + bogus sig, same overrides):");
        await runBatchRpcDebug({
          label: "fee batch only [0]",
          ctx,
          redeemAccount,
          redeemParams: bogusBundle.redeemParams,
          batchIndices: [0],
          stateOverride: fullOverride,
        });
        await runBatchRpcDebug({
          label: "swap batch only [1]",
          ctx,
          redeemAccount,
          redeemParams: bogusBundle.redeemParams,
          batchIndices: [1],
          stateOverride: fullOverride,
        });
      }
    }

    if (validRedeemParams) {
      const validCalldata = encodeRedeemDelegationsCalldata(validRedeemParams);
      const validCall = await runRpcRedeemSimulation({
        ctx,
        redeemAccount,
        redeemCalldata: validCalldata,
        stateOverride: fundingOverrides,
      });
      console.log(
        validCall.ok
          ? "Sanity eth_call (valid sigs, no shim): success"
          : `Sanity eth_call (valid sigs): ${validCall.revert}`,
      );
    }
  }

  if (!skipRelayer && !skipRpc) {
    if (!relayerEstimate?.success || rpcGas === undefined) {
      incomplete = true;
    }
  }

  printComparison({
    chainId: executionChainId,
    relayerEstimate,
    rpcGas,
    feeAmount: finalFeeAmount,
    incomplete,
  });
}
