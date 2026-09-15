import {
  decodeAbiParameters,
  decodeErrorResult,
  hexToString,
  sliceHex,
  type Hex,
} from "viem";

const delegationManagerErrors = [
  { type: "error", name: "CannotUseADisabledDelegation", inputs: [] },
  { type: "error", name: "InvalidAuthority", inputs: [] },
  { type: "error", name: "InvalidDelegate", inputs: [] },
  { type: "error", name: "InvalidDelegator", inputs: [] },
  { type: "error", name: "InvalidEOASignature", inputs: [] },
  { type: "error", name: "InvalidERC1271Signature", inputs: [] },
  { type: "error", name: "EmptySignature", inputs: [] },
  { type: "error", name: "AlreadyDisabled", inputs: [] },
  { type: "error", name: "AlreadyEnabled", inputs: [] },
  { type: "error", name: "BatchDataLengthMismatch", inputs: [] },
] as const;

const shimErrors = [
  { type: "error", name: "NotDelegationManager", inputs: [] },
  { type: "error", name: "ExecutionFailed", inputs: [] },
] as const;

const ERROR_STRING_SELECTOR = "0x08c379a0";
const PANIC_SELECTOR = "0x4e487b71";

export function extractRevertData(error: unknown): Hex | undefined {
  let current: unknown = error;
  for (let depth = 0; depth < 12 && current != null; depth++) {
    if (typeof current === "object") {
      const record = current as Record<string, unknown>;
      const data = record.data;
      if (typeof data === "string" && data.startsWith("0x") && data.length > 2) {
        return data as Hex;
      }
      if (record.cause !== undefined) {
        current = record.cause;
        continue;
      }
    }
    break;
  }
  return undefined;
}

function decodeRevertData(data: Hex): string | undefined {
  const selector = sliceHex(data, 0, 4).toLowerCase();

  if (selector === ERROR_STRING_SELECTOR) {
    try {
      const [reason] = decodeAbiParameters([{ type: "string" }], sliceHex(data, 4));
      return `Error("${reason}")`;
    } catch {
      // fall through
    }
  }

  if (selector === PANIC_SELECTOR) {
    try {
      const [code] = decodeAbiParameters([{ type: "uint256" }], sliceHex(data, 4));
      return `Panic(${code.toString()})`;
    } catch {
      // fall through
    }
  }

  for (const abi of [delegationManagerErrors, shimErrors]) {
    try {
      const decoded = decodeErrorResult({ abi, data });
      return decoded.args?.length
        ? `${decoded.errorName}(${decoded.args.join(", ")})`
        : decoded.errorName;
    } catch {
      // try next
    }
  }

  if (data.length > 10) {
    try {
      const raw = hexToString(sliceHex(data, 4), { size: 32 });
      const trimmed = raw.replace(/\0/g, "").trim();
      if (trimmed.length > 0 && /^[\x20-\x7e]+$/.test(trimmed)) {
        return `raw("${trimmed}") selector=${selector}`;
      }
    } catch {
      // ignore
    }
  }

  return undefined;
}

export function formatRevert(error: unknown): string {
  const data = extractRevertData(error);
  if (data) {
    const decoded = decodeRevertData(data);
    if (decoded) {
      return decoded;
    }
    if (error instanceof Error) {
      return `${error.message} revertData=${data}`;
    }
    return `revertData=${data}`;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
