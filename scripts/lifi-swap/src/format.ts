import type { Address } from "viem";

import type { QuoteFetchOverrides } from "./executeSpoof.js";
import { minAmountOutMeetsSlippage } from "./terms.js";
import type {
  LiFiApiError,
  LiFiChain,
  LiFiFeeCost,
  LiFiGasCost,
  LiFiQuoteStep,
  LiFiToken,
  LiFiToolError,
} from "./lifiApi.js";
import type { SavedDelegation } from "./types.js";

export function formatTokenAmount(atoms: string, decimals: number): string {
  const value = BigInt(atoms);
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const fraction = abs % base;
  const fractionStr = fraction.toString().padStart(decimals, "0").replace(/0+$/, "");
  const formatted = fractionStr ? `${whole}.${fractionStr}` : whole.toString();
  return negative ? `-${formatted}` : formatted;
}

export type ResolvedQuoteContext = {
  inputChain: LiFiChain;
  outputChain: LiFiChain;
  inputToken: LiFiToken;
  outputToken: LiFiToken;
};

export type QuoteNotFoundContext = ResolvedQuoteContext & {
  amountAtoms: string;
  allowBridges?: string[];
  denyBridges?: string[];
};

const MAX_ROUTE_ERROR_LINES = 5;

function truncatePath(path: string, maxLen = 60): string {
  if (path.length <= maxLen) return path;
  const half = Math.floor((maxLen - 3) / 2);
  return `${path.slice(0, half)}...${path.slice(-half)}`;
}

function collectFailedToolErrors(error: LiFiApiError): LiFiToolError[] {
  const seen = new Set<string>();
  const results: LiFiToolError[] = [];

  for (const failed of error.unavailableRoutes?.failed ?? []) {
    if (!failed.subpaths) continue;
    for (const entries of Object.values(failed.subpaths)) {
      for (const entry of entries) {
        const key = `${entry.tool ?? "?"}|${entry.code ?? ""}|${entry.message ?? ""}`;
        if (seen.has(key)) continue;
        seen.add(key);
        results.push(entry);
      }
    }
  }

  return results;
}

export function formatQuoteNotFound(
  context: QuoteNotFoundContext,
  error: LiFiApiError,
): string {
  const lines: string[] = ["No route found for this transfer.", ""];

  lines.push(
    `Route:  ${context.inputChain.name} ${context.inputToken.symbol} → ${context.outputChain.name} ${context.outputToken.symbol}`,
  );
  lines.push(
    `Amount: ${formatTokenAmount(context.amountAtoms, context.inputToken.decimals)} ${context.inputToken.symbol} (${context.amountAtoms} atoms)`,
  );

  const filterParts: string[] = [];
  if (context.allowBridges?.length) {
    filterParts.push(`allow-bridges=${context.allowBridges.join(",")}`);
  }
  if (context.denyBridges?.length) {
    filterParts.push(`deny-bridges=${context.denyBridges.join(",")}`);
  }
  if (filterParts.length > 0) {
    lines.push(`Filters: ${filterParts.join("  ")}`);
  }

  lines.push("");
  const codePart = error.code !== undefined ? ` (code ${error.code})` : "";
  lines.push(`LiFi: ${error.apiMessage ?? "No available quotes"}${codePart}`);

  const filteredOut = error.unavailableRoutes?.filteredOut ?? [];
  if (filteredOut.length > 0) {
    lines.push("");
    lines.push(`Filtered out (${Math.min(filteredOut.length, MAX_ROUTE_ERROR_LINES)} shown):`);
    for (const entry of filteredOut.slice(0, MAX_ROUTE_ERROR_LINES)) {
      lines.push(`  • ${truncatePath(entry.overallPath)} — ${entry.reason}`);
    }
    if (filteredOut.length > MAX_ROUTE_ERROR_LINES) {
      lines.push(`  ... and ${filteredOut.length - MAX_ROUTE_ERROR_LINES} more`);
    }
  }

  const failedTools = collectFailedToolErrors(error);
  if (failedTools.length > 0) {
    lines.push("");
    lines.push(`Failed tools (${Math.min(failedTools.length, MAX_ROUTE_ERROR_LINES)} shown):`);
    for (const entry of failedTools.slice(0, MAX_ROUTE_ERROR_LINES)) {
      const tool = entry.tool ?? "?";
      const code = entry.code ?? entry.errorType ?? "?";
      const message = entry.message ?? "";
      lines.push(`  • ${tool} — ${code}${message ? `: ${message}` : ""}`);
    }
    if (failedTools.length > MAX_ROUTE_ERROR_LINES) {
      lines.push(`  ... and ${failedTools.length - MAX_ROUTE_ERROR_LINES} more`);
    }
  }

  lines.push("");
  lines.push(
    `Tip: npm run lifi -- connections --from-chain ${context.inputChain.name} --to-chain ${context.outputChain.name} --from-token ${context.inputToken.symbol}`,
  );
  lines.push("     npm run lifi -- tools");

  return lines.join("\n");
}

function sumUsd(items: Array<{ amountUSD?: string }>): string | undefined {
  let total = 0;
  let hasAny = false;
  for (const item of items) {
    if (item.amountUSD === undefined) continue;
    const n = Number(item.amountUSD);
    if (!Number.isFinite(n)) continue;
    total += n;
    hasAny = true;
  }
  return hasAny ? total.toFixed(4) : undefined;
}

function formatCostLines(
  label: string,
  items: Array<LiFiFeeCost | LiFiGasCost>,
): string[] {
  if (items.length === 0) return [];
  const usd = sumUsd(items);
  const lines = [`${label}:`];
  for (const item of items) {
    const token = item.token;
    const symbol = token?.symbol ?? "?";
    const decimals = token?.decimals ?? 18;
    const amount = "amount" in item && item.amount ? formatTokenAmount(item.amount, decimals) : "?";
    const name = "name" in item ? item.name : item.type;
    const usdPart = item.amountUSD ? ` (~$${item.amountUSD})` : "";
    lines.push(`  - ${name}: ${amount} ${symbol}${usdPart}`);
  }
  if (usd) {
    lines.push(`  total USD: $${usd}`);
  }
  return lines;
}

export function formatQuoteSummary(
  quote: LiFiQuoteStep,
  resolved: ResolvedQuoteContext,
  options: { verbose?: boolean; calldata?: boolean } = {},
): string {
  const lines: string[] = [];
  const fromToken = quote.action?.fromToken ?? resolved.inputToken;
  const toToken = quote.action?.toToken ?? resolved.outputToken;
  const estimate = quote.estimate;

  lines.push(
    `Route: ${resolved.inputChain.name} ${fromToken.symbol} → ${resolved.outputChain.name} ${toToken.symbol}`,
  );
  lines.push(`Tool:  ${quote.tool} (${quote.type})`);

  if (estimate) {
    lines.push(
      `From:  ${formatTokenAmount(estimate.fromAmount, fromToken.decimals)} ${fromToken.symbol} (${estimate.fromAmount} atoms)`,
    );
    if (estimate.fromAmountUSD) {
      lines.push(`       ~$${estimate.fromAmountUSD}`);
    }
    lines.push(
      `To:    ${formatTokenAmount(estimate.toAmount, toToken.decimals)} ${toToken.symbol} (min ${formatTokenAmount(estimate.toAmountMin, toToken.decimals)})`,
    );
    if (estimate.toAmountUSD) {
      lines.push(`       ~$${estimate.toAmountUSD}`);
    }
    if (estimate.executionDuration !== undefined) {
      lines.push(`ETA:   ~${estimate.executionDuration}s`);
    }
    if (quote.action?.slippage !== undefined) {
      lines.push(`Slippage: ${(quote.action.slippage * 100).toFixed(2)}%`);
    }
    lines.push(...formatCostLines("Fees", estimate.feeCosts ?? []));
    lines.push(...formatCostLines("Gas", estimate.gasCosts ?? []));
    if (estimate.approvalAddress) {
      lines.push(`Approval: ${estimate.approvalAddress}`);
    }
  }

  lines.push(`Resolved input:  ${fromToken.symbol} @ ${fromToken.address} (chain ${fromToken.chainId})`);
  lines.push(`Resolved output: ${toToken.symbol} @ ${toToken.address} (chain ${toToken.chainId})`);

  if (options.verbose && quote.transactionRequest) {
    const tx = quote.transactionRequest;
    lines.push("");
    lines.push("Transaction request:");
    lines.push(`  to:        ${tx.to}`);
    lines.push(`  chainId:   ${tx.chainId ?? "?"}`);
    lines.push(`  value:     ${tx.value}`);
    lines.push(`  data len:  ${tx.data.length} chars`);
    if (tx.gasLimit) lines.push(`  gasLimit:  ${tx.gasLimit}`);
    if (tx.gasPrice) lines.push(`  gasPrice:  ${tx.gasPrice}`);
  }

  if (quote.includedSteps && quote.includedSteps.length > 0) {
    lines.push("");
    lines.push("Steps:");
    for (const step of quote.includedSteps) {
      lines.push(`  - ${step.type} via ${step.tool}`);
    }
  }

  if (options.calldata) {
    lines.push("");
    if (quote.transactionRequest?.data) {
      lines.push("Calldata:");
      lines.push(quote.transactionRequest.data);
    } else {
      lines.push("Calldata: (not returned by quote)");
    }
  }

  return lines.join("\n");
}

function chainLabel(chainId: number, name?: string): string {
  return name ? `${chainId} (${name})` : `Chain ${chainId}`;
}

function stubChain(chainId: number, name?: string): LiFiChain {
  const displayName = name ?? `Chain ${chainId}`;
  return {
    key: String(chainId),
    name: displayName,
    coin: displayName,
    id: chainId,
    mainnet: true,
  };
}

function fallbackToken(params: {
  address: string;
  chainId: number;
  symbol?: string;
  decimals?: number;
}): LiFiToken {
  return {
    address: params.address,
    chainId: params.chainId,
    symbol: params.symbol ?? params.address.slice(0, 10),
    name: params.symbol ?? params.address,
    decimals: params.decimals ?? 18,
  };
}

function buildExecuteQuoteContext(
  saved: SavedDelegation,
  lifiQuote: LiFiQuoteStep,
  executionChainId: number,
  quoteFetch: QuoteFetchOverrides,
): ResolvedQuoteContext {
  const inputChain = stubChain(executionChainId, saved.metadata?.inputChain);
  const outputChain = stubChain(
    quoteFetch.toChain,
    quoteFetch.toChain === Number(saved.terms.destinationChainId)
      ? saved.metadata?.outputChain
      : undefined,
  );

  const inputToken =
    lifiQuote.action?.fromToken ??
    fallbackToken({
      address: saved.terms.inputToken,
      chainId: executionChainId,
      symbol: saved.metadata?.inputSymbol,
      decimals: 6,
    });

  const outputToken =
    lifiQuote.action?.toToken ??
    fallbackToken({
      address: quoteFetch.toToken,
      chainId: quoteFetch.toChain,
      symbol: saved.metadata?.outputSymbol,
    });

  return { inputChain, outputChain, inputToken, outputToken };
}

export type ExecuteQuoteSummaryParams = {
  lifiQuote: LiFiQuoteStep;
  saved: SavedDelegation;
  quoteFetch: QuoteFetchOverrides;
  executionChainId: number;
  fromAmount: bigint;
  fromAddress: Address;
  apiSlippage: number;
  allowBridges?: string[];
  denyBridges?: string[];
  verbose?: boolean;
};

export function formatExecuteQuoteSummary(params: ExecuteQuoteSummaryParams): string {
  const {
    lifiQuote,
    saved,
    quoteFetch,
    executionChainId,
    fromAmount,
    fromAddress,
    apiSlippage,
    allowBridges,
    denyBridges,
    verbose,
  } = params;

  const requestLines: string[] = ["LiFi quote request:"];
  requestLines.push(
    `  fromChain:   ${chainLabel(executionChainId, saved.metadata?.inputChain)}`,
  );
  const fetchDestName =
    quoteFetch.toChain === Number(saved.terms.destinationChainId)
      ? saved.metadata?.outputChain
      : undefined;
  requestLines.push(`  toChain:     ${chainLabel(quoteFetch.toChain, fetchDestName)}`);
  requestLines.push(`  fromToken:   ${saved.terms.inputToken}`);
  requestLines.push(`  toToken:     ${quoteFetch.toToken}`);
  requestLines.push(`  fromAmount:  ${fromAmount.toString()} atoms`);
  requestLines.push(`  fromAddress: ${fromAddress}`);
  requestLines.push(`  toAddress:   ${quoteFetch.toAddress}`);
  requestLines.push(
    `  slippage:    ${apiSlippage} (${(apiSlippage * 100).toFixed(2)}%)`,
  );
  requestLines.push(
    `  termsSlippageBps: ${saved.terms.slippageBps} (on-chain cap; recreate with --slippage-bps to change)`,
  );
  if (allowBridges?.length) {
    requestLines.push(`  allow-bridges: ${allowBridges.join(",")}`);
  }
  if (denyBridges?.length) {
    requestLines.push(`  deny-bridges:  ${denyBridges.join(",")}`);
  }

  if (quoteFetch.spoofed) {
    requestLines.push(
      `  signedTerms: destinationChainId=${saved.terms.destinationChainId} (quote metadata unchanged)`,
    );
  }

  const resolved = buildExecuteQuoteContext(
    saved,
    lifiQuote,
    executionChainId,
    quoteFetch,
  );

  const lines = [
    requestLines.join("\n"),
    "",
    formatQuoteSummary(lifiQuote, resolved, { verbose }),
  ];

  const estimate = lifiQuote.estimate;
  if (estimate) {
    const expectedAmountOut = BigInt(estimate.toAmount);
    const minAmountOut = BigInt(estimate.toAmountMin);
    const slippageBps = BigInt(saved.terms.slippageBps);
    const minimumAllowed =
      expectedAmountOut === 0n
        ? 0n
        : (expectedAmountOut * (10_000n - slippageBps)) / 10_000n;
    const passes = minAmountOutMeetsSlippage(
      minAmountOut,
      expectedAmountOut,
      slippageBps,
    );
    lines.push("");
    lines.push(`Enforcer slippage check (terms.slippageBps=${saved.terms.slippageBps}):`);
    lines.push(`  expectedAmountOut: ${expectedAmountOut.toString()}`);
    lines.push(`  minAmountOut:      ${minAmountOut.toString()}`);
    lines.push(`  minimumAllowed:    ${minimumAllowed.toString()} (min must be >= this)`);
    lines.push(`  passes:            ${passes ? "yes" : "no"}`);
  }

  return lines.join("\n");
}

export function padColumns(rows: string[][], minGap = 2): string {
  if (rows.length === 0) return "";
  const colCount = Math.max(...rows.map((r) => r.length));
  const widths = Array.from({ length: colCount }, (_, col) =>
    Math.max(...rows.map((row) => (row[col] ?? "").length)),
  );
  const gap = " ".repeat(minGap);

  return rows
    .map((row) =>
      row.map((cell, i) => (cell ?? "").padEnd(widths[i]!)).join(gap),
    )
    .join("\n");
}
