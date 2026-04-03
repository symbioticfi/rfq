import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const workspaceDir = resolve(currentDir, "..");

const serviceName = process.argv[2];

const services = {
  backend: {
    packageDir: resolve(workspaceDir, "backend"),
    envVars: ["RFQ_DEPLOYMENT_ENV"],
    targetPath: resolve(workspaceDir, "backend", "src", "generated", "deployment.ts"),
    targetFormat: "ts",
  },
  filler: {
    packageDir: resolve(workspaceDir, "filler"),
    envVars: ["RFQ_FILLER_DEPLOYMENT_ENV"],
    targetPath: resolve(workspaceDir, "filler", "src", "generated", "deployment.ts"),
    targetFormat: "ts",
  },
  indexer: {
    packageDir: resolve(workspaceDir, "indexer"),
    envVars: ["RFQ_DEPLOYMENT_ENV"],
    targetPath: resolve(workspaceDir, "indexer", "src", "generated", "deployment.ts"),
    targetFormat: "ts",
  },
  frontend: {
    packageDir: resolve(workspaceDir, "frontend"),
    envVars: ["VITE_DEPLOYMENT_ENV", "RFQ_DEPLOYMENT_ENV"],
    targetPath: resolve(workspaceDir, "frontend", "src", "generated", "deployment.json"),
    targetFormat: "json",
  },
};

if (!serviceName || !(serviceName in services)) {
  throw new Error(`Usage: node ./scripts/sync-service-deployment.mjs <${Object.keys(services).join("|")}>`);
}

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

async function loadSourceManifest(config) {
  const fileEnv = {
    ...(await readEnvFile(resolve(config.packageDir, ".env"))),
    ...(await readEnvFile(resolve(config.packageDir, ".env.local"))),
  };

  const deploymentEnv = normalizeDeploymentEnv(
    config.envVars.map((name) => process.env[name] || fileEnv[name]).find(Boolean) || "local",
  );
  const sourcePath = resolve(config.packageDir, "deployments", deploymentEnv, "addresses.json");

  await access(sourcePath, constants.R_OK);

  const normalizedManifest = normalizeDeploymentAddresses(JSON.parse(await readFile(sourcePath, "utf8")));
  return {
    deploymentEnv,
    normalizedManifest,
  };
}

function serializeDeployment(config, manifest) {
  if (config.targetFormat === "json") {
    return `${JSON.stringify(manifest)}\n`;
  }

  return `export default ${JSON.stringify(manifest, null, 2)} as const;\n`;
}

const config = services[serviceName];
const { deploymentEnv, normalizedManifest } = await loadSourceManifest(config);
await mkdir(dirname(config.targetPath), { recursive: true });
await writeFile(config.targetPath, serializeDeployment(config, normalizedManifest));

// eslint-disable-next-line no-console
console.log(
  `Synced ${serviceName} deployment ${deploymentEnv} -> ${config.targetPath.replace(`${workspaceDir}/`, "rfq/")}`,
);
