import {
  flagBigInt,
  flagBool,
  flagString,
  loadCliConfig,
  parseArgs,
  parseCommaList,
} from "../config.js";
import { resolveChainlinkArgs } from "../chainlink.js";
import { QUOTE_EXPIRATION_SECONDS } from "../constants.js";
import { savedExecutionChainId } from "../executionChain.js";
import {
  createFeeDelegation,
  createSmartAccountContext,
  encodeTransferCalldata,
  readAvailableBudget,
  readErc20Allowance,
} from "../delegations.js";
import {
  patchChainlinkArgs,
  patchSwapDelegationArgs,
  relayerExecution,
} from "../encodings.js";
import {
  assertQuoteDiamond,
  assertQuoteValueZero,
  fetchLiFiQuote,
  parseQuoteAmounts,
  resolveQuoteToAddress,
} from "../lifi.js";
import { deriveRouteKind, encodeQuoteArgs, signQuote, verifyQuoteSigner } from "../quote.js";
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
import { resolveExecuteSpoofParams } from "../executeSpoof.js";
import { formatExecuteQuoteSummary } from "../format.js";
import { loadDelegation } from "../store.js";
import { hashCalldata, minAmountOutMeetsSlippage, termsRecordToEncoded } from "../terms.js";
import { RouteKind, type SignedLiFiQuote } from "../types.js";

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

  const toAddress = resolveQuoteToAddress(saved, ctx.delegator);
  const quoteFetch = await resolveExecuteSpoofParams(flags, saved, toAddress);
  if (quoteFetch.spoofed) {
    console.warn(
      "Warning: enforcer testing mode — LiFi quote fetch params are spoofed; " +
        "signed quote metadata still matches saved terms. Expect on-chain revert.\n" +
        quoteFetch.spoofSummary,
    );
    console.warn(
      "Likely enforcer errors:\n" +
        quoteFetch.expectedRevertHints.map((h) => `  - ${h}`).join("\n"),
    );
  }

  let patchedSwapDelegation = saved.swapDelegation;
  let chainlinkResult;

  if (saved.chainlinkTerms && !skipChainlink) {
    chainlinkResult = await resolveChainlinkArgs(
      ctx.publicClient,
      saved.chainlinkTerms,
      referenceRoundId,
    );
    if (!chainlinkResult.passed) {
      const msg =
        `Chainlink pre-check: ${chainlinkResult.reason ?? "not met"} — proceeding to relayer (enforcer decides on-chain).`;
      if (requireChainlink) {
        throw new Error(msg);
      }
      console.warn(`Warning: ${msg}`);
    }
    patchedSwapDelegation = patchChainlinkArgs(
      patchedSwapDelegation,
      chainlinkResult.args,
    );
  }

  const lifiQuote = await fetchLiFiQuote({
    fromChain: executionChainId,
    toChain: quoteFetch.toChain,
    fromToken: saved.terms.inputToken,
    toToken: quoteFetch.toToken,
    fromAmount: cli.fromAmount,
    fromAddress: ctx.delegator,
    slippage: cli.slippage,
    toAddress: quoteFetch.toAddress,
    allowBridges,
    denyBridges,
  });

  console.log(
    formatExecuteQuoteSummary({
      lifiQuote,
      saved,
      quoteFetch,
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

  assertQuoteValueZero(lifiQuote);
  assertQuoteDiamond(lifiQuote, saved.terms.lifiDiamond);

  const { expectedAmountOut, minAmountOut } = parseQuoteAmounts(lifiQuote);
  const slippageBps = BigInt(saved.terms.slippageBps);
  if (!minAmountOutMeetsSlippage(minAmountOut, expectedAmountOut, slippageBps)) {
    const minimumAllowed =
      (expectedAmountOut * (10_000n - slippageBps)) / 10_000n;
    throw new Error(
      "LiFi quote fails on-chain slippage check: " +
        `minAmountOut ${minAmountOut} < minimumAllowed ${minimumAllowed} ` +
        `(expectedAmountOut ${expectedAmountOut}, terms.slippageBps ${slippageBps}). ` +
        "Recreate the delegation with a higher --slippage-bps if the route requires more tolerance.",
    );
  }

  const diamondCalldata = lifiQuote.transactionRequest.data;
  const signedQuote: SignedLiFiQuote = {
    delegator: saved.delegator,
    lifiDiamond: saved.terms.lifiDiamond,
    inputToken: saved.terms.inputToken,
    outputAssetId: saved.terms.outputAssetId,
    outputRecipient: saved.terms.outputRecipient,
    destinationChainId: BigInt(saved.terms.destinationChainId),
    inputAmount: cli.fromAmount,
    expectedAmountOut,
    minAmountOut,
    calldataHash: hashCalldata(diamondCalldata),
    expiration: BigInt(Math.floor(Date.now() / 1000) + QUOTE_EXPIRATION_SECONDS),
  };

  const signature = await signQuote(
    ctx.account,
    signedQuote,
    saved.delegationHash,
    executionChainId,
  );

  if (
    !(await verifyQuoteSigner(
      signedQuote,
      saved.delegationHash,
      executionChainId,
      signature,
      saved.terms.quoteSigner,
    ))
  ) {
    throw new Error("Quote signature verification failed locally");
  }

  const routeKind = deriveRouteKind(lifiQuote, executionChainId);
  patchedSwapDelegation = patchSwapDelegationArgs(
    patchedSwapDelegation,
    encodeQuoteArgs(routeKind, signedQuote, signature),
  );

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
    if (chainlinkResult) {
      console.log(`  chainlinkPassed:   ${chainlinkResult.passed}`);
      if (!chainlinkResult.passed && chainlinkResult.reason) {
        console.log(`  chainlinkReason:   ${chainlinkResult.reason}`);
      }
      console.log(`  priceNow:          ${chainlinkResult.priceNow.toString()}`);
      if (chainlinkResult.currentRoundId !== undefined) {
        console.log(
          `  currentRoundId:    ${chainlinkResult.currentRoundId.toString()}`,
        );
      }
      if (chainlinkResult.windowNewestRoundId !== undefined) {
        console.log(
          `  windowNewestRoundId: ${chainlinkResult.windowNewestRoundId.toString()}`,
        );
      }
      if (chainlinkResult.windowOldestRoundId !== undefined) {
        console.log(
          `  windowOldestRoundId: ${chainlinkResult.windowOldestRoundId.toString()}`,
        );
      }
      if (chainlinkResult.priceRef !== undefined) {
        console.log(`  priceRef:          ${chainlinkResult.priceRef.toString()}`);
      }
      if (chainlinkResult.referenceRoundId !== undefined) {
        console.log(
          `  referenceRoundId:  ${chainlinkResult.referenceRoundId.toString()}`,
        );
      }
    }
    console.log(`  inputAmount:       ${cli.fromAmount.toString()}`);
    console.log(`  expectedAmountOut: ${expectedAmountOut.toString()}`);
    console.log(`  minAmountOut:      ${minAmountOut.toString()}`);
    console.log(`  availableBefore:   ${budget.available.toString()}`);
    if (quoteFetch.spoofed) {
      console.log(`  routeKind:         ${RouteKind[routeKind]} (${routeKind})`);
      console.log(
        `  termsDestChain:    ${saved.terms.destinationChainId} (signed quote)`,
      );
      console.log(`  fetchDestChain:    ${quoteFetch.toChain} (LiFi quote)`);
      console.log(`  fetchToAddress:    ${quoteFetch.toAddress}`);
      console.log(`  fetchToToken:      ${quoteFetch.toToken}`);
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
