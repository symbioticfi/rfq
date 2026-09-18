![Symbiotic RFQ](../frontend/public/lockup.png)

# Reactor Contracts

This directory contains the core RFQ settlement contracts used by the Symbiotic instant redemption flow. The pair is intentionally small:

- `Reactor.sol` validates the signed order, pulls approved input from the swapper directly into factory-registered LiquidLane adapters, and enforces output delivery.
- `ReactorV2.sol` uses Permit2 witness signatures to transfer the entire input into one registered LiquidLane adapter or connector, then invokes the filler and settles the protocol-authorized outputs.
- `Executor.sol` is an example role-gated execution surface that calls the Reactor, performs adapter swaps, runs any post-swap execution payload, and approves output transfers back to the Reactor.
- `LiquidLaneUniswapXExecutor.sol` is a transparent-proxy, caller-gated UniswapX fill contract. It routes Reactor-supplied ERC-20 input through direct and discount LiquidLane adapters, grants the immutable Reactor output allowances, and forwards native output. The Reactor authoritatively resolves and settles orders; adapters enforce swap and discount terms. Direct and discount route arrays remain separate, and unspent input or output surplus remains on the executor. Because the Reactor has maximum ERC-20 allowances, retained balances can participate in subsequent Reactor settlement; there is no sweep entrypoint.

> [!NOTE]
>
> `Executor.sol` is not a protocol requirement. It is an example filler-side executor contract that demonstrates one way to integrate with `Reactor`. Fillers can deploy their own executor implementation as long as it satisfies the expected Reactor callback flow.

## Contracts

- [Reactor.sol](src/Reactor.sol)
- [ReactorV2.sol](src/ReactorV2.sol)
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

## ReactorV2

V2 is a separate deployment with a new filler callback and signing flow. V1 and its executor remain unchanged.

1. The swapper approves the input token to **Permit2** and signs a `PermitWitnessTransferFrom` whose witness is the full `Request`. The permitted token/amount, nonce and deadline are taken from the request; the spender is the deployed **ReactorV2** address.
2. The protocol signs `Order` under the EIP-712 domain **name `Reactor`, version `2`**, the current chain ID, and the ReactorV2 address. The order binds the swapper, Permit2 signature, filler, single input destination (`adapter`), and final outputs.
3. The filler calls `fill(order, protocolSignature, executorData)`. The destination must satisfy `LL_ADAPTER_FACTORY.isEntity(adapter)` **or** `LL_CONNECTOR_FACTORY.isEntity(adapter)`. Exactly `request.amountIn` goes to that one address in one `permitWitnessTransferFrom` call.
4. ReactorV2 calls the filler's [`reactorCallback(order, executorData)`](src/interfaces/IReactorV2Callback.sol). The callback performs the appropriate direct swap, discount swap, or Merkle-authorized connector execution. A LiquidLaneConnector is called through its bound adapter; registering a connector does not grant the filler direct permission to call its `swap`.
5. ReactorV2 pulls ERC20 outputs from the filler and sends native outputs from its own balance. Each final output must retain its requested token and recipient and meet or exceed its requested amount. Any callback or output-payment failure reverts the entire fill, including the input transfer and Permit2 nonce consumption. Excess native currency is refunded to the filler, matching V1 settlement behavior.

The callback must authenticate ReactorV2 as its caller, approve its ERC20 output transfers, and send native output funding to it. The existing V1 `Executor` does not implement this callback. Transfers assume standard ERC20 balance accounting; fee-on-transfer tokens and rebases during settlement are unsupported.

### Signing and cancellation

[`IReactorV2.sol`](src/interfaces/IReactorV2.sol) defines the exact request/order schemas and `PERMIT2_WITNESS_TYPE_STRING`. For the swapper signature, use Permit2's domain (name `Permit2`, no version, current chain ID, Permit2 address), with primary type `PermitWitnessTransferFrom`:

```text
PermitWitnessTransferFrom(
  TokenPermissions permitted,
  address spender,
  uint256 nonce,
  uint256 deadline,
  Request witness
)
```

Supply the nested `TokenPermissions`, `Request`, and `Output` types to the typed-data encoder. The swapper authorizes its chosen protocol to select the registered destination and filler while preserving the signed minimum outputs. A standalone V1 request signature or plain Permit2 transfer signature cannot fill a V2 order.

Nonces belong to Permit2's global unordered bitmap for the swapper. To cancel, the **swapper calls Permit2 directly**:

```text
invalidateUnorderedNonces(nonce >> 8, 1 << (nonce & 255))
```

`ReactorV2.isUsedNonce(swapper, nonce)` reads that bitmap. There is no separate ReactorV2 nonce store or cancellation transaction. Nonces must be coordinated with other applications using Permit2 signature transfers.

The transfer/witness pattern follows [UniswapX's LimitOrderReactor](https://github.com/Uniswap/UniswapX/blob/main/src/reactors/LimitOrderReactor.sol). Permit2 is pinned to [`cc56ad0`](https://github.com/Uniswap/permit2/tree/cc56ad0f3439c502c246fc5cfcc3db92bb8b7219); tests execute its official precompiled Permit2 fixture and generate typed-data hashes independently with Foundry's EIP-712 encoder.

### Build and deploy

V2 pins Solidity **0.8.36**, while existing contracts retain **0.8.28**. Foundry detects both versions; the EVM target remains **Cancun**.
Use **Foundry v1.7.1**, matching the repository's CI pin and formatter.

```bash
git submodule update --init --recursive
forge fmt --check
forge test --isolate
forge build --sizes
```

Use explicit, verified dependency addresses for the deployment chain. Both factories and Permit2 must already be deployed. With an encrypted Foundry account:

```bash
forge script script/deploy/DeployReactorV2.s.sol:DeployReactorV2Script \
  --sig 'run(address,address,address)' \
  "$PERMIT2" "$LL_ADAPTER_FACTORY" "$LL_CONNECTOR_FACTORY" \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --sender "$SENDER" --broadcast
```

Omit `--broadcast` to simulate the deployment first.
