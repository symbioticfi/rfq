import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import { client, graphql } from "ponder";
import { db } from "ponder:api";
import schema from "ponder:schema";

import { createIndexerRequestLogger, indexerLogger, type IndexerAppVariables } from "../lib/logger";

const app = new Hono<{ Variables: IndexerAppVariables }>();

app.use("*", createIndexerRequestLogger(indexerLogger.child({ component: "api" })));

app.onError((error, context) => {
  const httpError = error instanceof HTTPException ? error : new HTTPException(500, { message: "Internal error" });
  context.get("logger").error({ err: error, status: httpError.status }, "request failed");
  return context.json({ error: httpError.message }, httpError.status);
});

app.use("/sql/*", client({ db, schema }));
app.use("/graphql", graphql({ db, schema }));

export default app;
