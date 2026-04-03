![Symbiotic RFQ](public/lockup.png)

# RFQ Frontend

The RFQ frontend is the browser client for the Symbiotic instant redemption flow. It is a Vite + React Router application that lets users connect a wallet, request indicative RFQ quotes, sign Permit2 witness orders, submit orders to the backend, and track order status from the same swap card.

## What it does

- Uses the doc-defined backend flow: `POST /check_approval`, `POST /quote`, `POST /order`, `GET /orders`
- Supports wallet connection through Privy and wagmi
- Shows local-only faucet tooling for development deployments
- Polls active orders and restores pending state after reload
- Uses the generated deployment manifest in `src/generated/deployment.json`

## Stack

- Vite
- React Router framework mode
- TypeScript
- viem + wagmi
- Privy
- TanStack Query
- Sonner

## Run locally

From `rfq/frontend`:

```bash
pnpm install
pnpm dev
```

The dev script syncs the current deployment manifest before starting the app.

For the full local stack, start everything from `rfq/` instead:

```bash
pnpm local:dev
```

## Build

```bash
pnpm build
pnpm preview
```

## Environment

Runtime and build-time envs used by the app:

- `VITE_API_URL`
- `VITE_PRIVY_APP_ID`
- `VITE_WALLET_RPC_URL`
- `VITE_WALLET_CHAIN_NAME`

Dev-server only:

- `VITE_API_PROXY_TARGET`
- `PORT`

> [!NOTE]
> Default slippage is fixed in code at `0.5%` (`50` bps). It is no longer configured via env.

## Project layout

- `src/features/swap` — swap card, settings, advanced details, order UI
- `src/features/faucet` — local and Hoodi faucet page
- `src/hooks` — quote polling, execution, balances, prices, active-order state
- `src/providers` — Privy, wagmi, chain, theme, wallet wiring
- `src/generated/deployment.json` — frontend deployment manifest consumed at build time

## Quality checks

```bash
pnpm check
pnpm lint
pnpm test
pnpm format:check
```

## Notes

- Local token and contract addresses come from the synced deployment manifest, not hardcoded app constants.
- Non-mainnet price labels use the local mocked pricing map for UI convenience.
- The frontend is a static SPA. The deployment manifest is bundled at build time, so it deploys cleanly to Vercel without runtime filesystem access.

## Vercel

Recommended Vercel project settings:

- Root Directory: `rfq/frontend`
- Framework Preset: `Vite`
- Build Command: `pnpm build`
- Output Directory: `build/client`

Required env vars:

- `VITE_API_URL`
- `VITE_PRIVY_APP_ID`
- `VITE_WALLET_RPC_URL`
- `VITE_WALLET_CHAIN_NAME`

Checked-in Vercel config:

- [vercel.json](./vercel.json)
- [.env.example](./.env.example)

The Vercel rewrite keeps deep links working for the SPA by rewriting unmatched routes to `index.html`.

Optional CLI deploy:

```bash
pnpm deploy:vercel
```
