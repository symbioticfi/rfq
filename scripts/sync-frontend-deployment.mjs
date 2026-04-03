import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const scriptPath = resolve(currentDir, "sync-service-deployment.mjs");
const result = spawnSync(process.execPath, [scriptPath, "frontend"], {
  cwd: resolve(currentDir, ".."),
  stdio: "inherit",
  env: process.env,
});

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}
