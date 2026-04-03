# RFQ Local To Cloud Rollout

## Local monorepo flow

The monorepo now supports a single-command local stack:

```bash
cd rfq
pnpm local:dev
```

The root command is just a shortcut. The integration harness now lives in [integration](../integration):

```bash
cd rfq/integration
pnpm local:dev
```

That command:

1. starts Docker Compose infra from [docker-compose.local.yml](../docker-compose.local.yml)
2. creates one Postgres instance for protocol data:
   - `rfq_protocol`
3. starts `anvil`
4. deploys the RFQ stack with [DeployRfqStack.s.sol](../integration/script/DeployRfqStack.s.sol)
5. writes [deployments/local/addresses.json](../deployments/local/addresses.json)
6. pushes Drizzle schemas for backend
7. seeds the protocol backend with the externally owned filler
8. starts backend, indexer, filler, and frontend

Cross-service integration tests and the local verification flow also live in [integration](../integration).

Local database ownership is now:

- protocol DB: backend + indexer
- filler: in-memory only

## Deployment manifests

Per-environment manifests live at:

- [deployments/local/addresses.json](../deployments/local/addresses.json)
- [deployments/hoodi/addresses.json](../deployments/hoodi/addresses.json)
- [deployments/mainnet/addresses.json](../deployments/mainnet/addresses.json)

Protocol-owned services load protocol addresses and vaults from the manifest. The filler also loads protocol-owned addresses from that manifest, but keeps filler-owned state and executor configuration separate.

The RFQ workspace owns the canonical protocol manifest at `rfq/deployments/<env>/addresses.json`.

Each RFQ package also keeps its own `deployments/<env>/addresses.json`, and `sync-service-deployment.mjs` materializes the active in-package generated config for build/runtime use:

- backend: [backend/src/generated/deployment.ts](../backend/src/generated/deployment.ts)
- filler: [filler/src/generated/deployment.ts](../filler/src/generated/deployment.ts)
- indexer: [indexer/src/generated/deployment.ts](../indexer/src/generated/deployment.ts)
- frontend: [frontend/src/generated/deployment.json](../frontend/src/generated/deployment.json)

## Filler execution model

The filler is direct-only:

- it quotes only when one or more vaults already hold the requested `tokenOut` as collateral
- it fills only those direct-collateral orders
- it does not route collateral through any other second-leg swap provider

Local deployment still uses the real core factories, real `VaultV2`, real rewards stack, real `InstantRedemptionAdapter`, real `ChainlinkOracle`, and real `Permit2`, while keeping only synthetic local tokens, local Chainlink feed stubs, and an immediate-settlement local account implementation.

## Protocol vs filler boundaries

Protocol-owned:

- frontend
- backend
- indexer
- protocol DB

Externally owned:

- filler
- filler runtime

The filler boundary is formalized by these public JSON schemas:

- [solver-quote-request.schema.json](./contracts/v1/solver-quote-request.schema.json)
- [solver-quote-response.schema.json](./contracts/v1/solver-quote-response.schema.json)
- [filler-notify.schema.json](./contracts/v1/filler-notify.schema.json)

## Hoodi staging

Cloud staging topology:

- frontend: Vercel
- backend: Railway
- indexer: Railway
- filler: Railway
- protocol data: Neon database `rfq_protocol`
- filler: in-memory only

Recommended env split:

- frontend
  - `VITE_DEPLOYMENT_ENV=hoodi`
  - `VITE_API_URL=<railway-backend-url>`
  - `VITE_WALLET_RPC_URL=<hoodi-rpc>`
- backend
  - `RFQ_DEPLOYMENT_ENV=hoodi` for `sync:deployment` / build selection
  - `RFQ_DATABASE_URL=<neon-protocol-url>`
  - `RFQ_PROTOCOL_SIGNER_PRIVATE_KEY=<hoodi-protocol-signer>`
  - `RFQ_SOLVER_SHARED_SECRET=<shared-secret>`
  - `RFQ_RPC_URLS=<hoodi-rpc>`
- indexer
  - `RFQ_DEPLOYMENT_ENV=hoodi` for `sync:deployment` / build selection
  - `RFQ_DATABASE_URL=<neon-protocol-url>`
  - `RFQ_RPC_URLS=<hoodi-rpc>`
- filler
  - `RFQ_FILLER_DEPLOYMENT_ENV=hoodi` for `sync:deployment` / build selection
  - `RFQ_FILLER_BACKEND_URL=<railway-backend-url>`
  - `RFQ_FILLER_BACKEND_SHARED_SECRET=<shared-secret>`
  - `RFQ_FILLER_EXECUTOR_ADDRESS=<filler-owned-executor>`
  - `RFQ_FILLER_CALLER_PRIVATE_KEY=<hoodi-filler-caller>`
  - `RFQ_FILLER_DISCOUNT_PERCENT=10`
  - `RFQ_FILLER_RPC_URL=<hoodi-rpc>`

## Repo split after staging

Split only after Hoodi is green:

1. `symbiotic-rfq-backend`
2. `symbiotic-rfq-indexer`
3. `symbiotic-rfq-filler`
4. `symbiotic-rfq-frontend`
5. `symbiotic-rfq-integration`

Service repos should own their own copied `deployments/<env>/addresses.json` files at deploy time. The extracted `integration` repo is the only layer allowed to orchestrate across repos. It should resolve sibling/submodule checkouts via:

- `RFQ_WORKSPACE_DIR`
- `RFQ_BACKEND_DIR`
- `RFQ_FILLER_DIR`
- `RFQ_INDEXER_DIR`
- `SYMBIOTIC_PROTOCOL_DIR`
- `INTEGRATION_DEPLOYMENTS_DIR`

The service deploy path should not depend on the integration repo being present.
