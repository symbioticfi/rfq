![Symbiotic RFQ](../frontend/public/lockup.png)

# RFQ Indexer

The RFQ indexer is a Ponder-based event indexer for the Reactor and Instant Redemption Adapter contracts. It writes normalized onchain state into Postgres so the backend can reconcile settled orders and delegated filler authorization without live contract reads.

## What it indexes

- `reactor_fill`
- `reactor_fill_output`
- `instant_redemption_adapter_filler_authorization`

Those tables capture:
- fill state for settled Reactor orders and their outputs
- current delegated filler authorization state keyed by `marketMaker + filler`

## Run locally

From `rfq/indexer`:

```bash
pnpm install
pnpm dev
```

Other useful commands:

```bash
pnpm start
pnpm serve
pnpm db
pnpm codegen
```

## Environment

- `RFQ_DATABASE_URL`
- `RFQ_INDEXER_START_BLOCK`
- `RFQ_INDEXER_PGLITE_DIR`
- `RFQ_RPC_URLS`

> [!NOTE]
> Postgres mode uses `RFQ_DATABASE_URL` and sets `search_path=rfq_indexer`. There is no separate `RFQ_INDEXER_DATABASE_URL` anymore.

## Files to know

- `ponder.config.ts` — Ponder entrypoint
- `config/local.ts` — Anvil/local chain configuration
- `config/hoodi.ts` — Hoodi chain configuration
- `config/mainnet.ts` — Mainnet chain configuration
- `config/base.ts` — shared deployment, DB, and RPC wiring
- `ponder.schema.ts` — indexed table definitions
- `src/index.ts` — registry bootstrap
- `src/indexer/index.ts` — event registration exports
- `src/indexer/contracts/*` — event-to-state mappers and handlers

## Quality checks

```bash
pnpm check
pnpm test
pnpm format:check
```

## Railway

Checked-in deploy config:

- [railway.json](./railway.json)
- [.env.example](./.env.example)

## Notes

- Runtime config reads the generated in-package manifest at `src/generated/deployment.ts`.
- `RFQ_DEPLOYMENT_ENV` is only used by `sync:deployment` and `dev/build/start/serve` to choose the package-local manifest under `deployments/<env>/addresses.json`.
- Live chain/indexer integration tests live under [rfq/integration](/Users/andreikorokhov/symbiotic/core-mirror/rfq/integration), so the indexer package keeps only service-local tests.
- The backend reads indexed fill data from the protocol database to reconcile order status.
- The backend also reads indexed delegated filler authorization state instead of querying `SetFiller` permissions live.
- Local dev runs with the `rfq_indexer` schema and `rfq_indexer_views` views schema.
