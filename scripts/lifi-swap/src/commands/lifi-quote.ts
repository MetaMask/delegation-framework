import {
  flagBool,
  flagNumber,
  flagString,
  parseArgs,
  parseCommaList,
  signerAddressFromEnv,
} from "../config.js";
import { formatQuoteNotFound, formatQuoteSummary } from "../format.js";
import { fetchQuote, LiFiApiError } from "../lifiApi.js";
import {
  loadAllChains,
  loadTokensForChain,
  resolveChain,
  resolveToken,
} from "../resolve.js";

function isQuoteNotFoundError(error: LiFiApiError): boolean {
  if (error.path !== "/quote") return false;
  if (error.status === 404) return true;
  return error.status === 400 && error.hasUnavailableRoutes();
}

export async function runLifiQuoteCommand(argv: string[]): Promise<void> {
  const { flags } = parseArgs(argv);

  const inputChainQuery =
    flagString(flags, "input-chain") ?? process.env.LIFI_QUOTE_INPUT_CHAIN;
  const outputChainQuery =
    flagString(flags, "output-chain") ?? process.env.LIFI_QUOTE_OUTPUT_CHAIN;
  const inputTokenQuery = flagString(flags, "input-token");
  const outputTokenQuery = flagString(flags, "output-token");
  const defaultFrom = signerAddressFromEnv();
  const inputAddress =
    flagString(flags, "input-address") ??
    process.env.LIFI_QUOTE_INPUT_ADDRESS ??
    defaultFrom;
  const outputAddress =
    flagString(flags, "output-address") ??
    process.env.LIFI_QUOTE_OUTPUT_ADDRESS ??
    inputAddress;
  const amountRaw = flagString(flags, "amount") ?? process.env.LIFI_FROM_AMOUNT;

  if (
    !inputChainQuery ||
    !outputChainQuery ||
    !inputTokenQuery ||
    !outputTokenQuery ||
    !inputAddress ||
    !outputAddress ||
    !amountRaw
  ) {
    throw new Error(
      "Usage: lifi quote --input-chain <name> --input-token <symbol> --output-chain <name> " +
        "--output-token <symbol> --amount <atoms> " +
        "[--input-address <addr>] [--output-address <addr>] " +
        "(addresses default to PRIVATE_KEY EOA; chains default to LIFI_QUOTE_*_CHAIN in .env) " +
        "[--slippage 0.005] [--order FASTEST|CHEAPEST] [--allow-bridges relay,layerswap] " +
        "[--deny-bridges hop] [--calldata] [--raw-errors] [--json] [--verbose]",
    );
  }

  const slippage = flagNumber(flags, "slippage") ?? 0.005;
  const order = flagString(flags, "order") as "FASTEST" | "CHEAPEST" | undefined;
  const asJson = flagBool(flags, "json");
  const verbose = flagBool(flags, "verbose");
  const calldata = flagBool(flags, "calldata");
  const rawErrors = flagBool(flags, "raw-errors");
  const allowBridges = parseCommaList(flagString(flags, "allow-bridges"));
  const denyBridges = parseCommaList(flagString(flags, "deny-bridges"));

  const chains = await loadAllChains();
  const inputChain = resolveChain(inputChainQuery, chains);
  const outputChain = resolveChain(outputChainQuery, chains);

  const inputTokens = await loadTokensForChain(inputChain);
  const outputTokens = await loadTokensForChain(outputChain);
  const inputToken = resolveToken(inputTokenQuery, inputChain, inputTokens);
  const outputToken = resolveToken(outputTokenQuery, outputChain, outputTokens);

  const quoteContext = {
    inputChain,
    outputChain,
    inputToken,
    outputToken,
    amountAtoms: amountRaw,
    allowBridges,
    denyBridges,
  };

  let quote;
  try {
    quote = await fetchQuote({
      fromChain: inputChain.id,
      toChain: outputChain.id,
      fromToken: inputToken.address,
      toToken: outputToken.address,
      fromAmount: BigInt(amountRaw),
      fromAddress: inputAddress,
      toAddress: outputAddress,
      slippage,
      order: order === "FASTEST" || order === "CHEAPEST" ? order : undefined,
      allowBridges,
      denyBridges,
    });
  } catch (error) {
    if (error instanceof LiFiApiError) {
      if (rawErrors) {
        console.error(error.rawBody);
        process.exit(1);
      }
      if (isQuoteNotFoundError(error)) {
        throw new Error(formatQuoteNotFound(quoteContext, error));
      }
    }
    throw error;
  }

  if (asJson) {
    console.log(JSON.stringify(quote, null, 2));
    return;
  }

  console.log(
    formatQuoteSummary(
      quote,
      {
        inputChain,
        outputChain,
        inputToken,
        outputToken,
      },
      { verbose, calldata },
    ),
  );
}
