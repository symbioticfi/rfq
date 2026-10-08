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

All three executors accept additional `IRecipeRoute.RecipeRoute[]` input legs. Each route contains a RecipeExecutor address, its account-bound LiquidLaneConnector, `amountIn`, and the exact `queries`, `steps`, `inputs`, and `runtime` arguments of `IRecipeExecutor.execute`. The route requires connector version **2** and the same nonzero account on both contracts. Input goes to the connector, never directly to the RecipeExecutor or its account.

LiquidLaneConnector must be whitelisted as version 2 and created through `LiquidLaneAdapterFactory`. Before filling, the RecipeExecutor owner sets its `caller` to the RFQ, LI.FI or UniswapX executor contract and commits the intended recipe with `setRecipe`. The bound account needs the recipe's permissions and current Merkle proofs. The recipe performs all version 2 adapter actions: approvals, connector direct or discount swaps, and any further conversion needed to return the settlement outputs to the calling executor. Connector swaps are account-only: they return funded RWA input to the account and pay output assets from that account. Each RecipeExecutor has one caller; separate integrations require separate RecipeExecutors or an owner-approved caller change.

The entrypoints are:

```solidity
// Native RFQ: existing direct inputs + existing discount inputs + recipe amounts
// must equal order.request.amountIn. postCalls run after recipes.
executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, recipeFill);
// recipeFill is IExecutor.RecipeFill({routes: recipeRoutes, postCalls: postCalls}).

// LI.FI: recipe inputs use the funds released after input settler fees.
lifiExecutor.finaliseWithCurrentTimestamp(order, routes, discountRoutes, recipeRoutes);

// UniswapX: recipe inputs use the funds supplied by the Reactor.
uniswapXExecutor.execute(signedOrder, fillCall, recipeRoutes);
```

**The native RFQ Reactor and its interface are unchanged.** The executor appends each recipe's connector and input amount to the existing `SwapInput[]`, then calls the existing Reactor entrypoint. Every connector remains subject to the Reactor's factory membership and input-token checks. Swapper and protocol signatures, deadlines, nonces, the exact input total, and required output transfers still apply. The executor skips its automatic direct/discount swap call for version 2 inputs; RecipeExecutor makes the account perform those actions. Version 1 swaps run as before, followed by recipes and optional RFQ post-calls. No new Reactor deployment is required for this integration.

LI.FI and UniswapX fund each additional recipe input into its connector before calling RecipeExecutor. Their existing direct and discount routes also fund the specified adapter and skip the automatic swap for version 2. If an existing input route already funds a connector, set that recipe route's `amountIn` to zero to avoid funding it twice. A recipe's transfer amount is routing information; the committed program and account permissions determine its actual actions, including any discount terms. Version 2 connector discount precision and signatures are defined by the connector, not by the legacy adapter's discount helpers.

A failed recipe or output shortfall reverts the entire fill. LI.FI's output settler and UniswapX's Reactor continue to enforce their respective output amounts and preserve the existing retained-balance behavior. Unspent input and surplus output stay on the executor and can participate in later settlement; the allowed caller remains responsible for route amounts.

Existing fill entrypoints and public LiquidLane route structs remain available. Native RFQ's existing opaque `Call[]` payload can also invoke `IRecipeExecutor.execute` directly after funding a registered version 2 connector through an existing input leg. LI.FI and UniswapX internally encode their callback data as `(FillCall, RecipeRoute[])`, including an empty recipe array for the existing entrypoints. Integrations that directly construct these opaque callback payloads must use this encoding. Proxy storage layouts are unchanged. Deploy/upgrade executor implementations separately from factory whitelisting and account/recipe configuration.

`IRecipeExecutor.sol` and its inherited recipe schema, `IRecipes.sol`, are copied from [symbioticfi/adapters at bd5e235](https://github.com/symbioticfi/adapters/tree/bd5e235899de5e175a0001a913d47596f6f4f801/src/interfaces/merkle-adapter). Only the local `IRecipes` import path is adjusted. No adapters implementation dependency is added to production contracts.

## Test Locally

Run commands from the repository root:

```bash
forge build
forge test --isolate
```

Recipe tests cover all three executors, mixed LiquidLane/recipe routes, multiple bound accounts, caller and commitment rejection, output shortfall, native outputs, and atomic rollback. They also deploy pinned upstream RecipeExecutor bytecode and forward managed-action runtime data with Merkle proofs. See [fixture provenance and reproduction](test/fixtures/SOURCE.md) for the real-contract and mock boundaries. The optional mainnet and Sepolia fork suites require `ETH_RPC_URL` and `ETH_RPC_URL_SEPOLIA`, respectively.

## Files to know

- `src/Reactor.sol`
- `src/Executor.sol`
- `src/interfaces`
- `test/Reactor.t.sol`

## Notes

- `Executor` is caller-gated through an owner-managed caller list.
- `Reactor` uses swapper ERC20 allowances, Reactor-managed request nonces, request deadlines, and factory-registered LiquidLane adapters/connectors as its execution primitives.
