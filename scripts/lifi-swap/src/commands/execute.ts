import {
  flagBigInt,
  flagBool,
  flagString,
  loadCliConfig,
  parseArgs,
  parseCommaList,
} from "../config.js";
import { savedExecutionChainId } from "../executionChain.js";
import {
  createFeeDelegation,
  createSmartAccountContext,
  encodeTransferCalldata,
  readAvailableBudget,
  readErc20Allowance,
} from "../delegations.js";
import { relayerExecution } from "../encodings.js";
import {
  estimateAndPrepareSend,
  logEstimateResult,
  sendPreparedTransaction,
} from "../relaySubmit.js";
import {
  assertSavedRelayerTarget,
  findUsdcToken,
  getChainCapabilities,
  pollUntilTerminal,
  serializeDelegations,
} from "../relayer.js";
import { formatExecuteQuoteSummary } from "../format.js";
import { prepareSwapRedemption } from "../prepareSwapRedemption.js";
import { loadDelegation } from "../store.js";
import { termsRecordToEncoded } from "../terms.js";
import { RouteKind } from "../types.js";

export async function runExecuteCommand(argv: string[]): Promise<void> {
  const { positional, flags } = parseArgs(argv);
  const id = positional[0];
  if (!id) {
    throw new Error("Usage: execute <id> [--amount <atoms>] [--dry-run] [--skip-approve]");
  }

  const dryRun = flagBool(flags, "dry-run");
  const verbose = flagBool(flags, "verbose");
  const skipApprove = flagBool(flags, "skip-approve");
  const skipChainlink = flagBool(flags, "skip-chainlink");
  const requireChainlink = flagBool(flags, "require-chainlink");
  const referenceRoundRaw = flagString(flags, "reference-round-id");
  const referenceRoundId =
    referenceRoundRaw !== undefined ? BigInt(referenceRoundRaw) : undefined;
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

  if (!skipApprove) {
    const allowance = await readErc20Allowance(
      ctx,
      saved.terms.inputToken,
      saved.terms.lifiDiamond,
    );
    if (allowance < cli.fromAmount) {
      throw new Error(
        `Insufficient allowance (${allowance}). Run: npm run approve -- ${id}`,
      );
    }
  }

  const termsBytes = termsRecordToEncoded(saved.terms);
  const budget = await readAvailableBudget(ctx, saved.delegationHash, termsBytes);
  if (cli.fromAmount > budget.available) {
    console.warn(
      `Warning: requested amount ${cli.fromAmount} exceeds available period budget ${budget.available}. ` +
        `Proceeding to relayer — LiFiSwapEnforcer may revert (period-amount-exceeded).`,
    );
  }

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

  if (prep.quoteFetch.spoofed) {
    console.warn(
      "Warning: enforcer testing mode — LiFi quote fetch params are spoofed; " +
        "signed quote metadata still matches saved terms. Expect on-chain revert.\n" +
        prep.quoteFetch.spoofSummary,
    );
    console.warn(
      "Likely enforcer errors:\n" +
        prep.quoteFetch.expectedRevertHints.map((h) => `  - ${h}`).join("\n"),
    );
  }

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

  const diamondCalldata = prep.diamondCalldata;
  const patchedSwapDelegation = prep.patchedSwapDelegation;
  const { expectedAmountOut, minAmountOut } = prep;
  const paymentToken = findUsdcToken(chainCaps);

  const prepared = await estimateAndPrepareSend({
    ctx,
    chainId: executionChainId,
    paymentToken: paymentToken.address,
    relayerUrl: cli.relayerUrl,
    buildSendParams: async (feeAmount) => {
      const feeDelegation = await createFeeDelegation(
        ctx,
        chainCaps.targetAddress,
        paymentToken.address,
        feeAmount,
      );
      return {
        chainId: String(executionChainId),
        transactions: [
          {
            permissionContext: serializeDelegations([feeDelegation]),
            executions: [
              relayerExecution(
                paymentToken.address,
                0n,
                encodeTransferCalldata(chainCaps.feeCollector, feeAmount),
              ),
            ],
          },
          {
            permissionContext: serializeDelegations([patchedSwapDelegation]),
            executions: [relayerExecution(saved.terms.lifiDiamond, 0n, diamondCalldata)],
          },
        ],
      };
    },
  });

  if (dryRun) {
    console.log("Dry run execute estimate succeeded.");
    console.log(`  inputAmount:       ${cli.fromAmount.toString()}`);
    console.log(`  expectedAmountOut: ${expectedAmountOut.toString()}`);
    console.log(`  minAmountOut:      ${minAmountOut.toString()}`);
    console.log(`  availableBefore:   ${budget.available.toString()}`);
    if (prep.quoteFetch.spoofed) {
      console.log(`  routeKind:         ${RouteKind[prep.routeKind]} (${prep.routeKind})`);
    }
    logEstimateResult(prepared.estimate, " ");
    return;
  }

  const taskId = await sendPreparedTransaction(prepared, cli.relayerUrl, {
    memo: `lifi-swap:${id}`,
  });

  console.log(`Swap submitted. taskId=${taskId}`);
  logEstimateResult(prepared.estimate);

  const result = await pollUntilTerminal(taskId, cli.relayerUrl);
  if (!result.ok) {
    throw new Error(`Swap failed: ${result.reason ?? "unknown"}`);
  }

  const budgetAfter = await readAvailableBudget(ctx, saved.delegationHash, termsBytes);
  console.log(`Swap confirmed. tx=${result.hash}`);
  console.log(`  availableAfter: ${budgetAfter.available.toString()}`);
}
