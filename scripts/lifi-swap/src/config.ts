import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, isHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  BASE_CHAIN_ID,
  DEFAULT_CHAINLINK_PRICE_FEED,
  DEFAULT_RELAYER_URL,
} from "./constants.js";
import { isRelativeRuleKind, parseRuleKind } from "./chainlinkTerms.js";
import type { ChainlinkCreateParams, ChainlinkEnvConfig, CliConfig, SwapConfig } from "./types.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(scriptDir, "..");

function loadEnvFile(): void {
  const envPath = join(packageRoot, ".env");
  if (!existsSync(envPath)) return;

  const content = readFileSync(envPath, "utf8");
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

loadEnvFile();

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optionalEnv(name: string): string | undefined {
  return process.env[name];
}

function parseBigIntEnv(name: string, fallback?: bigint): bigint {
  const raw = optionalEnv(name);
  if (!raw) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return BigInt(raw);
}

function parsePrivateKey(): Hex {
  const raw = requireEnv("PRIVATE_KEY");
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(normalized)) {
    throw new Error("PRIVATE_KEY must be a hex string");
  }
  return normalized;
}

function parseOptionalHexEnv(name: string): Hex | undefined {
  const raw = optionalEnv(name);
  if (!raw) return undefined;
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(normalized)) {
    throw new Error(`${name} must be a hex string`);
  }
  return normalized;
}

function parseOptionalAddressEnv(name: string): Address | undefined {
  const raw = optionalEnv(name);
  if (!raw) return undefined;
  return getAddress(raw);
}

function resolveRpcUrl(override?: string): string {
  return (
    override ??
    optionalEnv("ARC_RPC_URL") ??
    optionalEnv("BASE_RPC_URL") ??
    (() => {
      throw new Error(
        "Missing RPC URL in scripts/lifi-swap/.env (set ARC_RPC_URL or BASE_RPC_URL)",
      );
    })()
  );
}

/** EOA for LiFi quote `fromAddress` / `toAddress` when flags are omitted. */
export function signerAddressFromEnv(): Address | undefined {
  const explicit =
    parseOptionalAddressEnv("LIFI_QUOTE_FROM_ADDRESS") ??
    parseOptionalAddressEnv("LIFI_QUOTE_INPUT_ADDRESS");
  if (explicit) return explicit;

  const raw = optionalEnv("PRIVATE_KEY");
  if (!raw) return undefined;
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(normalized)) return undefined;
  return getAddress(privateKeyToAccount(normalized).address);
}

export function loadCliConfig(overrides: Partial<CliConfig> = {}): CliConfig {
  return {
    privateKey: overrides.privateKey ?? parsePrivateKey(),
    rpcUrl: resolveRpcUrl(overrides.rpcUrl),
    fromAmount: overrides.fromAmount ?? parseBigIntEnv("LIFI_FROM_AMOUNT", 1_000_000n),
    slippage: overrides.slippage ?? Number(optionalEnv("LIFI_SLIPPAGE") ?? "0.005"),
    periodAmount:
      overrides.periodAmount ?? parseBigIntEnv("LIFI_PERIOD_AMOUNT", 10_000_000n),
    periodDuration:
      overrides.periodDuration ??
      Number(optionalEnv("LIFI_PERIOD_DURATION") ?? "86400"),
    slippageBps: overrides.slippageBps ?? Number(optionalEnv("LIFI_SLIPPAGE_BPS") ?? "50"),
    relayerUrl: overrides.relayerUrl ?? optionalEnv("RELAYER_URL") ?? DEFAULT_RELAYER_URL,
    outputRecipient: overrides.outputRecipient ?? optionalEnv("LIFI_OUTPUT_RECIPIENT"),
    outputAssetIdOverride:
      overrides.outputAssetIdOverride ?? parseOptionalHexEnv("LIFI_OUTPUT_ASSET_ID"),
    outputRecipientBytes32Override:
      overrides.outputRecipientBytes32Override ??
      parseOptionalHexEnv("LIFI_OUTPUT_RECIPIENT_BYTES32"),
    lifiDiamondOverride:
      overrides.lifiDiamondOverride ?? parseOptionalAddressEnv("LIFI_DIAMOND"),
  };
}

/** Legacy helper: full swap pair from env. Prefer resolveCreateRoute() + loadCliConfig() for create. */
export function loadSwapConfig(overrides: Partial<SwapConfig> = {}): SwapConfig {
  const cli = loadCliConfig(overrides);
  const fromTokenRaw = optionalEnv("LIFI_FROM_TOKEN");
  const toTokenRaw = optionalEnv("LIFI_TO_TOKEN");

  if (!overrides.fromToken && !fromTokenRaw) {
    throw new Error(
      "Missing LIFI_FROM_TOKEN — use route flags on create or set LIFI_FROM_TOKEN in .env",
    );
  }
  if (!overrides.toToken && !toTokenRaw) {
    throw new Error(
      "Missing LIFI_TO_TOKEN — use route flags on create or set LIFI_TO_TOKEN in .env",
    );
  }

  return {
    ...cli,
    fromToken:
      overrides.fromToken ??
      getAddress(fromTokenRaw!),
    toToken: overrides.toToken ?? toTokenRaw!,
    toChain: overrides.toChain ?? Number(optionalEnv("LIFI_TO_CHAIN") ?? BASE_CHAIN_ID),
  };
}

export function getDelegationsDir(): string {
  return join(scriptDir, "../delegations");
}

export function parseArgs(argv: string[]): {
  positional: string[];
  flags: Record<string, string | boolean>;
} {
  const positional: string[] = [];
  const flags: Record<string, string | boolean> = {};

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      positional.push(arg);
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      flags[key] = true;
    } else {
      flags[key] = next;
      i++;
    }
  }

  return { positional, flags };
}

export function flagBigInt(
  flags: Record<string, string | boolean>,
  key: string,
): bigint | undefined {
  const value = flags[key];
  if (typeof value !== "string") return undefined;
  return BigInt(value);
}

export function flagNumber(
  flags: Record<string, string | boolean>,
  key: string,
): number | undefined {
  const value = flags[key];
  if (typeof value !== "string") return undefined;
  return Number(value);
}

export function flagString(
  flags: Record<string, string | boolean>,
  key: string,
): string | undefined {
  const value = flags[key];
  return typeof value === "string" ? value : undefined;
}

export function flagBool(flags: Record<string, string | boolean>, key: string): boolean {
  return flags[key] === true;
}

export function parseCommaList(raw: string | undefined): string[] | undefined {
  if (!raw) return undefined;
  const items = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return items.length > 0 ? items : undefined;
}

export function loadChainlinkEnvConfig(): ChainlinkEnvConfig {
  const priceFeedRaw = optionalEnv("CHAINLINK_PRICE_FEED") ?? DEFAULT_CHAINLINK_PRICE_FEED;
  return {
    priceFeed: getAddress(priceFeedRaw),
    maxStaleSeconds: Number(optionalEnv("CHAINLINK_MAX_STALE_SECONDS") ?? "120"),
    minGapSeconds: Number(optionalEnv("CHAINLINK_MIN_GAP_SECONDS") ?? "300"),
  };
}

export function parseChainlinkCreateFlags(
  flags: Record<string, string | boolean>,
): ChainlinkCreateParams {
  const ruleKindRaw = flagString(flags, "rule-kind");
  if (!ruleKindRaw) {
    throw new Error("create-chainlink requires --rule-kind (dip|rise|absolute_gte|absolute_lte)");
  }

  const windowRaw = flagString(flags, "window-seconds");
  if (windowRaw === undefined) {
    throw new Error("create-chainlink requires --window-seconds");
  }

  const thresholdRaw = flagString(flags, "threshold-bps");
  if (thresholdRaw === undefined) {
    throw new Error("create-chainlink requires --threshold-bps");
  }

  const triggerRaw = flagString(flags, "trigger-price");
  if (triggerRaw === undefined) {
    throw new Error("create-chainlink requires --trigger-price");
  }

  const ruleKind = parseRuleKind(ruleKindRaw);
  const windowSeconds = Number(windowRaw);
  const thresholdBps = Number(thresholdRaw);
  const triggerPrice = BigInt(triggerRaw);

  if (isRelativeRuleKind(ruleKind)) {
    if (windowSeconds <= 0) {
      throw new Error(`${ruleKind} requires --window-seconds > 0`);
    }
    if (thresholdBps <= 0 || thresholdBps >= 10_000) {
      throw new Error(`${ruleKind} requires 0 < --threshold-bps < 10000`);
    }
    if (triggerPrice !== 0n) {
      throw new Error(`${ruleKind} requires --trigger-price 0`);
    }
  } else {
    if (triggerPrice <= 0n) {
      throw new Error(`${ruleKind} requires --trigger-price > 0`);
    }
    if (windowSeconds !== 0) {
      throw new Error(`${ruleKind} requires --window-seconds 0`);
    }
    if (thresholdBps !== 0) {
      throw new Error(`${ruleKind} requires --threshold-bps 0`);
    }
  }

  return { ruleKind, windowSeconds, thresholdBps, triggerPrice };
}
