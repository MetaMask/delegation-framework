import {
  existsSync,
  mkdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import { getDelegationsDir } from "./config.js";
import type { Manifest, ManifestEntry, SavedDelegation } from "./types.js";

function manifestPath(): string {
  return join(getDelegationsDir(), "manifest.json");
}

function delegationPath(id: string): string {
  return join(getDelegationsDir(), `${id}.json`);
}

function ensureStoreDir(): void {
  const dir = getDelegationsDir();
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

function readManifest(): Manifest {
  ensureStoreDir();
  const path = manifestPath();
  if (!existsSync(path)) {
    return { delegations: [] };
  }
  return JSON.parse(readFileSync(path, "utf8")) as Manifest;
}

function writeManifest(manifest: Manifest): void {
  ensureStoreDir();
  writeFileSync(manifestPath(), `${JSON.stringify(manifest, null, 2)}\n`);
}

export function listDelegations(): ManifestEntry[] {
  return readManifest().delegations;
}

export function loadDelegation(id: string): SavedDelegation {
  const path = delegationPath(id);
  if (!existsSync(path)) {
    throw new Error(`Delegation not found: ${id}`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as SavedDelegation;
}

export function saveDelegation(
  saved: SavedDelegation,
  options: { force?: boolean } = {},
): string {
  ensureStoreDir();
  const path = delegationPath(saved.id);
  if (existsSync(path) && !options.force) {
    throw new Error(
      `Delegation id "${saved.id}" already exists. Use --force to overwrite.`,
    );
  }

  writeFileSync(path, `${JSON.stringify(saved, null, 2)}\n`);

  const manifest = readManifest();
  const entry: ManifestEntry = {
    id: saved.id,
    name: saved.name,
    createdAt: saved.createdAt,
    delegationHash: saved.delegationHash,
    periodAmount: saved.terms.periodAmount,
    periodDuration: saved.terms.periodDuration,
    chainlinkRuleKind: saved.chainlinkTerms?.ruleKind,
    delegationType: saved.delegationType,
  };

  const index = manifest.delegations.findIndex((d) => d.id === saved.id);
  if (index >= 0) {
    manifest.delegations[index] = entry;
  } else {
    manifest.delegations.push(entry);
  }

  manifest.delegations.sort((a, b) => a.id.localeCompare(b.id));
  writeManifest(manifest);
  return path;
}

export function delegationExists(id: string): boolean {
  return existsSync(delegationPath(id));
}

export function deleteDelegation(id: string): void {
  const path = delegationPath(id);
  if (!existsSync(path)) {
    throw new Error(`Delegation not found: ${id}`);
  }
  unlinkSync(path);

  const manifest = readManifest();
  manifest.delegations = manifest.delegations.filter((d) => d.id !== id);
  writeManifest(manifest);
}

export function deleteAllDelegations(): number {
  const manifest = readManifest();
  let removed = 0;
  for (const entry of manifest.delegations) {
    const path = delegationPath(entry.id);
    if (existsSync(path)) {
      unlinkSync(path);
      removed++;
    }
  }
  writeManifest({ delegations: [] });
  return removed;
}
