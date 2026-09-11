import {
  encodeAbiParameters,
  encodePacked,
  getAddress,
  hexToBytes,
  type Address,
  type Hex,
} from "viem";
import { bytesToHex } from "viem/utils";

import {
  CHAINLINK_TERMS_LENGTH,
  RULE_KIND_ABSOLUTE_GTE,
  RULE_KIND_ABSOLUTE_LTE,
  RULE_KIND_DIP,
  RULE_KIND_RISE,
} from "./constants.js";
import type { ChainlinkRuleKind, ChainlinkTermsRecord } from "./types.js";

function readUint32BE(buf: Uint8Array, offset: number): number {
  return (
    (buf[offset]! << 24) |
    (buf[offset + 1]! << 16) |
    (buf[offset + 2]! << 8) |
    buf[offset + 3]!
  ) >>> 0;
}

function readUint16BE(buf: Uint8Array, offset: number): number {
  return (buf[offset]! << 8) | buf[offset + 1]!;
}

function bytesToSignedBigInt(bytes: Uint8Array): bigint {
  let value = 0n;
  for (const byte of bytes) {
    value = (value << 8n) | BigInt(byte);
  }
  const signBit = 1n << 255n;
  if (value >= signBit) {
    value -= 1n << 256n;
  }
  return value;
}

export function parseRuleKind(value: string): ChainlinkRuleKind {
  const normalized = value.toLowerCase().replace(/-/g, "_");
  switch (normalized) {
    case "dip":
    case "0":
      return "dip";
    case "rise":
    case "1":
      return "rise";
    case "absolute_gte":
    case "gte":
    case "2":
      return "absolute_gte";
    case "absolute_lte":
    case "lte":
    case "3":
      return "absolute_lte";
    default:
      throw new Error(
        `Invalid rule kind "${value}". Use dip, rise, absolute_gte, or absolute_lte.`,
      );
  }
}

export function ruleKindToUint8(kind: ChainlinkRuleKind): number {
  switch (kind) {
    case "dip":
      return RULE_KIND_DIP;
    case "rise":
      return RULE_KIND_RISE;
    case "absolute_gte":
      return RULE_KIND_ABSOLUTE_GTE;
    case "absolute_lte":
      return RULE_KIND_ABSOLUTE_LTE;
  }
}

export function isRelativeRuleKind(kind: ChainlinkRuleKind): boolean {
  return kind === "dip" || kind === "rise";
}

export function encodeChainlinkTerms(params: {
  priceFeed: Address;
  ruleKind: ChainlinkRuleKind;
  expectedDecimals: number;
  windowSeconds: number;
  thresholdBps: number;
  maxStaleSeconds: number;
  minGapSeconds: number;
  triggerPrice: bigint;
}): Hex {
  const encoded = encodePacked(
    [
      "address",
      "uint8",
      "uint8",
      "uint32",
      "uint16",
      "uint32",
      "uint32",
      "int256",
    ],
    [
      getAddress(params.priceFeed),
      ruleKindToUint8(params.ruleKind),
      params.expectedDecimals,
      params.windowSeconds,
      params.thresholdBps,
      params.maxStaleSeconds,
      params.minGapSeconds,
      params.triggerPrice,
    ],
  );

  if (hexToBytes(encoded).length !== CHAINLINK_TERMS_LENGTH) {
    throw new Error(
      `Chainlink terms encoding length mismatch: expected ${CHAINLINK_TERMS_LENGTH}`,
    );
  }

  return encoded;
}

export function decodeChainlinkTerms(terms: Hex): ChainlinkTermsRecord {
  const buf = hexToBytes(terms);
  if (buf.length !== CHAINLINK_TERMS_LENGTH) {
    throw new Error(
      `Invalid Chainlink terms length: expected ${CHAINLINK_TERMS_LENGTH}, got ${buf.length}`,
    );
  }

  const ruleKindNum = buf[20]!;
  let ruleKind: ChainlinkRuleKind;
  switch (ruleKindNum) {
    case RULE_KIND_DIP:
      ruleKind = "dip";
      break;
    case RULE_KIND_RISE:
      ruleKind = "rise";
      break;
    case RULE_KIND_ABSOLUTE_GTE:
      ruleKind = "absolute_gte";
      break;
    case RULE_KIND_ABSOLUTE_LTE:
      ruleKind = "absolute_lte";
      break;
    default:
      throw new Error(`Unknown Chainlink rule kind: ${ruleKindNum}`);
  }

  const priceFeed = getAddress(bytesToHex(buf.slice(0, 20)));

  return {
    priceFeed,
    ruleKind,
    expectedDecimals: buf[21]!,
    windowSeconds: String(readUint32BE(buf, 22)),
    thresholdBps: readUint16BE(buf, 26),
    maxStaleSeconds: String(readUint32BE(buf, 28)),
    minGapSeconds: String(readUint32BE(buf, 32)),
    triggerPrice: bytesToSignedBigInt(buf.slice(36, 68)).toString(),
  };
}

export function termsRecordToEncoded(record: ChainlinkTermsRecord): Hex {
  return encodeChainlinkTerms({
    priceFeed: record.priceFeed,
    ruleKind: record.ruleKind,
    expectedDecimals: record.expectedDecimals,
    windowSeconds: Number(record.windowSeconds),
    thresholdBps: record.thresholdBps,
    maxStaleSeconds: Number(record.maxStaleSeconds),
    minGapSeconds: Number(record.minGapSeconds),
    triggerPrice: BigInt(record.triggerPrice),
  });
}

export function encodeChainlinkArgs(referenceRoundId: bigint): Hex {
  return encodeAbiParameters([{ type: "uint80" }], [referenceRoundId]);
}
