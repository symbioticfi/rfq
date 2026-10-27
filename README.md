![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow. The settlement surfaces are:

- `Reactor.sol` validates the signed order, pulls approved input from the swapper into factory-registered LiquidLane adapters/connectors, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs LiquidLane and RecipeExecutor swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.
- `LiquidLaneLifiExecutor.sol` is a caller-gated LI.FI executor that routes input settler funds through LiquidLane and RecipeExecutor legs, fills the output mandate, and attests settlement.
- `LiquidLaneUniswapXExecutor.sol` is a transparent-proxy, caller-gated UniswapX fill contract. It routes Reactor-supplied ERC-20 input through direct and discount LiquidLane adapters and RecipeExecutors, grants the immutable Reactor output allowances, and forwards native output. The Reactor authoritatively resolves and settles orders; adapters enforce swap and discount terms. Direct and discount route arrays remain separate, and unspent input or output surplus remains on the executor. Because the Reactor has maximum ERC-20 allowances, retained balances can participate in subsequent Reactor settlement; there is no sweep entrypoint.

> [!NOTE]
>
> `Executor.sol` is not a protocol requirement. It is an example filler-side executor contract that demonstrates one way to integrate with `Reactor`. Fillers can deploy their own executor implementation as long as it satisfies the expected Reactor callback flow.

## Contracts

- [Reactor.sol](src/Reactor.sol)
- [Executor.sol](src/Executor.sol)
- [LiquidLaneLifiExecutor.sol](src/lifi/LiquidLaneLifiExecutor.sol)
- [LiquidLaneUniswapXExecutor.sol](src/uniswapx/LiquidLaneUniswapXExecutor.sol)

## Flow

1. The user signs the typed `Request` and approves `Reactor` to spend the input token.
2. The authorized filler calls `Executor.fill(...)`.
3. `Executor` forwards the request into `Reactor`.
4. `Reactor` validates signatures, checks each LiquidLane adapter against `LIQUID_LANE_ADAPTER_FACTORY`, consumes the request nonce, and transfers every input leg to its registered adapter or connector.
5. `Executor.execute(...)` performs the per-leg adapter swaps, recipe execution, and any post-swap calls.
6. `Reactor` enforces the requested outputs and emits the fill event used by the indexer.

## RecipeExecutor swaps

Funding stays in the normal input arrays. Put permissioned adapter or connector
amounts in `swapInputs`, and discounted amounts in `discountSwapInputs`. LI.FI
and UniswapX use their corresponding `routes` and `discountRoutes` fields.
The executors call the original swap methods for factory version `1` adapters.
Version `2` connectors receive their input and execute through the subsequent
`Call[]` loop: `RecipeExecutor → MerkleAccount → LiquidLaneConnector`.

Register the connector implementation as version `2` in the existing Liquid Lane
adapter factory, after the version `1` adapter implementation. Create connectors
with `create(2, owner, abi.encode(account, outputAsset))` and configure the Reactor
with that shared factory. Factory versions are independent of the connector's
EIP-712 domain version, which remains `1`.

```solidity
// Each call holds target, value and ABI-encoded RecipeExecutor.execute calldata.
executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));
lifiExecutor.finaliseWithCurrentTimestamp(order, routes, discountRoutes, calls);
uniswapXExecutor.execute(signedOrder, fillCall, calls);
```

Native RFQ forwards the input arrays and opaque `executorData` unchanged. Reactor
checks factory membership, signatures, deadlines, nonces, exact input totals and
outputs. LI.FI and UniswapX transfer the amounts from their route arrays before
calling direct adapters or the generic calls. The caller chooses each recipe and
its complete calldata; RFQ does not decode recipes, derive funding, or inspect
account metadata. RecipeExecutor commitments, account permissions, connector
checks and final settlement remain enforced by their contracts. A failed call
or output shortfall reverts the entire fill.

The original native RFQ fill ABI and callback `Call[]` encoding remain unchanged.
LI.FI and UniswapX callback data is `(FillCall, Call[])`, with an empty array for
fills needing no additional calls. Proxy storage layouts are unchanged.
The recipe interfaces and pinned upstream bytecode under `test/` are test fixtures;
production contracts have no dependency on the recipe interpreter schema.

## Test Locally

Use Foundry `v1.8.5`, Node.js from [.nvmrc](.nvmrc), pnpm `12.10.1`, Python `3.14.8`, and pre-commit `4.6.2`. Run commands from the repository root:

```bash
forge build
forge test --isolate
forge fmt --check
pre-commit run --all-files
```

Recipe tests cover all three executors, mixed LiquidLane/recipe routes, multiple bound accounts, caller and callback authorization, caller-selected funding recipients, absent or reverting recipe/account metadata, version-1 adapters and version-2 connectors, exact recipe calldata, commitment rejection, output shortfall, native outputs, and atomic rollback. They also deploy pinned upstream RecipeExecutor bytecode and forward managed-action runtime data with Merkle proofs. See [fixture provenance and reproduction](test/fixtures/SOURCE.md) for the real-contract and mock boundaries. The optional mainnet and Sepolia fork suites require `ETH_RPC_URL` and `ETH_RPC_URL_SEPOLIA`, respectively.

## Files to know

- `src/Reactor.sol`
- `src/Executor.sol`
- `src/interfaces`
- `test/Reactor.t.sol`

## Notes

- `Executor` is caller-gated through an owner-managed caller list.
- `Reactor` uses swapper ERC20 allowances, Reactor-managed request nonces, request deadlines, and factory-registered LiquidLane adapters/connectors as its execution primitives.
