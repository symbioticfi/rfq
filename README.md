![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow:

- `Reactor.sol` validates the signed order, pulls the input through Permit2, routes input into the instant redemption adapter, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs adapter swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.
- `Router.sol` is an ownerless, user-directed execution surface that directly funds registered LiquidLane adapters from the caller, executes their calldata inline, and transfers declared outputs.

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
3. The backend returns one or more solver legs, each containing an adapter, an input amount, and complete signed-swap or discounted-swap calldata.
4. `Router.execute(tokenIn, calls, outputs, deadline)` transfers each leg directly from the user to its adapter, invokes the provided calldata inline, and then transfers the declared outputs to their recipients.

Every adapter must be registered by `LIQUID_LANE_ADAPTER_FACTORY`. The Router does not inspect adapter calldata or add an outer authorization layer: signature, nonce, selector, and quote validation remain the adapter's responsibility. This permits both signed-swap and discounted-swap calldata. The calls and output transfers run in caller-supplied order and the entire batch is atomic.

The ABI tuple order is:

```solidity
struct SwapCall {
    address adapter;
    uint256 amountIn;
    bytes data;
}

struct Output {
    address token;
    address recipient;
    uint256 amount;
}
```

The Router intentionally performs no array, amount, token, recipient, selector, input-consumption, output-delta, or surplus validation. ERC-20 transfers and adapter calls define success. Output entries are ordinary transfers from the Router's current balances, and undeclared surplus remains in the Router. Use the deadline overload when the user wants Router-level expiry.

## Test locally

This folder is part of the root Foundry workspace, so run commands from the repository root:

```bash
forge build
forge test --match-path rfq/reactor/test/Reactor.t.sol
forge test --match-path rfq/reactor/test/Router.t.sol
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
- `Router` uses ordinary ERC-20 allowance, validates only adapter registration and an optional deadline, and forwards adapter calldata unchanged.
