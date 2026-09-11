import { bech32, bech32m } from "bech32";
import { padHex, toHex, type Hex } from "viem";

const BITCOIN_BECH32_PREFIX = /^(bc1|tb1)/i;

/** Segwit bech32 / bech32m (bc1…, tb1…). Legacy base58 (1…, 3…) not supported yet. */
export function isBitcoinAddress(value: string): boolean {
  return BITCOIN_BECH32_PREFIX.test(value.trim());
}

function decodeBech32Address(address: string): { prefix: string; words: number[] } {
  const normalized = address.toLowerCase();
  try {
    return bech32.decode(normalized);
  } catch {
    return bech32m.decode(normalized);
  }
}

/**
 * LiFi bridge calldata stores the bech32 witness program as 5-bit words (one byte per word),
 * omitting the leading witness-version word. For P2WPKH (20-byte program) this is exactly 32 bytes.
 */
export function encodeLiFiBitcoinBytes32(address: string): Hex {
  const decoded = decodeBech32Address(address);
  const programWords = decoded.words.slice(1);
  if (programWords.length !== 32) {
    throw new Error(
      `Unsupported Bitcoin address program length for LiFi bytes32 encoding: ` +
        `${programWords.length} five-bit words (expected 32 for P2WPKH bc1q). ` +
        `Use LIFI_OUTPUT_RECIPIENT_BYTES32 override for P2WSH/P2TR.`,
    );
  }
  for (const word of programWords) {
    if (word < 0 || word > 31) {
      throw new Error(`Invalid bech32 word value: ${word}`);
    }
  }
  return padHex(toHex(Uint8Array.from(programWords)), { size: 32 });
}
