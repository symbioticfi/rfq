![Symbiotic RFQ](../frontend/public/lockup.png)

# RFQ Backend

The RFQ backend is the protocol-owned HTTP API for the instant redemption flow. It validates user requests, fans out quote requests to configured fillers, creates Permit2 witness orders, stores order state in Postgres, and exposes order polling and local development helpers.

## What it does

- Checks Permit2 approval state
- Fans out quote requests to external fillers
- Creates signed RFQ orders backed by the Reactor contracts
- Stores quotes and orders in Postgres with Drizzle
- Reconciles order state with indexed onchain fills
- Exposes OpenAPI docs and metrics

## API surface

Main routes:

- `GET /health`
- `GET /openapi.json`
- `GET /docs`
- `GET /metrics`
- `POST /check_approval`
- `POST /quote`
- `POST /order`
- `GET /orders`

Local-only helpers:

- `POST /dev/fund`
- `GET /dev/faucet`
- `POST /dev/faucet`

## Run locally

From `rfq/backend`:

```bash
pnpm install
pnpm dev
```

For the full local stack, run from `rfq/`:

```bash
pnpm local:dev
```

That root shortcut now delegates to the integration harness in [rfq/integration](/Users/andreikorokhov/symbiotic/core-mirror/rfq/integration).

## Environment

Required:

- `RFQ_PROTOCOL_SIGNER_PRIVATE_KEY`
- `RFQ_DATABASE_URL`

Optional:

- `RFQ_DEPLOYMENT_ENV`
- `RFQ_LOCAL_FUNDER_PRIVATE_KEY`
- `RFQ_SOLVER_SHARED_SECRET`
- `RFQ_RPC_URLS`
- `RFQ_HOST`
- `RFQ_PORT`
- `RFQ_PERMIT_DEADLINE_SECONDS`
- `RFQ_SOLVER_TIMEOUT_MS`

> [!NOTE]
> Permit deadline and order deadline are the same value. The backend derives both from `RFQ_PERMIT_DEADLINE_SECONDS`.

## Database

The backend uses Drizzle with Postgres and expects the `rfq_backend` schema inside the protocol database.

Common commands:

```bash
pnpm db:generate
pnpm db:migrate
pnpm db:push
```

## Development utilities

- `pnpm seed:solver` seeds the configured market maker address and solver endpoint into the solver table
- `scripts/verify-local-flow.mjs` exercises the full local flow against a running stack
- Cross-service and live-stack checks now live under [rfq/integration](/Users/andreikorokhov/symbiotic/core-mirror/rfq/integration)

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

- `RFQ_DEPLOYMENT_ENV` is only used by `sync:deployment` and `dev` to choose the package-local manifest under `deployments/<env>/addresses.json`.
- Runtime code reads the generated in-package manifest at `src/generated/deployment.ts`.
- Winner notifications are self-contained execution payloads keyed by `orderHash`.
