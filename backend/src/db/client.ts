import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

import * as schema from "./schema";

/**
 * @dev Creates a node-postgres pool and Drizzle client for the backend schema.
 * @param connectionString Postgres connection string.
 * @returns The pool and typed Drizzle db handle.
 */
export function createBackendDb(connectionString: string) {
  const pool = new Pool({
    connectionString,
  });

  return {
    pool,
    db: drizzle(pool, { schema }),
  };
}
