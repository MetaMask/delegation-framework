import type { Delegation } from "@metamask/smart-accounts-kit";
import type { Address, Hex } from "viem";

import { resolveChainlinkArgs } from "./chainlink.js";
import { QUOTE_EXPIRATION_SECONDS } from "./constants.js";
import type { SmartAccountContext } from "./delegations.js";
import { patchChainlinkArgs, patchSwapDelegationArgs } from "./encodings.js";
import {
  assertQuoteDiamond,
  assertQuoteValueZero,
  fetchLiFiQuote,
  parseQuoteAmounts,
  resolveQuoteToAddress,
  type LiFiQuoteResponse,
} from "./lifi.js";
import { deriveRouteKind, encodeQuoteArgs, signQuote, verifyQuoteSigner } from "./quote.js";
import {
  resolveExecuteSpoofParams,
  type QuoteFetchOverrides,
} from "./executeSpoof.js";
import { hashCalldata, minAmountOutMeetsSlippage } from "./terms.js";
import type { SavedDelegation, SignedLiFiQuote } from "./types.js";

export type PrepareSwapRedemptionInput = {
  saved: SavedDelegation;
  ctx: SmartAccountContext;
  fromAmount: bigint;
  slippage: number;
  flags: Record<string, string | boolean>;
  skipChainlink: boolean;
  requireChainlink: boolean;
  referenceRoundId?: bigint;
  allowBridges?: string[];
  denyBridges?: string[];
};

export type PrepareSwapRedemptionResult = {
  patchedSwapDelegation: Delegation;
  diamondCalldata: Hex;
  lifiQuote: LiFiQuoteResponse;
  quoteFetch: QuoteFetchOverrides;
  expectedAmountOut: bigint;
  minAmountOut: bigint;
  routeKind: ReturnType<typeof deriveRouteKind>;
};

export async function prepareSwapRedemption(
  input: PrepareSwapRedemptionInput,
): Promise<PrepareSwapRedemptionResult> {
  const {
    saved,
    ctx,
    fromAmount,
    slippage,
    flags,
    skipChainlink,
    requireChainlink,
    referenceRoundId,
    allowBridges,
    denyBridges,
  } = input;

  const executionChainId = saved.chainId ?? ctx.chainId;
  const toAddress = resolveQuoteToAddress(saved, ctx.delegator);
  const quoteFetch = await resolveExecuteSpoofParams(flags, saved, toAddress);

  let patchedSwapDelegation = saved.swapDelegation;

  if (saved.chainlinkTerms && !skipChainlink) {
    const chainlinkResult = await resolveChainlinkArgs(
      ctx.publicClient,
      saved.chainlinkTerms,
      referenceRoundId,
    );
    if (!chainlinkResult.passed) {
      const msg =
        `Chainlink pre-check: ${chainlinkResult.reason ?? "not met"} — proceeding (enforcer decides on-chain).`;
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
    fromAmount,
    fromAddress: ctx.delegator,
    slippage,
    toAddress: quoteFetch.toAddress,
    allowBridges,
    denyBridges,
  });

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
        `(expectedAmountOut ${expectedAmountOut}, terms.slippageBps ${slippageBps}).`,
    );
  }

  const diamondCalldata = lifiQuote.transactionRequest.data as Hex;
  const signedQuote: SignedLiFiQuote = {
    delegator: saved.delegator as Address,
    lifiDiamond: saved.terms.lifiDiamond,
    inputToken: saved.terms.inputToken,
    outputAssetId: saved.terms.outputAssetId,
    outputRecipient: saved.terms.outputRecipient,
    destinationChainId: BigInt(saved.terms.destinationChainId),
    inputAmount: fromAmount,
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

  return {
    patchedSwapDelegation,
    diamondCalldata,
    lifiQuote,
    quoteFetch,
    expectedAmountOut,
    minAmountOut,
    routeKind,
  };
}
