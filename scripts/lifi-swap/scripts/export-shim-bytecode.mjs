#!/usr/bin/env node
/**
 * Regenerate delegatorEstimateShimBytecode.ts after editing src/poc/DelegatorEstimateShim.sol.
 * Run from repo root: node scripts/lifi-swap/scripts/export-shim-bytecode.mjs
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const artifactPath = path.join(
  repoRoot,
  "out/DelegatorEstimateShim.sol/DelegatorEstimateShim.json",
);
const outPath = path.join(
  __dirname,
  "../src/poc/delegatorEstimateShimBytecode.ts",
);

const DELEGATION_MANAGER = "db9B1e94B5b69Df7e401DDbedE43491141047dB3".toLowerCase();

function patchDelegationManagerImmutable(deployedObject, immRefs) {
  let hex = deployedObject.startsWith("0x") ? deployedObject.slice(2) : deployedObject;
  const addr = DELEGATION_MANAGER.padStart(40, "0");
  let patched = 0;

  for (const refs of Object.values(immRefs ?? {})) {
    for (const { start, length } of refs) {
      if (length !== 32) {
        throw new Error(`Unexpected immutable length ${length} at byte ${start}`);
      }
      const addrCharStart = (start + 12) * 2;
      hex = hex.slice(0, addrCharStart) + addr + hex.slice(addrCharStart + 40);
      patched += 1;
    }
  }

  if (patched === 0) {
    throw new Error("deployedBytecode.immutableReferences missing; cannot patch shim");
  }

  return `0x${hex}`;
}

const json = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
const patched = patchDelegationManagerImmutable(
  json.deployedBytecode.object,
  json.deployedBytecode.immutableReferences,
);

fs.writeFileSync(
  outPath,
  `import type { Hex } from "viem";

/** Runtime bytecode for DelegatorEstimateShim(DELEGATION_MANAGER). PoC only. */
export const DELEGATOR_ESTIMATE_SHIM_CODE: Hex = "${patched}" as const;
`,
);

console.log(`Wrote ${outPath} (${patched.length} hex chars)`);
