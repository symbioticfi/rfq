![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow:

- `Reactor.sol` validates the signed order, pulls the input through Permit2, routes input into the instant redemption adapter, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs adapter swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.
- `Router.sol` is an ownerless, user-directed execution surface that directly funds registered LiquidLane adapters from the caller and settles transaction-local output deltas.

> [!NOTE]
> `Executor.sol` is not a protocol requirement. It is an example filler-side executor contract that demonstrates one way to integrate with `Reactor`. Fillers can deploy their own executor implementation as long as it satisfies the expected Reactor callback flow.

## Contracts

- [Reactor.sol](src/Reactor.sol)
- [Executor.sol](src/Executor.sol)
- [Router.sol](src/Router.sol)

## Flow

1. The user signs a Permit2 witness order.
2. The authorized filler calls `Executor.fill(...)`.
3. `Executor` forwards the request into `Reactor`.
4. `Reactor` validates signatures, pulls the input token, and sends swap legs to the adapter.
5. `Executor.execute(...)` performs the adapter swaps and any opaque execution payload.
6. `Reactor` enforces the requested outputs and emits the fill event used by the indexer.

## User-directed swap flow

1. The user approves the input ERC-20 to `Router` using an ordinary ERC-20 allowance.
2. The user requests an unsigned transaction from the backend `/api/v1/swap` endpoint.
3. `Router.execute(tokenIn, calls, outputs, deadline)` transfers each leg directly from the user to its adapter, invokes the provided calldata, and pays the declared recipients.
4. Any transaction-local surplus is returned to the caller; balances that predate the call are never used for settlement.

The Router supports standard ERC-20 tokens and distinct input/output tokens only. Every adapter must be registered by `LIQUID_LANE_ADAPTER_FACTORY`, and calldata must use either the signed-swap selector `0x9a4568b6` or discount-swap selector `0x8fa5c671`. The batch is atomic: a failed leg or unmet output reverts every transfer.

## Test locally

This folder is part of the root Foundry workspace, so run commands from the repository root:

```bash
forge build
forge test --match-path rfq/reactor/test/Reactor.t.sol
```

## Deploy

The repository includes helper scripts for deploying the example executor and Router:

- `rfq/reactor/script/deploy/DeployExecutor.s.sol`
- `rfq/reactor/script/deploy/DeployRouter.s.sol`

Example `Executor` deployment:

```bash
cd <repo-root>
REACTOR=0x... \
IR_ADAPTER=0x... \
ADMIN=0x... \
forge script rfq/reactor/script/deploy/DeployExecutor.s.sol:DeployExecutorScript \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Example `Router` deployment:

```bash
cd <repo-root>
LIQUID_LANE_ADAPTER_FACTORY=0x... \
forge script rfq/reactor/script/deploy/DeployRouter.s.sol:DeployRouterScript \
  --rpc-url "$RPC_URL" \
  --account "$ACCOUNT" \
  --sender "$SENDER" \
  --broadcast
```

## Files to know

- `src/Reactor.sol`
- `src/Executor.sol`
- `src/Router.sol`
- `src/interfaces`
- `test/Reactor.t.sol`
- `test/Router.t.sol`

## Notes

- `Executor` is role-gated through `CALLER_ROLE`.
- `Reactor` uses Permit2 witness transfers and the instant redemption adapter as its execution primitives.
