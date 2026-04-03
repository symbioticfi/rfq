import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const packageDir = resolve(currentDir, "..");
const targetPath = resolve(packageDir, "src", "generated", "deployment.ts");

function normalizeDeploymentEnv(value) {
  const normalized = (value ?? "").trim().toLowerCase();
  if (!normalized || normalized === "local" || normalized === "anvil") {
    return "local";
  }
  if (normalized === "hoodi" || normalized === "stage-hoodi") {
    return "hoodi";
  }
  if (normalized === "mainnet" || normalized === "prod" || normalized === "production") {
    return "mainnet";
  }

  throw new Error(`Unsupported deployment environment: ${value}`);
}

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

async function readEnvFile(filePath) {
  try {
    const contents = await readFile(filePath, "utf8");
    const values = {};

    for (const rawLine of contents.split(/\r?\n/u)) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) {
        continue;
      }

      const separatorIndex = line.indexOf("=");
      if (separatorIndex === -1) {
        continue;
      }

      const key = line.slice(0, separatorIndex).trim();
      const rawValue = line.slice(separatorIndex + 1).trim();
      const unquotedValue =
        (rawValue.startsWith(`"`) && rawValue.endsWith(`"`)) ||
        (rawValue.startsWith(`'`) && rawValue.endsWith(`'`))
          ? rawValue.slice(1, -1)
          : rawValue;

      values[key] = unquotedValue;
    }

    return values;
  } catch {
    return {};
  }
}

const fileEnv = {
  ...(await readEnvFile(resolve(packageDir, ".env"))),
  ...(await readEnvFile(resolve(packageDir, ".env.local"))),
};

const deploymentEnv = normalizeDeploymentEnv(process.env.RFQ_DEPLOYMENT_ENV || fileEnv.RFQ_DEPLOYMENT_ENV || "local");
const sourcePath = resolve(packageDir, "deployments", deploymentEnv, "addresses.json");

await access(sourcePath, constants.R_OK);

const normalizedManifest = normalizeDeploymentAddresses(JSON.parse(await readFile(sourcePath, "utf8")));
await mkdir(dirname(targetPath), { recursive: true });
await writeFile(targetPath, `export default ${JSON.stringify(normalizedManifest, null, 2)} as const;\n`);

// eslint-disable-next-line no-console
console.log(`Synced backend deployment ${deploymentEnv} -> rfq/backend/src/generated/deployment.ts`);
