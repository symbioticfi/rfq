import { and, asc, desc, eq, gt, inArray, lt, lte, or, sql } from "drizzle-orm";
import { getAddress } from "viem";

import type {
  DiscountRecord,
  OrderInternalStatus,
  OrderPublicStatus,
  OrderRecord,
  QuoteRequestRecord,
  SettledAmount,
  SolverConfig,
  SolverQuoteRecord,
} from "../types/domain";
import type { BackendRepositories, FillReadRepository, OrderListFilters } from "../types/repositories";
import {
  adapterFillerAuthorizationTable,
  discountsTable,
  orderOutputsTable,
  ordersTable,
  orderStatusHistoryTable,
  quoteRequestsTable,
  reactorFillOutputTable,
  reactorFillTable,
  solversTable,
  solverQuotesTable,
  vaultFactoryVaultTable,
} from "./schema";

function normalizeAddress<T extends string | null | undefined>(value: T): T {
  if (typeof value !== "string" || !value.startsWith("0x")) {
    return value;
  }

  return getAddress(value).toLowerCase() as T;
}

function normalizeOrderOutput<T extends { readonly token: `0x${string}`; readonly recipient: `0x${string}` }>(output: T): T {
  return {
    ...output,
    token: normalizeAddress(output.token),
    recipient: normalizeAddress(output.recipient),
  };
}

function normalizeQuoteRequestInput<T extends {
  readonly swapper: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly outputs: ReadonlyArray<{ readonly token: `0x${string}`; readonly recipient: `0x${string}` }>;
}>(request: T): T {
  return {
    ...request,
    swapper: normalizeAddress(request.swapper),
    tokenIn: normalizeAddress(request.tokenIn),
    tokenOut: normalizeAddress(request.tokenOut),
    outputs: request.outputs.map(normalizeOrderOutput),
  };
}

type DbLike = {
  readonly select: (...args: any[]) => any;
  readonly insert: (...args: any[]) => any;
  readonly update: (...args: any[]) => any;
  readonly execute: (...args: any[]) => Promise<{ rows: unknown[] }>;
};

function mapSolver(row: typeof solversTable.$inferSelect): SolverConfig {
  return {
    id: row.id,
    chainId: row.chainId,
    name: row.name,
    endpointUrl: row.endpointUrl,
    notifyUrl: row.notifyUrl,
    filler: normalizeAddress(row.filler as `0x${string}`),
    enabled: row.enabled,
    cooldownUntil: row.cooldownUntil,
    metadata: row.metadata,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function mapQuoteRequest(row: typeof quoteRequestsTable.$inferSelect): QuoteRequestRecord {
  return {
    id: row.id,
    requestId: row.requestId,
    quoteId: row.quoteId,
    phase: row.phase,
    request: normalizeQuoteRequestInput(row.requestPayload as QuoteRequestRecord["request"]),
    permitData: row.permitData as QuoteRequestRecord["permitData"],
    outputs: (row.outputs as QuoteRequestRecord["outputs"]).map(normalizeOrderOutput),
    bestAmountOut: row.bestAmountOut,
    bestFiller: normalizeAddress(row.bestFiller as `0x${string}` | null),
    selectedSolverId: row.selectedSolverId,
    expiresAt: row.expiresAt,
    createdAt: row.createdAt,
  };
}

function mapOrder(
  row: typeof ordersTable.$inferSelect,
  outputs: (typeof orderOutputsTable.$inferSelect)[],
): OrderRecord {
  return {
    orderId: row.id,
    quoteId: row.quoteId,
    requestId: row.requestId,
    swapper: normalizeAddress(row.swapper as `0x${string}`),
    filler: normalizeAddress(row.filler as `0x${string}`),
    tokenIn: normalizeAddress(row.tokenIn as `0x${string}`),
    amountIn: row.amountIn,
    outputs: outputs
      .sort((left, right) => left.outputIndex - right.outputIndex)
      .map((output) => ({
        token: normalizeAddress(output.token as `0x${string}`),
        recipient: normalizeAddress(output.recipient as `0x${string}`),
        amount: output.amount,
      })),
    deadline: row.deadline,
    nonce: row.nonce as `0x${string}`,
    orderHash: row.orderHash as `0x${string}`,
    encodedOrder: row.encodedOrder as `0x${string}`,
    protocolSignature: row.protocolSignature as `0x${string}`,
    swapperSignature: row.swapperSignature as `0x${string}`,
    publicStatus: row.publicStatus,
    internalStatus: row.internalStatus,
    txHash: row.txHash as `0x${string}` | null,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function mapSolverQuote(row: typeof solverQuotesTable.$inferSelect): SolverQuoteRecord {
  return {
    id: row.id,
    quoteRequestId: row.quoteRequestId,
    solverId: row.solverId,
    phase: row.phase,
    status: row.status,
    latencyMs: row.latencyMs,
    amountOut: row.amountOut,
    filler: normalizeAddress(row.filler as `0x${string}` | null),
    responsePayload: row.responsePayload,
    errorMessage: row.errorMessage,
    createdAt: row.createdAt,
  };
}

function mapDiscount(row: typeof discountsTable.$inferSelect): DiscountRecord {
  return {
    discountId: row.discountId as `0x${string}`,
    chainId: row.chainId,
    vault: normalizeAddress(row.vault as `0x${string}`),
    tokenToRedeem: normalizeAddress(row.tokenToRedeem as `0x${string}`),
    discountPpm: row.discountPpm,
    signer: normalizeAddress(row.signer as `0x${string}`),
    protocol: normalizeAddress(row.protocol as `0x${string}`),
    nonce: row.nonce as `0x${string}`,
    deadline: row.deadline,
    signerSignature: row.signerSignature as `0x${string}`,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

/**
 * @dev Creates typed repository adapters over the backend and indexer schemas.
 * @param db The Drizzle db handle.
 * @returns Repository implementations used by the RFQ service.
 */
export function createBackendRepositories(db: DbLike): BackendRepositories {
  return {
    solvers: {
      async create(solver) {
        await db.insert(solversTable).values({
          id: solver.id,
          chainId: solver.chainId,
          name: solver.name,
          endpointUrl: solver.endpointUrl,
          notifyUrl: solver.notifyUrl,
          filler: normalizeAddress(solver.filler),
          enabled: solver.enabled,
          cooldownUntil: solver.cooldownUntil,
          metadata: solver.metadata,
          createdAt: solver.createdAt,
          updatedAt: solver.updatedAt,
        });
      },
      async upsert(solver) {
        const existing = await db.select().from(solversTable).where(eq(solversTable.id, solver.id)).limit(1);

        if (!existing[0]) {
          await this.create(solver);
          return;
        }

        await db
          .update(solversTable)
          .set({
            chainId: solver.chainId,
            name: solver.name,
            endpointUrl: solver.endpointUrl,
            notifyUrl: solver.notifyUrl,
            filler: normalizeAddress(solver.filler),
            enabled: solver.enabled,
            cooldownUntil: solver.cooldownUntil,
            metadata: solver.metadata,
            updatedAt: solver.updatedAt,
          })
          .where(eq(solversTable.id, solver.id));
      },
      async listEligible(chainId, at) {
        const rows = await db
          .select()
          .from(solversTable)
          .where(
            and(
              eq(solversTable.chainId, chainId),
              eq(solversTable.enabled, true),
              or(sql`${solversTable.cooldownUntil} is null`, lte(solversTable.cooldownUntil, at)),
            ),
          );

        return rows.map(mapSolver);
      },
    },
    quotes: {
      async create(quoteRequest) {
        await db.insert(quoteRequestsTable).values({
          id: quoteRequest.id,
          requestId: quoteRequest.requestId,
          quoteId: quoteRequest.quoteId,
          phase: quoteRequest.phase,
          requestPayload: normalizeQuoteRequestInput(quoteRequest.request),
          permitData: quoteRequest.permitData,
          outputs: quoteRequest.outputs.map(normalizeOrderOutput),
          bestAmountOut: quoteRequest.bestAmountOut,
          bestFiller: normalizeAddress(quoteRequest.bestFiller),
          selectedSolverId: quoteRequest.selectedSolverId,
          expiresAt: quoteRequest.expiresAt,
          createdAt: quoteRequest.createdAt,
        });
      },
      async finalize(input) {
        await db
          .update(quoteRequestsTable)
          .set({
            permitData: input.permitData,
            outputs: input.outputs.map(normalizeOrderOutput),
            bestAmountOut: input.bestAmountOut,
            bestFiller: normalizeAddress(input.bestFiller),
            selectedSolverId: input.solverId,
          })
          .where(eq(quoteRequestsTable.quoteId, input.quoteId));
      },
      async findByQuoteId(quoteId) {
        const row = await db.select().from(quoteRequestsTable).where(eq(quoteRequestsTable.quoteId, quoteId)).limit(1);
        return row[0] ? mapQuoteRequest(row[0]) : null;
      },
    },
    solverQuotes: {
      async create(record) {
        await db.insert(solverQuotesTable).values({
          id: record.id,
          quoteRequestId: record.quoteRequestId,
          solverId: record.solverId,
          phase: record.phase,
          status: record.status,
          latencyMs: record.latencyMs,
          amountOut: record.amountOut,
          filler: normalizeAddress(record.filler),
          responsePayload: record.responsePayload,
          errorMessage: record.errorMessage,
          createdAt: record.createdAt,
        });
      },
      async listByQuoteRequest(quoteRequestId) {
        const rows = await db
          .select()
          .from(solverQuotesTable)
          .where(eq(solverQuotesTable.quoteRequestId, quoteRequestId));
        return rows.map(mapSolverQuote);
      },
    },
    discounts: {
      async upsertLive(record) {
        const existing = await db
          .select()
          .from(discountsTable)
          .where(
            and(
              eq(discountsTable.chainId, record.chainId),
              eq(discountsTable.vault, normalizeAddress(record.vault)),
              eq(discountsTable.tokenToRedeem, normalizeAddress(record.tokenToRedeem)),
            ),
          );

        if (!existing[0]) {
          await db.insert(discountsTable).values({
            discountId: record.discountId,
            chainId: record.chainId,
            vault: normalizeAddress(record.vault),
            tokenToRedeem: normalizeAddress(record.tokenToRedeem),
            discountPpm: record.discountPpm,
            signer: normalizeAddress(record.signer),
            protocol: normalizeAddress(record.protocol),
            nonce: record.nonce,
            deadline: record.deadline,
            signerSignature: record.signerSignature,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
          });
          return;
        }

        await db
          .update(discountsTable)
          .set({
            discountId: record.discountId,
            discountPpm: record.discountPpm,
            signer: normalizeAddress(record.signer),
            protocol: normalizeAddress(record.protocol),
            nonce: record.nonce,
            deadline: record.deadline,
            signerSignature: record.signerSignature,
            updatedAt: record.updatedAt,
          })
          .where(eq(discountsTable.discountId, existing[0].discountId));
      },
      async listLive(chainId) {
        const rows = await db.select().from(discountsTable).where(eq(discountsTable.chainId, chainId));
        return rows.map(mapDiscount);
      },
      async findByDiscountId(discountId) {
        const rows = await db.select().from(discountsTable).where(eq(discountsTable.discountId, discountId)).limit(1);
        return rows[0] ? mapDiscount(rows[0]) : null;
      },
      async findByPair(chainId, vault, tokenToRedeem) {
        const rows = await db
          .select()
          .from(discountsTable)
          .where(
            and(
              eq(discountsTable.chainId, chainId),
              eq(discountsTable.vault, normalizeAddress(vault)),
              eq(discountsTable.tokenToRedeem, normalizeAddress(tokenToRedeem)),
            ),
          )
          .limit(1);
        return rows[0] ? mapDiscount(rows[0]) : null;
      },
      async deleteByDiscountId(discountId) {
        await db.execute(sql`delete from ${discountsTable} where ${discountsTable.discountId} = ${discountId}`);
      },
      async deleteByPair(chainId, vault, tokenToRedeem) {
        await db.execute(
          sql`delete from ${discountsTable}
              where ${discountsTable.chainId} = ${chainId}
                and ${discountsTable.vault} = ${normalizeAddress(vault)}
                and ${discountsTable.tokenToRedeem} = ${normalizeAddress(tokenToRedeem)}`,
        );
      },
    },
    orders: {
      async create(order) {
        await db.insert(ordersTable).values({
          id: order.orderId,
          requestId: order.requestId,
          quoteId: order.quoteId,
          orderHash: order.orderHash,
          swapper: normalizeAddress(order.swapper),
          filler: normalizeAddress(order.filler),
          tokenIn: normalizeAddress(order.tokenIn),
          amountIn: order.amountIn,
          nonce: order.nonce,
          deadline: order.deadline,
          encodedOrder: order.encodedOrder,
          protocolSignature: order.protocolSignature,
          swapperSignature: order.swapperSignature,
          publicStatus: order.publicStatus,
          internalStatus: order.internalStatus,
          txHash: order.txHash,
          createdAt: order.createdAt,
          updatedAt: order.updatedAt,
        });

        if (order.outputs.length > 0) {
          await db.insert(orderOutputsTable).values(
            order.outputs.map((output, outputIndex) => ({
              orderId: order.orderId,
              outputIndex,
              token: normalizeAddress(output.token),
              recipient: normalizeAddress(output.recipient),
              amount: output.amount,
            })),
          );
        }
      },
      async findByOrderId(orderId) {
        const rows = await db.select().from(ordersTable).where(eq(ordersTable.id, orderId)).limit(1);
        if (!rows[0]) {
          return null;
        }
        const outputs = await db.select().from(orderOutputsTable).where(eq(orderOutputsTable.orderId, orderId));
        return mapOrder(rows[0], outputs);
      },
      async findByQuoteIdAndSignature(quoteId, swapperSignature) {
        const rows = await db
          .select()
          .from(ordersTable)
          .where(and(eq(ordersTable.quoteId, quoteId), eq(ordersTable.swapperSignature, swapperSignature)))
          .limit(1);

        if (!rows[0]) {
          return null;
        }

        const outputs = await db.select().from(orderOutputsTable).where(eq(orderOutputsTable.orderId, rows[0].id));
        return mapOrder(rows[0], outputs);
      },
      async list(filters) {
        const whereClauses = [];
        if (filters.orderId) whereClauses.push(eq(ordersTable.id, filters.orderId));
        if (filters.orderIds && filters.orderIds.length > 0)
          whereClauses.push(inArray(ordersTable.id, [...filters.orderIds]));
        if (filters.orderHash) whereClauses.push(eq(ordersTable.orderHash, filters.orderHash));
        if (filters.orderHashes && filters.orderHashes.length > 0)
          whereClauses.push(inArray(ordersTable.orderHash, [...filters.orderHashes]));
        if (filters.orderStatus) whereClauses.push(eq(ordersTable.publicStatus, filters.orderStatus));
        if (filters.swapper) whereClauses.push(eq(ordersTable.swapper, normalizeAddress(filters.swapper)));
        if (filters.filler) whereClauses.push(eq(ordersTable.filler, normalizeAddress(filters.filler)));

        const limit = filters.limit ?? 20;
        const orderBy = filters.sort === "asc" ? asc : desc;
        const sortColumn = filters.sortKey === "updatedAt" ? ordersTable.updatedAt : ordersTable.createdAt;
        if (filters.cursor) {
          const [cursorRow] = await db
            .select({
              id: ordersTable.id,
              createdAt: ordersTable.createdAt,
              updatedAt: ordersTable.updatedAt,
            })
            .from(ordersTable)
            .where(eq(ordersTable.id, filters.cursor))
            .limit(1);

          if (cursorRow) {
            const cursorValue = filters.sortKey === "updatedAt" ? cursorRow.updatedAt : cursorRow.createdAt;
            const cursorClause =
              filters.sort === "asc"
                ? or(gt(sortColumn, cursorValue), and(eq(sortColumn, cursorValue), gt(ordersTable.id, cursorRow.id)))
                : or(lt(sortColumn, cursorValue), and(eq(sortColumn, cursorValue), lt(ordersTable.id, cursorRow.id)));
            whereClauses.push(cursorClause);
          }
        }
        const rows = await db
          .select()
          .from(ordersTable)
          .where(whereClauses.length > 0 ? and(...whereClauses) : undefined)
          .orderBy(orderBy(sortColumn), orderBy(ordersTable.id))
          .limit(limit + 1);

        const hasMore = rows.length > limit;
        const selectedRows = rows.slice(0, limit);
        const orderIds = selectedRows.map((row: typeof ordersTable.$inferSelect) => row.id);
        const outputs =
          orderIds.length === 0
            ? []
            : await db.select().from(orderOutputsTable).where(inArray(orderOutputsTable.orderId, orderIds));
        const outputsByOrderId = new Map<string, typeof outputs>();
        for (const output of outputs) {
          const list = outputsByOrderId.get(output.orderId) ?? [];
          list.push(output);
          outputsByOrderId.set(output.orderId, list);
        }

        return {
          orders: selectedRows.map((row: typeof ordersTable.$inferSelect) =>
            mapOrder(row, outputsByOrderId.get(row.id) ?? []),
          ),
          cursor: hasMore ? (selectedRows[selectedRows.length - 1]?.id ?? null) : null,
        };
      },
      async updateStatus(orderId, publicStatus, internalStatus, txHash) {
        await db
          .update(ordersTable)
          .set({
            publicStatus,
            internalStatus,
            txHash: txHash ?? null,
            updatedAt: new Date(),
          })
          .where(eq(ordersTable.id, orderId));
      },
    },
    orderStatusHistory: {
      async append(input) {
        await db.insert(orderStatusHistoryTable).values({
          id: crypto.randomUUID(),
          orderId: input.orderId,
          publicStatus: input.publicStatus,
          internalStatus: input.internalStatus,
          reason: input.reason,
          createdAt: input.createdAt,
        });
      },
    },
    fills: createFillReadRepository(db),
  };
}

function createFillReadRepository(db: DbLike): FillReadRepository {
  return {
    async listSettledAmounts(orderHashes) {
      if (orderHashes.length === 0) {
        return new Map();
      }

      let rows: Array<{
        orderHash: `0x${string}`;
        token: `0x${string}`;
        amount: string;
        recipient: `0x${string}`;
        txHash: `0x${string}`;
      }>;
      try {
        rows = await db
          .select({
            orderHash: reactorFillTable.orderHash,
            token: reactorFillOutputTable.token,
            amount: reactorFillOutputTable.amount,
            recipient: reactorFillOutputTable.recipient,
            txHash: reactorFillTable.txHash,
          })
          .from(reactorFillTable)
          .innerJoin(reactorFillOutputTable, eq(reactorFillOutputTable.fillId, reactorFillTable.id))
          .where(inArray(reactorFillTable.orderHash, orderHashes));
      } catch (error) {
        if (isMissingIndexerRelation(error)) {
          return new Map();
        }
        throw error;
      }

      const settledAmounts = new Map<`0x${string}`, SettledAmount[]>();
      for (const row of rows) {
        const orderHash = row.orderHash;
        const entries = settledAmounts.get(orderHash) ?? [];
        entries.push({
          token: normalizeAddress(row.token),
          amount: String(row.amount),
          recipient: normalizeAddress(row.recipient),
          txHash: row.txHash,
        });
        settledAmounts.set(orderHash, entries);
      }

      return settledAmounts;
    },
    async listAuthorizedFillersForMarketMakers(chainId, marketMakers) {
      if (marketMakers.length === 0) {
        return new Map();
      }

      let rows: Array<{ marketMaker: `0x${string}`; filler: `0x${string}` }>;
      try {
        rows = await db
          .select({
            marketMaker: adapterFillerAuthorizationTable.marketMaker,
            filler: adapterFillerAuthorizationTable.filler,
          })
          .from(adapterFillerAuthorizationTable)
          .where(
            and(
              eq(adapterFillerAuthorizationTable.chainId, chainId),
              eq(adapterFillerAuthorizationTable.status, true),
              inArray(
                adapterFillerAuthorizationTable.marketMaker,
                marketMakers.map((marketMaker) => normalizeAddress(marketMaker)),
              ),
            ),
          );
      } catch (error) {
        if (isMissingIndexerRelation(error)) {
          return new Map();
        }
        throw error;
      }

      const authorizations = new Map<string, Set<string>>();
      for (const row of rows) {
        const marketMaker = normalizeAddress(row.marketMaker);
        const filler = normalizeAddress(row.filler);
        const fillers = authorizations.get(marketMaker) ?? new Set<string>();
        fillers.add(filler);
        authorizations.set(marketMaker, fillers);
      }

      return authorizations;
    },
    async listIndexedVaults(chainId) {
      try {
        const rows = await db
          .select({ vault: vaultFactoryVaultTable.vault })
          .from(vaultFactoryVaultTable)
          .where(eq(vaultFactoryVaultTable.chainId, chainId));

        return rows.map((row: { readonly vault: string }) => normalizeAddress(row.vault as `0x${string}`));
      } catch (error) {
        if (isMissingIndexerRelation(error)) {
          return [];
        }
        throw error;
      }
    },
  };
}

function isMissingIndexerRelation(error: unknown) {
  const code = typeof error === "object" && error !== null && "code" in error ? String(error.code) : "";
  if (code === "42P01" || code === "3F000") {
    return true;
  }

  const message = error instanceof Error ? error.message : String(error);
  return (
    message.includes('schema "rfq_indexer" does not exist') ||
    message.includes('relation "rfq_indexer.instant_redemption_adapter_filler_authorization" does not exist') ||
    message.includes('relation "rfq_indexer.reactor_fill" does not exist') ||
    message.includes('relation "rfq_indexer.reactor_fill_output" does not exist') ||
    message.includes('Failed query: select "rfq_indexer"."reactor_fill"."order_hash"') ||
    message.includes('from "rfq_indexer"."reactor_fill" inner join "rfq_indexer"."reactor_fill_output"')
  );
}
