import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { keccak256, stringToBytes } from "viem";

import { encodeLiFiBitcoinBytes32, isBitcoinAddress } from "./bitcoinEncoding.js";
import { extractNonEvmRecipientBytes32 } from "./calldataExtract.js";
import type { LiFiChain } from "./lifiApi.js";
import { resolveTermsEncodings } from "./lifi.js";
import { encodeLiFiNonEvmBytes32 } from "./terms.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(scriptDir, "..");

const BTC_RECIPIENT = "bc1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h";
const EXPECTED_BYTES32 =
  "0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f";

const bitcoinChain: LiFiChain = {
  key: "btc",
  name: "Bitcoin",
  coin: "BTC",
  id: 20000000000001,
  mainnet: true,
  chainType: "UTXO",
};

function loadFixture(name: string): { transactionRequest: { data: string } } {
  const raw = readFileSync(join(packageRoot, name), "utf8");
  return JSON.parse(raw) as { transactionRequest: { data: string } };
}

describe("encodeLiFiBitcoinBytes32", () => {
  it("encodes bc1q P2WPKH to LiFi calldata bytes32", () => {
    assert.equal(encodeLiFiBitcoinBytes32(BTC_RECIPIENT), EXPECTED_BYTES32);
  });

  it("isBitcoinAddress detects bc1/tb1 only", () => {
    assert.equal(isBitcoinAddress(BTC_RECIPIENT), true);
    assert.equal(isBitcoinAddress("tb1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h"), true);
    assert.equal(isBitcoinAddress("HoJQwEF9VZVQREpwACNjMiQEkvZDwWYPHGuAdAHkX6dw"), false);
  });
});

describe("encodeLiFiNonEvmBytes32", () => {
  it("uses Bitcoin encoder for bc1 addresses", () => {
    assert.equal(encodeLiFiNonEvmBytes32(BTC_RECIPIENT), EXPECTED_BYTES32);
  });

  it("still keccak-hashes long non-Bitcoin strings", () => {
    const long = "a".repeat(42);
    assert.equal(encodeLiFiNonEvmBytes32(long), keccak256(stringToBytes(long)));
  });
});

describe("resolveTermsEncodings BTC route", () => {
  it("uses LiFi binary bytes32 for cross-chain Bitcoin recipient", () => {
    const result = resolveTermsEncodings({
      toChain: bitcoinChain.id,
      sourceChain: 8453,
      toToken: "bitcoin",
      outputRecipient: BTC_RECIPIENT,
      outputChain: bitcoinChain,
    });
    assert.equal(result.outputRecipient, EXPECTED_BYTES32);
  });
});

describe("calldata round-trip", () => {
  it("matches encoder output in LAYERSWAP.JSON", () => {
    const fixture = loadFixture("LAYERSWAP.JSON");
    const extracted = extractNonEvmRecipientBytes32(
      fixture.transactionRequest.data as `0x${string}`,
      "layerswap",
    );
    assert.equal(extracted, EXPECTED_BYTES32);
    assert.equal(extracted, encodeLiFiBitcoinBytes32(BTC_RECIPIENT));
  });

  it("matches encoder output in NEAR.json", () => {
    const fixture = loadFixture("NEAR.json");
    const extracted = extractNonEvmRecipientBytes32(
      fixture.transactionRequest.data as `0x${string}`,
      "near",
    );
    assert.equal(extracted, EXPECTED_BYTES32);
    assert.equal(extracted, encodeLiFiBitcoinBytes32(BTC_RECIPIENT));
  });
});
