import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const integrationDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const explicitBackendDir = process.env.RFQ_BACKEND_DIR?.trim();
const explicitWorkspaceDir = process.env.RFQ_WORKSPACE_DIR?.trim();
const backendCandidates = [
  explicitBackendDir ? resolve(explicitBackendDir) : null,
  explicitWorkspaceDir ? resolve(explicitWorkspaceDir, "backend") : null,
  resolve(integrationDir, "submodules", "rfq-backend"),
  resolve(integrationDir, "submodules", "rfq", "backend"),
  resolve(integrationDir, "..", "backend"),
].filter((value) => value !== null);
const backendDir = backendCandidates.find((candidate) => existsSync(candidate));

if (!backendDir) {
  throw new Error(`Could not locate the RFQ backend. Set RFQ_BACKEND_DIR explicitly for ${integrationDir}.`);
}

const result = spawnSync(
  "pnpm",
  ["exec", "vitest", "run", "--root", integrationDir, "--config", resolve(integrationDir, "vitest.config.ts")],
  {
    cwd: backendDir,
    stdio: "inherit",
    env: process.env,
  },
);

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}
