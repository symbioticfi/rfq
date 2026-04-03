import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const workspaceDir = resolve(currentDir, "..");

function normalizeDeploymentAddresses(value) {
  if (Array.isArray(value)) {
    return value.map(normalizeDeploymentAddresses);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, nested]) => [key, normalizeDeploymentAddresses(nested)]));
  }

  if (typeof value === "string" && /^0x[a-fA-F0-9]{40}$/u.test(value)) {
    return value.toLowerCase();
  }

  return value;
}

const sourcePath = resolve(workspaceDir, "deployments", "local", "addresses.json");
const normalizedContents = JSON.stringify(normalizeDeploymentAddresses(JSON.parse(await readFile(sourcePath, "utf8"))));

for (const service of ["backend", "filler", "indexer", "frontend"]) {
  const targetPath = resolve(workspaceDir, service, "deployments", "local", "addresses.json");
  await mkdir(dirname(targetPath), { recursive: true });
  await writeFile(targetPath, `${normalizedContents}\n`);
  // eslint-disable-next-line no-console
  console.log(`Synced local deployment -> rfq/${service}/deployments/local/addresses.json`);
}
