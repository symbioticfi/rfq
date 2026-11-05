![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow. The settlement surfaces are:

- `Reactor.sol` validates the signed order, pulls approved input from the swapper into factory-registered LiquidLane adapters/connectors, and enforces output delivery.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, runs a caller-supplied list of calls and approves output transfers back to the Reactor.
- `LiquidLaneLifiExecutor.sol` runs caller-supplied calls after receiving input, then fills and attests the LI.FI output mandate.
- `LiquidLaneUniswapXExecutor.sol` runs caller-supplied calls after receiving input and authorizes the Reactor to settle outputs.
- `SymbioticOevSolver.sol` liquidates Morpho positions using either its native Liquid Lane exit or signed calls, including Merkle recipes. Actual repayment and profit checks gate bid payment.

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
5. `Executor.execute(...)` runs the supplied calls in order, including adapter swaps, recipe execution and any post-swap calls.
6. `Reactor` enforces the requested outputs and emits the fill event used by the indexer.

## RecipeExecutor swaps

Each generic call contains `target`, `value` and ABI-encoded `data`. The executors run them in order without adapter-version checks or implicit swap dispatch.

- Native RFQ: the Reactor funds registered adapters/connectors from `swapInputs` and `discountSwapInputs`; the callback calls execute swaps and recipes.
- LI.FI and UniswapX: the input arrives at the executor. The call list must include transfers to each adapter/connector before its swap or recipe.
- Redstone: each signed liquidation leg may supply a `collateralRecipient` and `calls`. The callback transfers the actual seized collateral to that recipient, executes the calls, then checks actual loan proceeds against repayment and the profit floor. Leaving both empty selects the native Liquid Lane exit with live pricing and collateral clamping.

A recipe exit uses `RecipeExecutor → MerkleAccount → LiquidLaneConnector`. The recipe and underlying contracts enforce their own permissions and terms. The callback authorization binds every target, value, calldata byte and collateral recipient. A recipe must handle the live funded amount; a stale fixed amount can revert that leg.

Register the connector implementation as version `2` in the existing Liquid Lane
adapter factory, after the version `1` adapter implementation. Create connectors
with `create(2, owner, abi.encode(account, outputAsset))` and configure the Reactor
with that shared factory. Factory versions are independent of the connector's
EIP-712 domain version, which remains `1`.

```solidity
// Each call holds target, value and ABI-encoded adapter or RecipeExecutor calldata.
executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));
lifiExecutor.finaliseWithCurrentTimestamp(order, calls);
uniswapXExecutor.execute(signedOrder, calls);
```

Native RFQ exposes one `fill` entrypoint with both funding arrays; either can be
empty. It forwards the input arrays and opaque `executorData` unchanged. Reactor
checks factory membership, signatures, deadlines, nonces, exact input totals and
outputs. LI.FI and UniswapX transfer the amounts from their route arrays before
calling direct adapters or the generic calls. The caller chooses each recipe and
its complete calldata; RFQ does not decode recipes, derive funding, or inspect
account metadata. RecipeExecutor commitments, account permissions, connector
checks and final settlement remain enforced by their contracts. A failed call
or output shortfall reverts the entire fill.

Upgrade the callback contracts and solver encoders together. LI.FI and UniswapX now expose one entrypoint each; the route-based overloads are removed. Their proxy storage layouts are unchanged. LI.FI encodes `(FillCall, Call[])`, where `FillCall` contains only order ID, output and deadline. UniswapX encodes only `Call[]`. Redstone's signed leg tuple now includes the collateral recipient and call list.
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

Recipe tests cover all four executors, mixed LiquidLane/recipe routes, multiple bound accounts, caller and callback authorization, caller-selected funding recipients, absent or reverting recipe/account metadata, version-1 adapters and version-2 connectors, exact recipe calldata, commitment rejection, output shortfall, native outputs, and atomic rollback. They also deploy pinned upstream RecipeExecutor bytecode and forward managed-action runtime data with Merkle proofs. See [fixture provenance and reproduction](test/fixtures/SOURCE.md) for the real-contract and mock boundaries. The optional mainnet and Sepolia fork suites require `ETH_RPC_URL` and `ETH_RPC_URL_SEPOLIA`, respectively.

## Files to know

- `src/Reactor.sol`
- `src/Executor.sol`
- `src/interfaces`
- `test/Reactor.t.sol`

## Notes

- `Executor` is caller-gated through an owner-managed caller list.
- `Reactor` uses swapper ERC20 allowances, Reactor-managed request nonces, request deadlines, and factory-registered LiquidLane adapters/connectors as its execution primitives.
