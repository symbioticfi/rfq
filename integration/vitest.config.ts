import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";

const integrationDir = dirname(fileURLToPath(import.meta.url));
const explicitBackendDir = process.env.RFQ_BACKEND_DIR?.trim();
const explicitWorkspaceDir = process.env.RFQ_WORKSPACE_DIR?.trim();
const backendDirCandidates = [
  explicitBackendDir ? resolve(explicitBackendDir) : null,
  explicitWorkspaceDir ? resolve(explicitWorkspaceDir, "backend") : null,
  resolve(integrationDir, "submodules", "rfq-backend"),
  resolve(integrationDir, "submodules", "rfq", "backend"),
  resolve(integrationDir, "..", "backend"),
].filter((value) => value !== null);
const backendDir = backendDirCandidates.find((candidate) => existsSync(candidate));
if (!backendDir) {
  throw new Error(`Could not locate the RFQ backend. Set RFQ_BACKEND_DIR explicitly for ${integrationDir}.`);
}
const backendNodeModules = resolve(backendDir, "node_modules");

export default {
  test: {
    globals: true,
  },
  resolve: {
    alias: {
      viem: resolve(backendNodeModules, "viem"),
      "viem/accounts": resolve(backendNodeModules, "viem/accounts"),
    },
  },
};
