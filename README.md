![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow. The pair is intentionally small:

- `Reactor.sol` validates the signed order, pulls the input through Permit2, routes input into the instant redemption adapter, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs adapter swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.

> [!NOTE]
>
> `Executor.sol` is not a protocol requirement. It is an example filler-side executor contract that demonstrates one way to integrate with `Reactor`. Fillers can deploy their own executor implementation as long as it satisfies the expected Reactor callback flow.

## Contracts

- [Reactor.sol](src/Reactor.sol)
- [Executor.sol](src/Executor.sol)

## Flow

1. The user signs a Permit2 witness order.
2. The authorized filler calls `Executor.fill(...)`.
3. `Executor` forwards the request into `Reactor`.
4. `Reactor` validates signatures, pulls the input token, and sends swap legs to the adapter.
5. `Executor.execute(...)` performs the adapter swaps and any opaque execution payload.
6. `Reactor` enforces the requested outputs and emits the fill event used by the indexer.

## Test Locally

Run commands from the repository root:

```bash
forge build
forge test --isolate
```

## Deploy

The repository includes helper scripts for deploying the Reactor and the example Executor:

- `script/deploy/DeployExecutor.s.sol`
- `script/deploy/DeployReactor.s.sol`

Example `Executor` deployment:

```bash
REACTOR=0x... \
IR_ADAPTER=0x... \
ADMIN=0x... \
forge script script/deploy/DeployExecutor.s.sol:DeployExecutorScript \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

## Files to know

- `src/Reactor.sol`
- `src/Executor.sol`
- `src/interfaces`
- `test/Reactor.t.sol`

## Notes

- `Executor` is role-gated through `CALLER_ROLE`.
- `Reactor` uses Permit2 witness transfers and the instant redemption adapter as its execution primitives.
