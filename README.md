![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow. The pair is intentionally small:

- `Reactor.sol` validates the signed order, pulls approved input from the swapper directly into factory-registered LiquidLane adapters, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs adapter swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.

> [!NOTE]
>
> `Executor.sol` is not a protocol requirement. It is an example filler-side executor contract that demonstrates one way to integrate with `Reactor`. Fillers can deploy their own executor implementation as long as it satisfies the expected Reactor callback flow.

## Contracts

- [Reactor.sol](src/Reactor.sol)
- [Executor.sol](src/Executor.sol)

## Flow

1. The user signs the typed `Request` and approves `Reactor` to spend the input token.
2. The authorized filler calls `Executor.fill(...)`.
3. `Executor` forwards the request into `Reactor`.
4. `Reactor` validates signatures, checks each adapter against `LIQUID_LANE_ADAPTER_FACTORY`, consumes the request nonce, and transfers input token legs from the swapper to their adapters.
5. `Executor.execute(...)` performs the per-leg adapter swaps and any opaque execution payload.
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
- `Reactor` uses swapper ERC20 allowances, Reactor-managed request nonces, request deadlines, and factory-registered LiquidLane adapters as its execution primitives.
