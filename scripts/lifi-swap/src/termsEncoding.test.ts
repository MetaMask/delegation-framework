import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { LiFiChain } from "./lifiApi.js";
import { encodeEvmTermsFields, resolveTermsEncodings } from "./lifi.js";

const RECIPIENT = "0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954";
const PADDED_RECIPIENT =
  "0x0000000000000000000000009fEad8B19C044C2f404dac38B925Ea16ADaa2954";
const NATIVE_TOKEN = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 =
  "0x0000000000000000000000000000000000000000000000000000000000000000";

const baseChain: LiFiChain = {
  key: "base",
  name: "Base",
  coin: "ETH",
  id: 8453,
  mainnet: true,
  chainType: "EVM",
};

const ethereumChain: LiFiChain = {
  key: "eth",
  name: "Ethereum",
  coin: "ETH",
  id: 1,
  mainnet: true,
  chainType: "EVM",
};

const bitcoinChain: LiFiChain = {
  key: "btc",
  name: "Bitcoin",
  coin: "BTC",
  id: 20000000000001,
  mainnet: true,
  chainType: "UTXO",
};

describe("resolveTermsEncodings", () => {
  it("same-chain EVM uses padded address encoding", () => {
    const result = resolveTermsEncodings({
      toChain: 8453,
      sourceChain: 8453,
      toToken: NATIVE_TOKEN,
      outputRecipient: RECIPIENT,
      outputChain: baseChain,
    });
    assert.equal(result.outputRecipient, PADDED_RECIPIENT);
    assert.equal(result.outputAssetId, ZERO_BYTES32);
  });

  it("cross-chain EVM uses padded address encoding", () => {
    const result = resolveTermsEncodings({
      toChain: 1,
      sourceChain: 8453,
      toToken: NATIVE_TOKEN,
      outputRecipient: RECIPIENT,
      outputChain: ethereumChain,
    });
    assert.equal(result.outputRecipient, PADDED_RECIPIENT);
    assert.equal(result.outputAssetId, ZERO_BYTES32);
  });

  it("cross-chain non-EVM Bitcoin uses LiFi binary bytes32", () => {
    const btcRecipient = "bc1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h";
    const result = resolveTermsEncodings({
      toChain: bitcoinChain.id,
      sourceChain: 8453,
      toToken: "bitcoin",
      outputRecipient: btcRecipient,
      outputChain: bitcoinChain,
    });
    assert.equal(
      result.outputRecipient,
      "0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f",
    );
  });
});

describe("encodeEvmTermsFields", () => {
  it("matches resolveTermsEncodings for EVM routes", () => {
    const direct = encodeEvmTermsFields(NATIVE_TOKEN, RECIPIENT);
    assert.equal(direct.outputRecipient, PADDED_RECIPIENT);
    assert.equal(direct.outputAssetId, ZERO_BYTES32);
  });
});
