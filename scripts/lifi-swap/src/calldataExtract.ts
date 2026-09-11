import { type Hex } from "viem";

export type NonEvmBridgeKind = "near" | "layerswap";

const NON_EVM_FIELD_OFFSET: Record<NonEvmBridgeKind, number> = {
  near: 0x00,
  layerswap: 0x60,
};

function readWord(data: Uint8Array, offset: number): Hex {
  if (data.length < 32 || offset > data.length - 32) {
    throw new Error("calldata too short for nonEVMRecipient read");
  }
  const slice = data.slice(offset, offset + 32);
  return `0x${Buffer.from(slice).toString("hex")}` as Hex;
}

function bridgeDataBody(data: Uint8Array): number {
  const bdOff = Number(readBigEndianWord(data, 0x04));
  return 0x04 + bdOff;
}

function readBigEndianWord(data: Uint8Array, offset: number): bigint {
  if (data.length < offset + 32) {
    throw new Error("calldata too short");
  }
  let value = 0n;
  for (let i = 0; i < 32; i++) {
    value = (value << 8n) | BigInt(data[offset + i]!);
  }
  return value;
}

function bridgeSpecificStructBody(data: Uint8Array): number {
  const bd = bridgeDataBody(data);
  const hasSourceSwaps = readBigEndianWord(data, bd + 0x100) !== 0n;
  const headSlotAbs = hasSourceSwaps ? 0x44 : 0x24;
  const structOff = Number(readBigEndianWord(data, headSlotAbs));
  return 0x04 + structOff;
}

/** Extract nonEVMReceiver bytes32 from LiFi swap+bridge calldata (Near or LayerSwap BTC). */
export function extractNonEvmRecipientBytes32(
  calldata: Hex,
  routeKind: NonEvmBridgeKind,
): Hex {
  const hex = calldata.startsWith("0x") ? calldata.slice(2) : calldata;
  const data = Uint8Array.from(Buffer.from(hex, "hex"));
  if (data.length < 4) {
    throw new Error("calldata too short");
  }
  const structBody = bridgeSpecificStructBody(data);
  return readWord(data, structBody + NON_EVM_FIELD_OFFSET[routeKind]);
}
