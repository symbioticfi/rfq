import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";

const integrationDir = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const explicitWorkspaceDir = process.env.RFQ_WORKSPACE_DIR?.trim();
const workspaceCandidates = [
  explicitWorkspaceDir ? resolve(explicitWorkspaceDir) : null,
  resolve(integrationDir, "submodules", "rfq"),
  resolve(integrationDir, ".."),
].filter((value) => value !== null);
const workspaceDir = workspaceCandidates.find((candidate) => existsSync(candidate));
if (!workspaceDir) {
  throw new Error(`Could not locate the RFQ workspace. Set RFQ_WORKSPACE_DIR explicitly for ${integrationDir}.`);
}
const scriptPath = resolve(workspaceDir, "scripts", "local", "stop.mjs");
const mode = process.argv[2] === "hoodi" ? "hoodi" : "local";

const result = spawnSync(process.execPath, [scriptPath, mode], {
  cwd: workspaceDir,
  stdio: "inherit",
  env: process.env,
});

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}
