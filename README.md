![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow. The pair is intentionally small:

- `Reactor.sol` validates the signed order, pulls approved input from the swapper directly into factory-registered LiquidLane adapters, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs adapter swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.
- `LiquidLaneUniswapXExecutor.sol` is a transparent-proxy, caller-gated UniswapX fill contract. It routes Reactor-supplied ERC-20 input through direct and discount LiquidLane adapters, grants the immutable Reactor output allowances, and forwards native output. The Reactor authoritatively resolves and settles orders; adapters enforce swap and discount terms. Direct and discount route arrays remain separate, and unspent input or output surplus remains on the executor. Because the Reactor has maximum ERC-20 allowances, retained balances can participate in subsequent Reactor settlement; there is no sweep entrypoint.

> [!NOTE]
>
> `Executor.sol` is not a protocol requirement. It is an example filler-side executor contract that demonstrates one way to integrate with `Reactor`. Fillers can deploy their own executor implementation as long as it satisfies the expected Reactor callback flow.

## Contracts

- [Reactor.sol](src/Reactor.sol)
- [Executor.sol](src/Executor.sol)
- [LiquidLaneUniswapXExecutor.sol](src/uniswapx/LiquidLaneUniswapXExecutor.sol)

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

## Files to know

- `src/Reactor.sol`
- `src/Executor.sol`
- `src/interfaces`
- `test/Reactor.t.sol`

## Notes

- `Executor` is caller-gated through an owner-managed caller list.
- `Reactor` uses swapper ERC20 allowances, Reactor-managed request nonces, request deadlines, and factory-registered LiquidLane adapters as its execution primitives.
