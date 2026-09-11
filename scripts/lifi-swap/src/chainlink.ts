import { type Address, type Hex, type PublicClient } from "viem";

import {
  encodeChainlinkArgs,
  isRelativeRuleKind,
  termsRecordToEncoded,
} from "./chainlinkTerms.js";
import type { ChainlinkTermsRecord } from "./types.js";

const AGGREGATOR_V3_ABI = [
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  {
    type: "function",
    name: "getRoundData",
    stateMutability: "view",
    inputs: [{ name: "_roundId", type: "uint80" }],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

const MAX_ROUND_ITERATIONS = 500;
const BPS_DENOMINATOR = 10_000n;

export type RoundData = {
  roundId: bigint;
  price: bigint;
  updatedAt: bigint;
  answeredInRound: bigint;
};

export type WindowScanResult = {
  referenceRoundId?: bigint;
  priceRef?: bigint;
  windowNewestRoundId?: bigint;
  windowOldestRoundId?: bigint;
};

export type ChainlinkResolveResult = {
  args: Hex;
  currentRoundId?: bigint;
  windowNewestRoundId?: bigint;
  windowOldestRoundId?: bigint;
  referenceRoundId?: bigint;
  priceNow: bigint;
  priceRef?: bigint;
  passed: boolean;
  reason?: string;
};

export async function readFeedDecimals(
  client: PublicClient,
  feed: Address,
): Promise<number> {
  return client.readContract({
    address: feed,
    abi: AGGREGATOR_V3_ABI,
    functionName: "decimals",
  });
}

export async function readLatestRound(
  client: PublicClient,
  feed: Address,
): Promise<RoundData> {
  const result = await client.readContract({
    address: feed,
    abi: AGGREGATOR_V3_ABI,
    functionName: "latestRoundData",
  });

  return {
    roundId: result[0],
    price: result[1],
    updatedAt: result[3],
    answeredInRound: result[4],
  };
}

export async function readRound(
  client: PublicClient,
  feed: Address,
  roundId: bigint,
): Promise<RoundData> {
  const result = await client.readContract({
    address: feed,
    abi: AGGREGATOR_V3_ABI,
    functionName: "getRoundData",
    args: [roundId],
  });

  return {
    roundId: result[0],
    price: result[1],
    updatedAt: result[3],
    answeredInRound: result[4],
  };
}

function validateReferenceRound(
  terms: ChainlinkTermsRecord,
  roundIdNow: bigint,
  referenceRoundId: bigint,
  priceRef: bigint,
  updatedAtRef: bigint,
  answeredInRoundRef: bigint,
  now: bigint,
): string | undefined {
  if (referenceRoundId === 0n) {
    return "referenceRoundId must be non-zero";
  }
  if (referenceRoundId >= roundIdNow) {
    return "referenceRoundId must be less than latest roundId";
  }
  if (answeredInRoundRef < referenceRoundId) {
    return "answeredInRoundRef < referenceRoundId (stale reference round)";
  }
  if (priceRef <= 0n) {
    return "reference price must be positive";
  }

  const windowSeconds = BigInt(terms.windowSeconds);
  const minGapSeconds = BigInt(terms.minGapSeconds);
  const windowStart = now - windowSeconds;
  const windowEnd = now - minGapSeconds;

  if (updatedAtRef < windowStart) {
    return "reference round updatedAt is before window start";
  }
  if (updatedAtRef > windowEnd) {
    return "reference round updatedAt is too recent (within minGapSeconds)";
  }

  return undefined;
}

function checkRelativeThreshold(
  terms: ChainlinkTermsRecord,
  priceNow: bigint,
  priceRef: bigint,
): boolean {
  const thresholdBps = BigInt(terms.thresholdBps);
  if (terms.ruleKind === "dip") {
    const dropBps = ((priceRef - priceNow) * BPS_DENOMINATOR) / priceRef;
    return dropBps >= thresholdBps;
  }
  const riseBps = ((priceNow - priceRef) * BPS_DENOMINATOR) / priceRef;
  return riseBps >= thresholdBps;
}

function attachWindowRoundIds(
  result: ChainlinkResolveResult,
  latest: RoundData,
  scan?: WindowScanResult,
): ChainlinkResolveResult {
  return {
    ...result,
    currentRoundId: latest.roundId,
    windowNewestRoundId: scan?.windowNewestRoundId,
    windowOldestRoundId: scan?.windowOldestRoundId,
  };
}

async function scanReferenceWindow(
  client: PublicClient,
  terms: ChainlinkTermsRecord,
  latest: RoundData,
  now: bigint,
): Promise<WindowScanResult> {
  const feed = terms.priceFeed;
  const windowStart = now - BigInt(terms.windowSeconds);
  const windowEnd = now - BigInt(terms.minGapSeconds);

  let best: { roundId: bigint; price: bigint } | undefined;
  let windowNewestRoundId: bigint | undefined;
  let windowOldestRoundId: bigint | undefined;

  for (
    let i = 0n, roundId = latest.roundId - 1n;
    roundId > 0n && i < BigInt(MAX_ROUND_ITERATIONS);
    roundId--, i++
  ) {
    const round = await readRound(client, feed, roundId);
    if (round.updatedAt < windowStart) break;
    if (round.updatedAt > windowEnd) continue;
    if (round.price <= 0n) continue;
    if (round.answeredInRound < roundId) continue;

    if (windowNewestRoundId === undefined || roundId > windowNewestRoundId) {
      windowNewestRoundId = roundId;
    }
    if (windowOldestRoundId === undefined || roundId < windowOldestRoundId) {
      windowOldestRoundId = roundId;
    }

    if (terms.ruleKind === "dip") {
      if (!best || round.price > best.price) {
        best = { roundId, price: round.price };
      }
    } else {
      if (!best || round.price < best.price) {
        best = { roundId, price: round.price };
      }
    }
  }

  return {
    referenceRoundId: best?.roundId,
    priceRef: best?.price,
    windowNewestRoundId,
    windowOldestRoundId,
  };
}

async function resolveRelativeRule(
  client: PublicClient,
  terms: ChainlinkTermsRecord,
  overrideRoundId?: bigint,
): Promise<ChainlinkResolveResult> {
  const feed = terms.priceFeed;
  const latest = await readLatestRound(client, feed);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const maxStale = BigInt(terms.maxStaleSeconds);
  const scan = await scanReferenceWindow(client, terms, latest, now);

  if (now - latest.updatedAt > maxStale) {
    return attachWindowRoundIds(
      {
        args: encodeChainlinkArgs(0n),
        priceNow: latest.price,
        passed: false,
        reason: `latest round stale (${now - latest.updatedAt}s > maxStaleSeconds ${maxStale})`,
      },
      latest,
      scan,
    );
  }

  if (latest.price <= 0n) {
    return attachWindowRoundIds(
      {
        args: encodeChainlinkArgs(0n),
        priceNow: latest.price,
        passed: false,
        reason: "latest price must be positive",
      },
      latest,
      scan,
    );
  }

  if (overrideRoundId !== undefined) {
    const ref = await readRound(client, feed, overrideRoundId);
    const validationError = validateReferenceRound(
      terms,
      latest.roundId,
      overrideRoundId,
      ref.price,
      ref.updatedAt,
      ref.answeredInRound,
      now,
    );
    if (validationError) {
      return attachWindowRoundIds(
        {
          args: encodeChainlinkArgs(overrideRoundId),
          referenceRoundId: overrideRoundId,
          priceNow: latest.price,
          priceRef: ref.price,
          passed: false,
          reason: validationError,
        },
        latest,
        scan,
      );
    }

    const thresholdMet = checkRelativeThreshold(terms, latest.price, ref.price);
    return attachWindowRoundIds(
      {
        args: encodeChainlinkArgs(overrideRoundId),
        referenceRoundId: overrideRoundId,
        priceNow: latest.price,
        priceRef: ref.price,
        passed: thresholdMet,
        reason: thresholdMet
          ? undefined
          : `threshold not met (${terms.ruleKind}, need ${terms.thresholdBps} bps)`,
      },
      latest,
      scan,
    );
  }

  if (scan.referenceRoundId === undefined || scan.priceRef === undefined) {
    return attachWindowRoundIds(
      {
        args: encodeChainlinkArgs(0n),
        priceNow: latest.price,
        passed: false,
        reason: "no valid reference round found in window",
      },
      latest,
      scan,
    );
  }

  const refRound = await readRound(client, feed, scan.referenceRoundId);
  const validationError = validateReferenceRound(
    terms,
    latest.roundId,
    scan.referenceRoundId,
    scan.priceRef,
    refRound.updatedAt,
    refRound.answeredInRound,
    now,
  );

  if (validationError) {
    return attachWindowRoundIds(
      {
        args: encodeChainlinkArgs(scan.referenceRoundId),
        referenceRoundId: scan.referenceRoundId,
        priceNow: latest.price,
        priceRef: scan.priceRef,
        passed: false,
        reason: validationError,
      },
      latest,
      scan,
    );
  }

  const thresholdMet = checkRelativeThreshold(
    terms,
    latest.price,
    scan.priceRef,
  );

  return attachWindowRoundIds(
    {
      args: encodeChainlinkArgs(scan.referenceRoundId),
      referenceRoundId: scan.referenceRoundId,
      priceNow: latest.price,
      priceRef: scan.priceRef,
      passed: thresholdMet,
      reason: thresholdMet
        ? undefined
        : `threshold not met (${terms.ruleKind}, need ${terms.thresholdBps} bps)`,
    },
    latest,
    scan,
  );
}

async function resolveAbsoluteRule(
  client: PublicClient,
  terms: ChainlinkTermsRecord,
): Promise<ChainlinkResolveResult> {
  const feed = terms.priceFeed;
  const latest = await readLatestRound(client, feed);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const maxStale = BigInt(terms.maxStaleSeconds);
  const triggerPrice = BigInt(terms.triggerPrice);

  if (now - latest.updatedAt > maxStale) {
    return {
      args: encodeChainlinkArgs(0n),
      currentRoundId: latest.roundId,
      priceNow: latest.price,
      passed: false,
      reason: `latest round stale (${now - latest.updatedAt}s > maxStaleSeconds ${maxStale})`,
    };
  }

  if (latest.price <= 0n) {
    return {
      args: encodeChainlinkArgs(0n),
      currentRoundId: latest.roundId,
      priceNow: latest.price,
      passed: false,
      reason: "latest price must be positive",
    };
  }

  let passed: boolean;
  if (terms.ruleKind === "absolute_gte") {
    passed = latest.price >= triggerPrice;
  } else {
    passed = latest.price <= triggerPrice;
  }

  return {
    args: encodeChainlinkArgs(0n),
    currentRoundId: latest.roundId,
    priceNow: latest.price,
    passed,
    reason: passed
      ? undefined
      : `absolute rule not met (${terms.ruleKind}, trigger=${triggerPrice}, now=${latest.price})`,
  };
}

export async function resolveChainlinkArgs(
  client: PublicClient,
  terms: ChainlinkTermsRecord,
  overrideRoundId?: bigint,
): Promise<ChainlinkResolveResult> {
  if (isRelativeRuleKind(terms.ruleKind)) {
    return resolveRelativeRule(client, terms, overrideRoundId);
  }
  if (overrideRoundId !== undefined && overrideRoundId !== 0n) {
    const latest = await readLatestRound(client, terms.priceFeed);
    return {
      args: encodeChainlinkArgs(0n),
      currentRoundId: latest.roundId,
      priceNow: latest.price,
      passed: false,
      reason: "referenceRoundId override ignored for absolute rules",
    };
  }
  return resolveAbsoluteRule(client, terms);
}

export function formatChainlinkReport(
  terms: ChainlinkTermsRecord,
  result: ChainlinkResolveResult,
): string {
  const lines = [
    `Rule kind:         ${terms.ruleKind}`,
    `Price feed:        ${terms.priceFeed}`,
    `Current price:     ${result.priceNow.toString()}`,
  ];

  if (result.currentRoundId !== undefined) {
    lines.push(`Current roundId:   ${result.currentRoundId.toString()}`);
  }

  if (isRelativeRuleKind(terms.ruleKind)) {
    lines.push(
      `Window newest roundId: ${result.windowNewestRoundId?.toString() ?? "n/a"}`,
    );
    lines.push(
      `Window oldest roundId: ${result.windowOldestRoundId?.toString() ?? "n/a"}`,
    );
  }

  if (result.priceRef !== undefined) {
    lines.push(`Reference price:   ${result.priceRef.toString()}`);
  }
  if (result.referenceRoundId !== undefined) {
    lines.push(`Reference roundId: ${result.referenceRoundId.toString()}`);
  }

  lines.push(`Passed:            ${result.passed ? "yes" : "no"}`);
  if (result.reason) {
    lines.push(`Reason:            ${result.reason}`);
  }

  lines.push(`Args:              ${result.args}`);
  lines.push(`Terms bytes:       ${termsRecordToEncoded(terms)}`);

  return lines.join("\n");
}
