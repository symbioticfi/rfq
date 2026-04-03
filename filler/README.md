![Symbiotic RFQ](../frontend/public/lockup.png)

# RFQ Filler

The filler is the externally owned solver/executor service for Symbiotic RFQ. It answers backend quote requests, accepts winner notifications, polls the backend for open orders, and submits fills through the `Executor` contract.

Protocol deployment manifests are expected to be published with this repository so external fillers can consume protocol-owned addresses without importing protocol runtime code. The filler still provides its own executor address explicitly through env.

## What it does

- Serves `POST /quote` for backend quote fanout
- Serves `POST /notify` as a wake-up signal for winning orders
- Polls the backend for open orders assigned to its executor address
- Reads pricing and capacity from the onchain adapter
- Applies a configurable quote discount before returning a quote
- Fills orders directly when the selected vault collateral already matches the requested output token

## Current scope

- Direct fills only
- No second-leg routing
- In-memory operational state only
- Access to `/quote` and `/notify` is restricted to the configured backend peer

## Run locally

From `rfq/filler`:

```bash
pnpm install
pnpm dev
```

Or start it as part of the full local stack from `rfq/`:

```bash
pnpm local:dev
```

That root shortcut now delegates to the integration harness in [rfq/integration](/Users/andreikorokhov/symbiotic/core-mirror/rfq/integration).

## Environment

- `RFQ_FILLER_DEPLOYMENT_ENV`
- `RFQ_FILLER_BACKEND_URL`
- `RFQ_FILLER_BACKEND_SHARED_SECRET`
- `RFQ_FILLER_EXECUTOR_ADDRESS`
- `RFQ_FILLER_CALLER_PRIVATE_KEY`
- `RFQ_FILLER_DISCOUNT_PERCENT`
- `RFQ_FILLER_RPC_URL`
- `RFQ_FILLER_HOST`
- `RFQ_FILLER_PORT`
- `RFQ_FILLER_POLL_INTERVAL_MS`
- `RFQ_FILLER_ORDER_LIMIT`

> [!NOTE]
> The filler uses `RFQ_FILLER_BACKEND_URL` for outbound backend calls and `RFQ_FILLER_BACKEND_SHARED_SECRET` to authenticate inbound `/quote` and `/notify` requests. `RFQ_FILLER_EXECUTOR_ADDRESS` is explicit because the executor is filler-owned, not protocol-owned.

## API surface

- `GET /health`
- `GET /openapi.json`
- `GET /docs`
- `POST /quote`
- `POST /notify`

## Architecture

- `src/services/quote-service.ts` — quote selection and discounting
- `src/services/execution-service.ts` — notify intake, polling, submission, reconciliation
- `src/lib/backend.ts` — backend client
- `src/lib/contracts.ts` — viem ABI bindings
- `src/db/repositories.ts` — in-memory state store

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

- `RFQ_FILLER_DEPLOYMENT_ENV` is only used by `sync:deployment` and `dev` to choose the package-local manifest under `deployments/<env>/addresses.json`.
- Runtime code reads the generated in-package manifest at `src/generated/deployment.ts`.
- Cross-service integration tests live under [rfq/integration](/Users/andreikorokhov/symbiotic/core-mirror/rfq/integration), not in the filler package test suite.
- The protocol deployment manifest supplies protocol-owned addresses like the instant redemption adapter. The executor address is provided by the filler operator via env.
- The filler uses the configured caller key to submit `Executor.fill(...)`.
- A quote is returned only when the filler can satisfy the requested output token directly from available vault collateral.
