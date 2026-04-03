import {
  bigint,
  boolean,
  index,
  integer,
  jsonb,
  pgEnum,
  pgSchema,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid,
  varchar,
} from "drizzle-orm/pg-core";

export const rfqBackend = pgSchema("rfq_backend");
export const rfqIndexer = pgSchema("rfq_indexer");

export const quotePhaseEnum = pgEnum("rfq_quote_phase", ["preview", "executable"]);
export const solverQuoteStatusEnum = pgEnum("rfq_solver_quote_status", [
  "quoted",
  "no_quote",
  "timeout",
  "error",
  "cooldown",
]);
export const orderPublicStatusEnum = pgEnum("rfq_order_public_status", [
  "open",
  "expired",
  "error",
  "cancelled",
  "filled",
  "unverified",
  "insufficient-funds",
]);
export const orderInternalStatusEnum = pgEnum("rfq_order_internal_status", [
  "hard_auction",
  "winner_selected",
  "tx_submitted",
  "filled",
  "expired",
  "failed",
]);

export const solversTable = rfqBackend.table(
  "solvers",
  {
    id: uuid("id").primaryKey(),
    chainId: integer("chain_id").notNull(),
    name: text("name").notNull(),
    endpointUrl: text("endpoint_url").notNull(),
    notifyUrl: text("notify_url"),
    filler: varchar("filler", { length: 42 }).notNull(),
    enabled: boolean("enabled").notNull().default(true),
    cooldownUntil: timestamp("cooldown_until", { withTimezone: true }),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default({}),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  },
  (table) => ({
    chainIdx: index("rfq_solvers_chain_idx").on(table.chainId),
  }),
);

export const quoteRequestsTable = rfqBackend.table(
  "quote_requests",
  {
    id: uuid("id").primaryKey(),
    requestId: uuid("request_id").notNull().unique(),
    quoteId: uuid("quote_id").notNull().unique(),
    phase: quotePhaseEnum("phase").notNull(),
    requestPayload: jsonb("request_payload").$type<Record<string, unknown>>().notNull(),
    permitData: jsonb("permit_data").$type<Record<string, unknown>>().notNull(),
    outputs: jsonb("outputs").$type<readonly Record<string, unknown>[]>().notNull(),
    bestAmountOut: text("best_amount_out"),
    bestFiller: varchar("best_filler", { length: 42 }),
    selectedSolverId: uuid("selected_solver_id"),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  },
  (table) => ({
    expiresIdx: index("rfq_quote_requests_expires_idx").on(table.expiresAt),
  }),
);

export const solverQuotesTable = rfqBackend.table(
  "solver_quotes",
  {
    id: uuid("id").primaryKey(),
    quoteRequestId: uuid("quote_request_id").notNull(),
    solverId: uuid("solver_id").notNull(),
    phase: quotePhaseEnum("phase").notNull(),
    status: solverQuoteStatusEnum("status").notNull(),
    latencyMs: integer("latency_ms").notNull(),
    amountOut: text("amount_out"),
    filler: varchar("filler", { length: 42 }),
    responsePayload: jsonb("response_payload").$type<Record<string, unknown>>(),
    errorMessage: text("error_message"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  },
  (table) => ({
    quoteIdx: index("rfq_solver_quotes_quote_idx").on(table.quoteRequestId),
    solverIdx: index("rfq_solver_quotes_solver_idx").on(table.solverId),
  }),
);

export const discountsTable = rfqBackend.table(
  "discounts",
  {
    discountId: varchar("discount_id", { length: 66 }).primaryKey(),
    chainId: integer("chain_id").notNull(),
    vault: varchar("vault", { length: 42 }).notNull(),
    tokenToRedeem: varchar("token_to_redeem", { length: 42 }).notNull(),
    discountPpm: text("discount_ppm").notNull(),
    signer: varchar("signer", { length: 42 }).notNull(),
    protocol: varchar("protocol", { length: 42 }).notNull(),
    nonce: varchar("nonce", { length: 66 }).notNull(),
    deadline: bigint("deadline", { mode: "number" }).notNull(),
    signerSignature: text("signer_signature").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  },
  (table) => ({
    livePairIdx: uniqueIndex("rfq_discounts_live_pair_idx").on(table.chainId, table.vault, table.tokenToRedeem),
    pairIdx: index("rfq_discounts_pair_idx").on(table.chainId, table.vault, table.tokenToRedeem),
  }),
);

export const ordersTable = rfqBackend.table(
  "orders",
  {
    id: uuid("id").primaryKey(),
    requestId: uuid("request_id").notNull(),
    quoteId: uuid("quote_id").notNull(),
    orderHash: varchar("order_hash", { length: 66 }).notNull().unique(),
    swapper: varchar("swapper", { length: 42 }).notNull(),
    filler: varchar("filler", { length: 42 }).notNull(),
    tokenIn: varchar("token_in", { length: 42 }).notNull(),
    amountIn: text("amount_in").notNull(),
    nonce: varchar("nonce", { length: 66 }).notNull(),
    deadline: bigint("deadline", { mode: "number" }).notNull(),
    encodedOrder: text("encoded_order").notNull(),
    protocolSignature: text("protocol_signature").notNull(),
    swapperSignature: text("swapper_signature").notNull(),
    publicStatus: orderPublicStatusEnum("public_status").notNull(),
    internalStatus: orderInternalStatusEnum("internal_status").notNull(),
    txHash: varchar("tx_hash", { length: 66 }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  },
  (table) => ({
    quoteIdx: index("rfq_orders_quote_idx").on(table.quoteId),
    swapperIdx: index("rfq_orders_swapper_idx").on(table.swapper),
    fillerIdx: index("rfq_orders_filler_idx").on(table.filler),
    publicStatusIdx: index("rfq_orders_public_status_idx").on(table.publicStatus),
  }),
);

export const orderOutputsTable = rfqBackend.table(
  "order_outputs",
  {
    orderId: uuid("order_id").notNull(),
    outputIndex: integer("output_index").notNull(),
    token: varchar("token", { length: 42 }).notNull(),
    recipient: varchar("recipient", { length: 42 }).notNull(),
    amount: text("amount").notNull(),
  },
  (table) => ({
    pk: primaryKey({ columns: [table.orderId, table.outputIndex] }),
    orderIdx: index("rfq_order_outputs_order_idx").on(table.orderId),
  }),
);

export const orderStatusHistoryTable = rfqBackend.table(
  "order_status_history",
  {
    id: uuid("id").primaryKey(),
    orderId: uuid("order_id").notNull(),
    publicStatus: orderPublicStatusEnum("public_status").notNull(),
    internalStatus: orderInternalStatusEnum("internal_status").notNull(),
    reason: text("reason"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  },
  (table) => ({
    orderIdx: index("rfq_order_status_history_order_idx").on(table.orderId),
  }),
);

export const reactorFillTable = rfqIndexer.table(
  "reactor_fill",
  {
    id: text("id").primaryKey(),
    txHash: varchar("tx_hash", { length: 66 }).notNull(),
    orderHash: varchar("order_hash", { length: 66 }).notNull(),
  },
  (table) => ({
    orderHashIdx: index("rfq_indexer_reactor_fill_order_hash_idx").on(table.orderHash),
  }),
);

export const reactorFillOutputTable = rfqIndexer.table(
  "reactor_fill_output",
  {
    fillId: text("fill_id").notNull(),
    outputIndex: integer("output_index").notNull(),
    token: varchar("token", { length: 42 }).notNull(),
    recipient: varchar("recipient", { length: 42 }).notNull(),
    amount: text("amount").notNull(),
  },
  (table) => ({
    pk: primaryKey({ columns: [table.fillId, table.outputIndex] }),
    fillIdx: index("rfq_indexer_reactor_fill_output_fill_idx").on(table.fillId),
  }),
);

export const vaultFactoryVaultTable = rfqIndexer.table(
  "vault_factory_vault",
  {
    id: text("id").primaryKey(),
    chainId: integer("chain_id").notNull(),
    vault: varchar("vault", { length: 42 }).notNull(),
    blockNumber: bigint("block_number", { mode: "bigint" }).notNull(),
    txHash: varchar("tx_hash", { length: 66 }).notNull(),
  },
  (table) => ({
    chainIdx: index("rfq_indexer_vault_factory_vault_chain_idx").on(table.chainId),
    vaultIdx: index("rfq_indexer_vault_factory_vault_vault_idx").on(table.vault),
  }),
);

export const adapterFillerAuthorizationTable = rfqIndexer.table(
  "instant_redemption_adapter_filler_authorization",
  {
    id: text("id").primaryKey(),
    chainId: integer("chain_id").notNull(),
    marketMaker: varchar("market_maker", { length: 42 }).notNull(),
    filler: varchar("filler", { length: 42 }).notNull(),
    status: boolean("status").notNull(),
    txHash: varchar("tx_hash", { length: 66 }).notNull(),
    blockNumber: bigint("block_number", { mode: "number" }).notNull(),
    logIndex: integer("log_index").notNull(),
  },
  (table) => ({
    fillerIdx: index("rfq_indexer_adapter_filler_authorization_filler_idx").on(table.chainId, table.filler),
    marketMakerIdx: index("rfq_indexer_adapter_filler_authorization_market_maker_idx").on(table.marketMaker),
  }),
);
