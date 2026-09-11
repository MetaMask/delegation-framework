import type { Address, Hex } from "viem";

import { LIFI_API_BASE } from "./constants.js";

export type LiFiToken = {
  address: string;
  chainId: number;
  decimals: number;
  symbol: string;
  name: string;
  coinKey?: string;
  logoURI?: string;
  priceUSD?: string;
  verificationStatus?: string;
  tags?: string[];
};

export type LiFiChain = {
  key: string;
  chainType?: string;
  name: string;
  coin: string;
  id: number;
  mainnet: boolean;
  logoURI?: string;
  diamondAddress?: string;
  metamask?: {
    chainId?: string;
    chainName?: string;
  };
  nativeToken?: LiFiToken;
};

export type LiFiBridge = {
  key: string;
  name: string;
  logoURI?: string;
  supportedChains?: Array<{ fromChainId: string | number; toChainId: string | number }>;
};

export type LiFiExchange = {
  key: string;
  name: string;
  logoURI?: string;
  supportedChains?: string[] | number[];
};

export type LiFiTools = {
  bridges: LiFiBridge[];
  exchanges: LiFiExchange[];
};

export type LiFiBaseToken = {
  address: string;
  chainId: number;
};

export type LiFiConnection = {
  fromChainId: number;
  toChainId: number;
  fromTokens: LiFiBaseToken[];
  toTokens: LiFiBaseToken[];
};

export type LiFiFeeCost = {
  name: string;
  description?: string;
  percentage?: string;
  amount?: string;
  amountUSD?: string;
  included?: boolean;
  token?: LiFiToken;
};

export type LiFiGasCost = {
  type: string;
  price?: string;
  estimate?: string;
  limit?: string;
  amount: string;
  amountUSD?: string;
  token?: LiFiToken;
};

export type LiFiQuoteStep = {
  id: string;
  type: string;
  tool: string;
  toolDetails?: { key: string; name: string; logoURI?: string };
  action?: {
    fromChainId: number;
    toChainId: number;
    fromAmount: string;
    slippage?: number;
    fromAddress?: string;
    toAddress?: string;
    fromToken?: LiFiToken;
    toToken?: LiFiToken;
  };
  estimate?: {
    tool?: string;
    fromAmount: string;
    fromAmountUSD?: string;
    toAmount: string;
    toAmountMin: string;
    toAmountUSD?: string;
    approvalAddress?: string;
    executionDuration?: number;
    feeCosts?: LiFiFeeCost[];
    gasCosts?: LiFiGasCost[];
  };
  transactionRequest?: {
    to: Address;
    data: Hex;
    value: string;
    from?: Address;
    chainId?: number;
    gasLimit?: string;
    gasPrice?: string;
  };
  includedSteps?: LiFiQuoteStep[];
};

export type LiFiQuoteResponse = LiFiQuoteStep;

export type LiFiExecutableQuote = LiFiQuoteStep & {
  transactionRequest: NonNullable<LiFiQuoteStep["transactionRequest"]>;
  estimate: NonNullable<LiFiQuoteStep["estimate"]>;
};

type QueryValue = string | number | boolean | undefined;
type QueryParams = Record<string, QueryValue | QueryValue[]>;

export type LiFiToolError = {
  tool?: string;
  code?: string;
  message?: string;
  errorType?: string;
};

export type LiFiUnavailableRoutes = {
  filteredOut?: Array<{ overallPath: string; reason: string }>;
  failed?: Array<{
    overallPath: string;
    subpaths?: Record<string, LiFiToolError[]>;
  }>;
};

export type LiFiErrorBody = {
  message?: string;
  code?: number;
  errors?: LiFiUnavailableRoutes;
};

export class LiFiApiError extends Error {
  readonly status: number;
  readonly path: string;
  readonly code?: number;
  readonly apiMessage?: string;
  readonly unavailableRoutes?: LiFiUnavailableRoutes;
  readonly rawBody: string;

  constructor(params: {
    status: number;
    path: string;
    rawBody: string;
    parsed?: LiFiErrorBody;
  }) {
    const { status, path, rawBody, parsed } = params;
    const apiMessage = parsed?.message;
    const code = parsed?.code;
    const codePart = code !== undefined ? ` (code ${code})` : "";
    const detail = apiMessage ?? rawBody.slice(0, 200);
    super(`LiFi API ${path} failed (${status})${codePart}: ${detail}`);
    this.name = "LiFiApiError";
    this.status = status;
    this.path = path;
    this.code = code;
    this.apiMessage = apiMessage;
    this.unavailableRoutes = parsed?.errors;
    this.rawBody = rawBody;
  }

  hasUnavailableRoutes(): boolean {
    const routes = this.unavailableRoutes;
    if (!routes) return false;
    return (routes.filteredOut?.length ?? 0) > 0 || (routes.failed?.length ?? 0) > 0;
  }
}

function parseErrorBody(body: string): LiFiErrorBody | undefined {
  try {
    return JSON.parse(body) as LiFiErrorBody;
  } catch {
    return undefined;
  }
}

function getApiKey(): string | undefined {
  return process.env.LIFI_API_KEY;
}

export async function lifiFetch<T>(
  path: string,
  query: QueryParams = {},
): Promise<T> {
  const url = new URL(`${LIFI_API_BASE}${path}`);

  for (const [key, value] of Object.entries(query)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) {
      for (const item of value) {
        if (item !== undefined) {
          url.searchParams.append(key, String(item));
        }
      }
    } else {
      url.searchParams.set(key, String(value));
    }
  }

  const headers: Record<string, string> = {};
  const apiKey = getApiKey();
  if (apiKey) {
    headers["x-lifi-api-key"] = apiKey;
  }

  const response = await fetch(url, { headers });
  if (!response.ok) {
    const body = await response.text();
    throw new LiFiApiError({
      status: response.status,
      path,
      rawBody: body,
      parsed: parseErrorBody(body),
    });
  }

  return (await response.json()) as T;
}

export async function fetchChains(params: {
  chainTypes?: string;
} = {}): Promise<{ chains: LiFiChain[] }> {
  return lifiFetch("/chains", {
    chainTypes: params.chainTypes ?? "EVM,SVM,UTXO,MVM,TVM",
  });
}

export async function fetchTokens(params: {
  chains?: string;
  tags?: string;
  chainTypes?: string;
  minPriceUSD?: number;
} = {}): Promise<{ tokens: Record<string, LiFiToken[]> }> {
  return lifiFetch("/tokens", params);
}

export async function fetchTools(params: {
  chains?: string[];
} = {}): Promise<LiFiTools> {
  return lifiFetch("/tools", {
    chains: params.chains,
  });
}

export type FetchConnectionsParams = {
  fromChain: string | number;
  toChain: string | number;
  fromToken?: string;
  toToken?: string;
  chainTypes?: string;
  allowBridges?: string[];
  denyBridges?: string[];
  preferBridges?: string[];
  allowExchanges?: string[];
  denyExchanges?: string[];
  preferExchanges?: string[];
  allowSwitchChain?: boolean;
  allowDestinationCall?: boolean;
};

export async function fetchConnections(
  params: FetchConnectionsParams,
): Promise<{ connections: LiFiConnection[] }> {
  return lifiFetch("/connections", {
    fromChain: params.fromChain,
    toChain: params.toChain,
    fromToken: params.fromToken,
    toToken: params.toToken,
    chainTypes: params.chainTypes,
    allowBridges: params.allowBridges,
    denyBridges: params.denyBridges,
    preferBridges: params.preferBridges,
    allowExchanges: params.allowExchanges,
    denyExchanges: params.denyExchanges,
    preferExchanges: params.preferExchanges,
    allowSwitchChain: params.allowSwitchChain,
    allowDestinationCall: params.allowDestinationCall,
  });
}

export type FetchQuoteParams = {
  fromChain: string | number;
  toChain: string | number;
  fromToken: string;
  toToken: string;
  fromAmount: bigint | string;
  fromAddress: string;
  toAddress?: string;
  slippage?: number;
  order?: "FASTEST" | "CHEAPEST";
  allowBridges?: string[];
  denyBridges?: string[];
  preferBridges?: string[];
  allowExchanges?: string[];
  denyExchanges?: string[];
  preferExchanges?: string[];
  allowDestinationCall?: boolean;
  skipSimulation?: boolean;
  preset?: string;
};

export async function fetchQuote(params: FetchQuoteParams): Promise<LiFiQuoteResponse> {
  return lifiFetch("/quote", {
    fromChain: params.fromChain,
    toChain: params.toChain,
    fromToken: params.fromToken,
    toToken: params.toToken,
    fromAmount: String(params.fromAmount),
    fromAddress: params.fromAddress,
    toAddress: params.toAddress,
    slippage: params.slippage,
    order: params.order,
    allowBridges: params.allowBridges,
    denyBridges: params.denyBridges,
    preferBridges: params.preferBridges,
    allowExchanges: params.allowExchanges,
    denyExchanges: params.denyExchanges,
    preferExchanges: params.preferExchanges,
    allowDestinationCall: params.allowDestinationCall,
    skipSimulation: params.skipSimulation,
    preset: params.preset,
  });
}

export function extractTokensForChain(
  response: { tokens: Record<string, LiFiToken[]> },
  chainId: number,
): LiFiToken[] {
  return response.tokens[String(chainId)] ?? [];
}
