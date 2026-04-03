import { defineConfig } from "drizzle-kit";

const connectionString = process.env.RFQ_DATABASE_URL || process.env.DATABASE_URL;

if (!connectionString) {
  throw new Error("RFQ_DATABASE_URL or DATABASE_URL is required");
}

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dbCredentials: {
    url: connectionString,
  },
});
