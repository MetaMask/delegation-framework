import { getAddress, zeroAddress } from "viem";

import {
  flagBigInt,
  flagBool,
  flagNumber,
  flagString,
  loadChainlinkEnvConfig,
  loadCliConfig,
  parseArgs,
  parseChainlinkCreateFlags,
} from "../config.js";
import {
  createApproveDelegation,
  createPriceGatedSwapDelegation,
  createSmartAccountContext,
} from "../delegations.js";
import { resolveTermsEncodings } from "../lifi.js";
import { getChainCapabilities } from "../relayer.js";
import {
  formatResolvedRoute,
  inputTokenAsAddress,
  resolveCreateRoute,
  resolveLiFiDiamond,
  resolveOutputRecipient,
  type ResolvedRoute,
} from "../routeConfig.js";
import { delegationExists, saveDelegation } from "../store.js";
import type { ChainlinkTermsRecord, CliConfig, LiFiTermsRecord, SavedDelegation } from "../types.js";

function defaultId(route: ResolvedRoute, cli: CliConfig, ruleKind: string): string {
  return `chainlink-${ruleKind}-${route.inputChain.key}-${route.inputToken.symbol}-${route.outputToken.symbol}-${cli.periodAmount}-${cli.periodDuration}s`;
}

export async function runCreateChainlinkCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);
  const chainlinkParams = parseChainlinkCreateFlags(flags);
  const chainlinkEnv = loadChainlinkEnvConfig();

  const lifiDiamondFlag = flagString(flags, "lifi-diamond");
  const cli = loadCliConfig({
    fromAmount: flagBigInt(flags, "amount") ?? undefined,
    periodAmount: flagBigInt(flags, "period-amount"),
    periodDuration: flagNumber(flags, "period-duration"),
    slippageBps: flagNumber(flags, "slippage-bps"),
    outputRecipient: flagString(flags, "output-recipient"),
    lifiDiamondOverride: lifiDiamondFlag ? getAddress(lifiDiamondFlag) : undefined,
  });

  const route = await resolveCreateRoute(flags);
  const id =
    flagString(flags, "id") ?? defaultId(route, cli, chainlinkParams.ruleKind);
  const name = flagString(flags, "name") ?? id;
  const force = flagBool(flags, "force");
  const inputToken = inputTokenAsAddress(route.inputToken);
  const withApprove =
    !flagBool(flags, "no-approve") && inputToken.toLowerCase() !== zeroAddress;

  if (delegationExists(id) && !force) {
    throw new Error(`Delegation "${id}" already exists. Pass --force to overwrite.`);
  }

  const ctx = await createSmartAccountContext(cli.privateKey, cli.rpcUrl, route.fromChainId);
  const chainCaps = await getChainCapabilities(route.fromChainId, cli.relayerUrl);

  const outputRecipient = resolveOutputRecipient(
    route,
    getAddress(ctx.delegator),
    flags,
    cli.outputRecipient,
  );

  console.log(formatResolvedRoute(route));
  console.log("");

  const lifiDiamond = resolveLiFiDiamond(route.inputChain, cli.lifiDiamondOverride);
  const startDate = BigInt(Math.floor(Date.now() / 1000));

  const { outputAssetId, outputRecipient: outputRecipientBytes32 } = resolveTermsEncodings({
    toChain: route.toChainId,
    sourceChain: route.fromChainId,
    toToken: route.toToken,
    outputRecipient,
    outputChain: route.outputChain,
    outputAssetIdOverride: cli.outputAssetIdOverride,
    outputRecipientBytes32Override: cli.outputRecipientBytes32Override,
  });

  const chainlinkTerms: ChainlinkTermsRecord = {
    priceFeed: chainlinkEnv.priceFeed,
    ruleKind: chainlinkParams.ruleKind,
    expectedDecimals: 0,
    windowSeconds: String(chainlinkParams.windowSeconds),
    thresholdBps: chainlinkParams.thresholdBps,
    maxStaleSeconds: String(chainlinkEnv.maxStaleSeconds),
    minGapSeconds: String(chainlinkEnv.minGapSeconds),
    triggerPrice: chainlinkParams.triggerPrice.toString(),
  };

  const lifiTerms: LiFiTermsRecord = {
    lifiDiamond,
    inputToken,
    outputAssetId,
    outputRecipient: outputRecipientBytes32,
    destinationChainId: String(route.toChainId),
    quoteSigner: ctx.account.address,
    periodAmount: cli.periodAmount.toString(),
    periodDuration: String(cli.periodDuration),
    startDate: startDate.toString(),
    slippageBps: cli.slippageBps,
  };

  const {
    delegation: swapDelegation,
    delegationHash,
    chainlinkTerms: resolvedChainlinkTerms,
    chainlinkTermsBytes,
    lifiTermsBytes,
  } = await createPriceGatedSwapDelegation(
    ctx,
    chainCaps.targetAddress,
    chainlinkTerms,
    lifiTerms,
  );

  let approveDelegation;
  if (withApprove) {
    approveDelegation = await createApproveDelegation(
      ctx,
      chainCaps.targetAddress,
      inputToken,
      lifiDiamond,
    );
  }

  const saved: SavedDelegation = {
    id,
    name,
    createdAt: new Date().toISOString(),
    chainId: route.fromChainId,
    delegator: ctx.delegator,
    delegationHash,
    toToken: route.toToken,
    relayerTargetAddress: chainCaps.targetAddress,
    relayerUrl: cli.relayerUrl,
    terms: lifiTerms,
    swapDelegation,
    approveDelegation,
    chainlinkTerms: resolvedChainlinkTerms,
    delegationType: "chainlink-lifi",
    metadata: {
      inputChain: route.inputChain.name,
      outputChain: route.outputChain.name,
      inputSymbol: route.inputToken.symbol,
      outputSymbol: route.outputToken.symbol,
      toChain: String(route.toChainId),
      outputRecipient,
    },
  };

  const path = saveDelegation(saved, { force });

  console.log("Saved price-gated delegation:");
  console.log(`  id:              ${id}`);
  console.log(`  path:            ${path}`);
  console.log(`  executionChain:  ${route.fromChainId} (${route.inputChain.name})`);
  console.log(`  delegator:       ${ctx.delegator}`);
  console.log(`  delegationHash:  ${delegationHash}`);
  console.log(`  ruleKind:        ${resolvedChainlinkTerms.ruleKind}`);
  console.log(`  priceFeed:       ${resolvedChainlinkTerms.priceFeed}`);
  console.log(`  windowSeconds:   ${resolvedChainlinkTerms.windowSeconds}`);
  console.log(`  thresholdBps:    ${resolvedChainlinkTerms.thresholdBps}`);
  console.log(`  triggerPrice:    ${resolvedChainlinkTerms.triggerPrice}`);
  console.log(`  maxStaleSeconds: ${resolvedChainlinkTerms.maxStaleSeconds}`);
  console.log(`  minGapSeconds:   ${resolvedChainlinkTerms.minGapSeconds}`);
  console.log(`  expectedDecimals:${resolvedChainlinkTerms.expectedDecimals}`);
  console.log(`  chainlinkTerms:  ${chainlinkTermsBytes}`);
  console.log(`  lifiDiamond:     ${lifiDiamond}`);
  console.log(`  toChain:         ${route.toChainId}`);
  console.log(`  toToken:         ${route.toToken}`);
  console.log(`  liFiToAddress:   ${outputRecipient}`);
  console.log(`  periodAmount:    ${lifiTerms.periodAmount}`);
  console.log(`  periodDuration:  ${lifiTerms.periodDuration}s`);
  console.log(`  lifiTermsBytes:  ${lifiTermsBytes}`);
  console.log(`  relayerTarget:   ${saved.relayerTargetAddress}`);
  console.log("");
  console.log(`Next: npm run chainlink -- check ${id}`);
}
