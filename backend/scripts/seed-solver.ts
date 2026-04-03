import { getBackendEnv } from "../src/config/env";
import { createBackendDb } from "../src/db/client";
import { createBackendRepositories } from "../src/db/repositories";
import { newUuid } from "../src/utils/ids";

const env = getBackendEnv();
const endpointUrl = process.env.RFQ_SOLVER_ENDPOINT_URL;

if (!endpointUrl) {
  throw new Error("RFQ_SOLVER_ENDPOINT_URL is required");
}

const notifyUrl = process.env.RFQ_SOLVER_NOTIFY_URL || `${endpointUrl.replace(/\/$/, "")}/notify`;
const solverId = process.env.RFQ_SOLVER_ID || "00000000-0000-0000-0000-000000000001";
const solverName = process.env.RFQ_SOLVER_NAME || "Local filler";
const enabled = process.env.RFQ_SOLVER_ENABLED ? process.env.RFQ_SOLVER_ENABLED !== "false" : true;
const filler = process.env.RFQ_SOLVER_FILLER_ADDRESS;

if (!filler) {
  throw new Error("RFQ_SOLVER_FILLER_ADDRESS is required");
}

const { pool, db } = createBackendDb(env.databaseUrl);
const repositories = createBackendRepositories(db);
const now = new Date();

await repositories.solvers.upsert({
  id: solverId,
  chainId: env.chainId,
  name: solverName,
  endpointUrl,
  notifyUrl,
  filler: filler as `0x${string}`,
  enabled,
  cooldownUntil: null,
  metadata: { owner: "external" },
  createdAt: now,
  updatedAt: now,
});

await pool.end();

// eslint-disable-next-line no-console
console.log(`Seeded solver ${solverId} -> ${endpointUrl} (${newUuid()})`);
