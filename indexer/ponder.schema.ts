import { index, onchainTable, primaryKey } from "ponder";

export const reactorFill = onchainTable(
  "reactor_fill",
  (t) => ({
    id: t.text().primaryKey().notNull(),
    chainId: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    orderHash: t.hex().notNull(),
    swapper: t.hex().notNull(),
    filler: t.hex().notNull(),
    tokenIn: t.hex().notNull(),
    amountIn: t.bigint().notNull(),
    deadline: t.bigint().notNull(),
    nonce: t.bigint().notNull(),
    protocol: t.hex().notNull(),
    swapperSignature: t.hex().notNull(),
  }),
  (table) => ({
    orderHashIdx: index().on(table.orderHash),
    txHashIdx: index().on(table.txHash),
  }),
);

export const reactorFillOutput = onchainTable(
  "reactor_fill_output",
  (t) => ({
    fillId: t.text().notNull(),
    outputIndex: t.integer().notNull(),
    token: t.hex().notNull(),
    recipient: t.hex().notNull(),
    amount: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.fillId, table.outputIndex] }),
    fillIdx: index().on(table.fillId),
  }),
);

export const vaultFactoryVault = onchainTable(
  "vault_factory_vault",
  (t) => ({
    id: t.text().primaryKey().notNull(),
    chainId: t.integer().notNull(),
    vault: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    chainIdx: index().on(table.chainId),
    vaultIdx: index().on(table.vault),
  }),
);

export const instantRedemptionAdapterFillerAuthorization = onchainTable(
  "instant_redemption_adapter_filler_authorization",
  (t) => ({
    id: t.text().primaryKey().notNull(),
    chainId: t.integer().notNull(),
    marketMaker: t.hex().notNull(),
    filler: t.hex().notNull(),
    status: t.boolean().notNull(),
    txHash: t.hex().notNull(),
    blockNumber: t.integer().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    fillerIdx: index().on(table.chainId, table.filler),
    marketMakerIdx: index().on(table.marketMaker),
  }),
);

export const instantRedemptionAdapterInvalidatedNonce = onchainTable(
  "instant_redemption_adapter_invalidated_nonce",
  (t) => ({
    id: t.text().primaryKey().notNull(),
    chainId: t.integer().notNull(),
    vault: t.hex().notNull(),
    tokenToRedeem: t.hex().notNull(),
    nonce: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    blockNumber: t.integer().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    pairIdx: index().on(table.chainId, table.vault, table.tokenToRedeem),
    nonceIdx: index().on(table.chainId, table.vault, table.tokenToRedeem, table.nonce),
  }),
);
