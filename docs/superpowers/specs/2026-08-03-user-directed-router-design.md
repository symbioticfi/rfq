# User-Directed Router Design

**Date:** 2026-08-03
**Status:** Implemented with the signed-only signer-authorization security amendment

## Summary

Add a standalone, non-upgradeable Solidity contract named `Router`. A swapper calls the Router directly after granting it an ordinary ERC-20 allowance. In one atomic transaction, the Router first verifies a Router-specific EIP-712 authorization from a current adapter owner, market maker, or filler for every leg; transfers each input leg directly from the swapper to a factory-registered LiquidLane adapter; invokes an authorized adapter swap selector with opaque calldata; verifies the output tokens received during this transaction; pays exact declared amounts to the declared recipients; and returns each declared token's surplus to the swapper.

The Router is not a Reactor executor, does not validate RFQ orders, does not use Permit2, and does not retain user funds or approvals. Its security boundary is deliberately narrow: registered adapters, current adapter-authorized signers, per-leg EIP-712 authorization, one permitted signed-swap selector, standard ERC-20 behavior, transaction-local balance deltas, and all-or-nothing execution.

## Branch and ABI Compatibility

The design is being documented on `codex/router`, which currently points at the old `origin/stage` commit `8687e48`. That tree contains the legacy single-adapter `IInstantRedemptionAdapter` interface and does not contain the current `IRegistry` interface. The implementation must nevertheless target the current mainline LiquidLane model:

- The Router stores an immutable LiquidLane adapter factory.
- Every per-leg adapter is validated with `IRegistry(factory).isEntity(adapter)`.
- The stage branch receives a minimal read-only `IRegistry` interface containing only `isEntity(address) external view returns (bool)`.
- The selector constant is pinned to the current LiquidLane signed-swap ABI and covered by selector-shape tests. It must not be inferred from the stale stage `IInstantRedemptionAdapter` overloads.
- The legacy direct-swap selector and arbitrary adapter selectors are not accepted.

This makes the Router source buildable from the old stage tree while preserving the current mainline deployment trust boundary. It does not make the Router compatible with a legacy deployment that has no factory registry or exposes different swap selectors.

## Goals

- Give a user one typed entrypoint for a batch of LiquidLane swap legs with a single input token.
- Pull each leg directly from `msg.sender` into its adapter; the Router never takes custody of input tokens.
- Allow backend- or solver-produced signed-swap adapter calldata without making the Router an arbitrary-call primitive.
- Require all expected adapter outputs to arrive at the Router.
- Enforce minimum output economically at the aggregate token level across the whole batch.
- Pay exact amounts to one or more recipients and return declared-token surplus to `msg.sender`.
- Make pre-existing Router balances unusable by the current or any later caller.
- Revert the entire batch on any validation, transfer, adapter, accounting, or payout failure.

## Non-Goals

- Reactor order execution or implementation of `IExecutor`.
- Permit2, EIP-2612 permits, relayed execution, or meta-transactions.
- Multiple input tokens in one batch.
- An output token equal to the common input token.
- Native input, native output, wrapping, or unwrapping.
- Direct, unsigned LiquidLane swaps.
- Arbitrary targets, arbitrary selectors, `delegatecall`, or calls carrying native value.
- Partial fills, partial success, or an "allow revert" flag.
- Per-leg output guarantees. V1 guarantees only the aggregate outputs declared for the batch.
- Support for fee-on-transfer, rebasing, ERC-777-style callback, or otherwise non-standard tokens.
- Upgradeability, governance, pausing, mutable adapter allowlists, rescue, or sweeping.

## Public API

The Router exposes two nonpayable overloads. Both are protected by the same reentrancy guard and execute the same internal flow.

| Function | Semantics |
| --- | --- |
| `execute(address tokenIn, SwapCall[] swapCalls, Output[] outputs)` | Executes immediately with no Router-level expiry. Adapter-level signatures and deadlines still apply. |
| `execute(address tokenIn, SwapCall[] swapCalls, Output[] outputs, uint256 deadline)` | Executes only while `block.timestamp <= deadline`. Equality is valid; `block.timestamp > deadline` reverts before any token interaction. |

Both functions return no value. Successful settlement is observable through token transfers and Router events. The caller is always the input payer, the surplus recipient, and the address reported as the swapper in events.

The Router exposes `LIQUID_LANE_ADAPTER_FACTORY()` as a public immutable getter.

## Data Structures

The ABI field order is fixed as follows:

```solidity
struct SwapCall {
    address adapter;
    uint256 amountIn;
    bytes data;
    address authSigner;
    uint256 authDeadline;
    bytes authSignature;
}

struct Output {
    address token;
    address recipient;
    uint256 amount;
}
```

### `SwapCall`

| Field | Type | Meaning |
| --- | --- | --- |
| `adapter` | `address` | Factory-registered LiquidLane adapter that receives this leg's input and is called. |
| `amountIn` | `uint256` | Exact amount of the common `tokenIn` transferred directly from `msg.sender` to `adapter` for this leg. Must be nonzero. |
| `data` | `bytes` | Complete adapter calldata, including one permitted selector and all encoded quote data and signatures. |
| `authSigner` | `address` | Current adapter owner, market maker, or authorized filler that signs the Router authorization. |
| `authDeadline` | `uint256` | Nonzero, unexpired Router-authorization deadline. |
| `authSignature` | `bytes` | EIP-712 signature over the payer, signer, input token, complete leg, execution deadline, and authorization deadline. |

The Router treats all calldata after the first four selector bytes as opaque. It forwards the bytes unchanged and ignores successful return data. `authSignature` is verified against EIP-712 domain `Router`, version `1`, the current chain ID, and this Router address. The exact primary type is `SwapAuthorization(address swapper,address authSigner,address tokenIn,address adapter,uint256 amountIn,bytes32 dataHash,uint256 executionDeadline,uint256 authorizationDeadline)`, where `dataHash = keccak256(data)`. `executionDeadline` is zero for the no-deadline overload and the exact top-level deadline otherwise.

### `Output`

| Field | Type | Meaning |
| --- | --- | --- |
| `token` | `address` | Standard ERC-20 output token. The zero address and common `tokenIn` are invalid. |
| `recipient` | `address` | Final recipient. Must be neither the zero address nor the Router. |
| `amount` | `uint256` | Exact amount transferred to this entry's recipient after aggregate minimum validation. Must be nonzero. |

Multiple entries may use the same token and may use the same recipient. For a token, the sum of all corresponding `Output.amount` values is both the batch's aggregate minimum for that token and the exact total allocated among declared recipients. Any transaction-local excess for that token goes to `msg.sender`.

At least one `SwapCall` and one `Output` are required. A batch with no economic input or no declared economic output is rejected.

## Adapter Trust and Call Validation

For every `SwapCall`, the Router performs all validation and verifies every leg authorization before funding any leg or making an executable adapter call:

1. `adapter` is nonzero and `IRegistry(LIQUID_LANE_ADAPTER_FACTORY).isEntity(adapter)` returns true.
2. `amountIn` is nonzero.
3. `data` contains at least four bytes.
4. The first four bytes are exactly the permitted current-main signed-swap selector: `swap((address,address,uint256,uint256,address,address,uint256,uint48),bytes)`.
5. `authDeadline` is nonzero and `block.timestamp <= authDeadline`.
6. `authSigner` is currently the adapter's `owner()` or `marketMaker()`, or `isFiller(marketMaker(), authSigner)` is true.
7. OpenZeppelin `SignatureChecker` accepts `authSignature` for the exact Router EIP-712 payload, supporting EOAs and ERC-1271 signers.
8. No native value is attached to the adapter call.

All other selectors are rejected, including the discount-swap and unsigned direct-swap overloads. The discount signature does not bind its caller, recipient, or input amount and its nonce is reusable, so exposing that calldata would create a transferable bearer authorization outside the Router boundary. A private discount may inform solver pricing, but a selected leg must be rebuilt as a fresh signed swap. The allowlist prevents a user from exercising adapter administration, nonce invalidation, acquisition, withdrawal, or fallback behavior under the Router's identity.

The backend or solver must encode the Router as both the signed `caller` and collateral recipient. The adapter authoritatively verifies those fields and the signature. The Router does not decode or rewrite them.

Because the payload remains opaque, a single leg is not required to produce its own pro-rata share of an output. One leg may overproduce while another underproduces, provided the user-approved batch meets every aggregate token minimum. This cross-leg netting is intentional in V1.

## Execution Flow

### 1. Validate the request

Before transferring any token, the Router:

- applies the deadline check for the deadline overload;
- rejects zero or non-contract `tokenIn`;
- rejects empty `swapCalls` or `outputs`;
- validates every output token, amount, and recipient;
- validates every adapter, amount, calldata length, and selector;
- computes the sum of all leg inputs with checked arithmetic before adapter execution;
- validates every current adapter signer and Router authorization before funding the first leg; and
- groups duplicate output tokens and sums their required amounts with checked arithmetic.

Pre-validating the complete request avoids entering external execution with a structurally invalid later leg.

### 2. Snapshot declared output balances

For every unique token appearing in `outputs`, the Router records its own ERC-20 balance before any input transfer or adapter call. These baselines define funds that predate the transaction and are never spendable by this execution.

The caller must declare every output token expected from the adapters. A token delivered to the Router but absent from `outputs` is not observable through the V1 accounting set and remains permanently isolated in the Router. There is intentionally no rescue function that could turn such a mistake into a cross-user withdrawal primitive.

### 3. Fund and execute each leg

For each `SwapCall`, in array order, the Router:

1. Records `tokenIn.balanceOf(adapter)` as the leg's adapter baseline.
2. Uses safe `transferFrom` to transfer exactly `amountIn` from `msg.sender` directly to the adapter.
3. Requires the adapter balance to equal `baseline + amountIn`. Any smaller or otherwise unexpected increase is rejected as unsupported token behavior.
4. Calls `adapter` with the opaque `data`, zero native value, and ordinary EVM `call`. `delegatecall` is never used.
5. If the call fails, reverts the whole batch with the leg index, adapter, and returned revert bytes.
6. Requires the adapter's `tokenIn` balance to equal its pre-transfer baseline after the call.

The two balance equalities prove, for standard ERC-20 tokens, that this leg received and consumed exactly the top-level `amountIn` even though the Router does not decode the payload's token or amount fields. A payload naming another input token, consuming too little, or consuming from a pre-existing adapter balance fails this invariant. Because funding and calling occur in the same transaction and every failure reverts, no successful execution leaves a Router-funded prefund at an adapter.

### 4. Verify aggregate outputs

After all calls complete, the Router reads its final balance for every unique declared output token.

- A final balance below the snapshot is a balance-isolation violation and reverts.
- `produced = finalBalance - snapshotBalance` is the only amount attributable to this transaction.
- `produced` must be at least the sum of declared output amounts for that token.
- Pre-existing balances never contribute to `produced` and therefore cannot satisfy a minimum.

Adapter return values are not used for settlement. Router balance deltas are authoritative.

### 5. Pay exact outputs

The Router processes `outputs` in caller-supplied order. For each entry it:

1. Records the recipient's token balance.
2. Safely transfers exactly `Output.amount` from the Router to the recipient.
3. Requires the recipient's balance to have increased by exactly `Output.amount`.

This recipient-delta assertion gives `amount` received semantics, not merely `amount` sent semantics, and causes common fee-on-transfer outputs to revert atomically.

### 6. Return surplus and restore baselines

For each unique output token, the Router computes `surplus = produced - required` after reserving all exact recipient payments. If nonzero, it transfers the surplus to `msg.sender` and requires the swapper's balance to increase by exactly the surplus.

Finally, the Router requires its balance of every declared output token to equal the original snapshot. This final assertion catches sender-side transfer fees and proves that the current transaction neither consumed old funds nor retained newly produced declared outputs.

Only after all final assertions pass does the Router emit its completion event. Any failure at any point reverts the input transfers, adapter effects, output transfers, and events.

## Core Invariants

1. **Registered targets only:** every external call target is a current entity of the immutable LiquidLane adapter factory.
2. **Current signer authority:** every leg is approved by its adapter's current owner, market maker, or authorized filler.
3. **Exact Router authorization:** each signature binds the Router domain and chain, caller, `authSigner`, top-level input token, adapter, amount, calldata hash, effective execution deadline, and nonzero authorization deadline.
4. **Signed selector only:** the Router can invoke only the current signed-swap entrypoint.
5. **No arbitrary execution:** the Router never calls a user-selected non-adapter target, never uses `delegatecall`, and never forwards native value.
6. **Caller-funded:** every leg pulls from `msg.sender`; no arbitrary payer field exists.
7. **Direct input routing:** input moves from the swapper directly to the adapter and never through the Router.
8. **Exact input per leg:** the adapter balance increases by exactly `amountIn` on funding and returns to the same baseline after execution.
9. **Router-directed outputs:** successful batches rely on the backend encoding the Router as adapter recipient; declared aggregate deltas must arrive at the Router.
10. **Aggregate minimums:** for each declared output token, transaction-local production is at least the sum of its output entries.
11. **Exact recipient receipts:** each recipient's balance increases by its declared amount.
12. **Surplus belongs to the swapper:** all transaction-local declared-token production beyond required outputs is transferred to `msg.sender`.
13. **Pre-existing balance isolation:** a call can neither spend nor withdraw balances present before that call.
14. **No successful custody:** after success, each declared token balance equals its pre-call snapshot.
15. **Atomicity:** no partial batch, partial output, stranded leg prefund, or allow-failure mode exists.
16. **Reentrancy exclusion:** neither token, adapter, nor recipient callbacks can enter either `execute` overload during execution.

## Reentrancy and External-Call Model

Both overloads share one OpenZeppelin `ReentrancyGuard` boundary. The stage compiler remains Solidity 0.8.28, so the Router deliberately does not use transient-storage reentrancy protection. All validation and snapshots happen inside that boundary.

External interactions are limited to:

- factory `isEntity` static calls;
- adapter `owner`, `marketMaker`, and `isFiller` static calls;
- optional ERC-1271 signature checks through OpenZeppelin `SignatureChecker`;
- ERC-20 `balanceOf`, `transferFrom`, and `transfer` calls; and
- zero-value calls to registered adapters with an allowed selector.

There is no callback entrypoint, `receive`, payable function, approval, or arbitrary target call. A malicious recipient or callback-capable token may force a revert but cannot execute a second Router batch or consume another caller's snapshot.

## Errors

The interface defines concise custom errors for these observable failure classes:

| Error | Condition |
| --- | --- |
| `AdapterCallFailed(index, adapter, reason)` | An allowed adapter call reverted. |
| `BalanceIsolationViolation(token, baseline, actual)` | A declared Router token balance fell below its snapshot or failed to return to it. |
| `EmptyOutputs()` | No output was declared. |
| `EmptySwapCalls()` | No swap leg was supplied. |
| `Expired(deadline)` | The deadline overload was called after its deadline. |
| `InputConsumptionMismatch(index, expectedBaseline, actual)` | A leg did not consume exactly the transferred input increment. |
| `InputTransferMismatch(index, expected, actual)` | Direct funding did not increase the adapter balance by exactly `amountIn`. |
| `InsufficientOutput(token, required, produced)` | Aggregate transaction-local production is below the declared total. |
| `InvalidAdapter(index, adapter)` | The target is zero or is not a factory entity. |
| `InvalidAmount(index)` | A swap or output amount is zero. |
| `InvalidAuthorizationDeadline(index, deadline)` | A Router authorization has a zero or expired deadline. |
| `InvalidAuthorizationSignature(index, signer)` | The Router EIP-712 signature is invalid for the declared signer. |
| `InvalidCalldata(index)` | Adapter calldata is shorter than one selector. |
| `InvalidOutputToken(index, token)` | An output is native, zero, equal to `tokenIn`, or not an ERC-20 contract. |
| `InvalidRecipient(index, recipient)` | A recipient is zero or the Router. |
| `InvalidSelector(index, selector)` | The adapter selector is not the permitted signed-swap selector. |
| `InvalidTokenIn(token)` | `tokenIn` is zero or not a contract. |
| `OutputTransferMismatch(index, expected, actual)` | A declared recipient did not receive exactly the requested amount. |
| `SurplusTransferMismatch(token, expected, actual)` | The swapper did not receive the exact surplus. |
| `UnauthorizedAuthSigner(index, adapter, signer)` | The signer is not the adapter's current owner, market maker, or filler. |

The reentrancy guard's standard custom error remains part of the observable surface. Arithmetic overflow uses Solidity's checked-arithmetic panic and is not remapped.

## Events

The Router emits:

- `OutputTransferred(token, recipient, amount)` after each exact recipient transfer;
- `SurplusTransferred(token, swapper, amount)` for each nonzero surplus; and
- `Execute(swapper, tokenIn, totalAmountIn, swapCallCount, outputCount)` once, after all transfers and final baseline assertions succeed.

`swapper`, `tokenIn`, output `token`, and output `recipient` are indexed where Solidity's event topic limit permits. Failed batches emit no durable events.

## Unsupported Token and Native Behavior

V1 supports ordinary ERC-20 tokens whose balances change exactly by the requested transfer amount.

- **Fee-on-transfer input:** rejected by the adapter funding delta check.
- **Fee-on-transfer output:** rejected by the recipient or surplus balance-delta check, or by the final Router baseline assertion.
- **Sender-side transfer fee:** rejected by the final Router baseline assertion.
- **Rebasing token:** unsupported. A rebase during external execution can invalidate snapshot arithmetic or make a delta appear to be swap production. Deployment and integration configuration must exclude rebasing assets even if a particular call happens to pass the checks.
- **Callback-capable token:** unsupported. The guard prevents reentrant settlement, but such a token may revert the batch or have balance semantics outside the V1 model.
- **Native currency:** both overloads are nonpayable, `address(0)` is rejected as an output token, there is no `receive` or payable fallback, and adapter calls always use zero value. ETH forced onto the contract is permanently inaccessible and never participates in accounting.

## Security Assumptions and Explicit Trade-offs

- The immutable factory correctly identifies authentic LiquidLane adapters. Factory compromise or registration of malicious adapters is outside the Router's local trust boundary.
- The current LiquidLane signed-swap selector retains its documented semantics.
- The backend or solver encodes both `recipient = Router` and `caller = Router`. Incorrect encoding is rejected by the adapter or aggregate output validation.
- The transaction caller authorizes the aggregate settlement by submitting the transaction, while every individual adapter leg also requires a current adapter-authorized Router EIP-712 signature.
- The Router has no authorization-ID or replay-storage mapping. The permitted LiquidLane signed-swap selector consumes its adapter nonce, which remains authoritative for replay protection without unbounded Router storage.
- Output protection is aggregate per token, not per leg. Cross-leg subsidy is accepted because the user receives the declared batch result.
- Only tokens listed in `outputs` are snapshotted and distributed. Undeclared tokens sent to the Router remain isolated permanently; a later user cannot claim them as transaction-local surplus.
- There is no rescue function. Recoverability of accidental or forced balances is intentionally sacrificed to keep the pre-existing-balance invariant unconditional and ownerless.

## Test Plan

Create focused Foundry tests in `test/Router.t.sol` with registry, adapter, token, callback, and recipient mocks. Tests must cover both overloads and all branches.

### Construction and API

- Constructor rejects a zero or non-contract factory.
- The immutable getter returns the configured factory.
- The no-deadline overload succeeds under the same economic conditions as the deadline overload.
- Deadline equality succeeds; one second after the deadline reverts before any transfer.
- Both overloads reject attached native value at the ABI boundary.

### Structural validation

- Zero/non-contract `tokenIn`, empty calls, and empty outputs revert.
- Zero amounts, zero recipients, Router recipients, native output, and non-contract output tokens revert.
- Duplicate output tokens and recipients are accepted and aggregated correctly.
- An unregistered or zero adapter reverts.
- Calldata shorter than four bytes reverts.
- The signed-swap selector succeeds.
- Discount swap, direct swap, adapter administration, arbitrary, fallback, and legacy stage selectors revert.
- Selector constants are pinned against the current LiquidLane interface shape.

### Input routing

- Each leg transfers directly from the caller to its selected adapter; the Router input balance remains unchanged.
- Multiple adapters and repeated calls to one adapter work in array order.
- Missing allowance and insufficient caller balance bubble/revert atomically.
- Fee-on-transfer input fails the exact adapter funding delta.
- A call that consumes less, more, or a different input token fails the post-call adapter baseline check.
- A failure on a later leg rolls back earlier adapter calls and transfers.
- Adapter revert data is reported with the correct index and target.

### Router authorization

- The exact `Router`/`1` EIP-712 domain and primary type hash are pinned.
- Owner, market-maker, filler, EOA, and ERC-1271 authorizations succeed.
- A zero or expired authorization deadline fails before funding; deadline equality succeeds.
- Copying a signed call to another payer or modifying the token, adapter calldata, amount, execution deadline, authorization deadline, signer, or signature fails before funding.
- Revoking owner, market-maker, or filler authority before execution makes the signer unauthorized.
- A malformed later authorization is rejected before the first adapter executes.
- Input-total overflow is rejected before any adapter execution.

### Output accounting

- One token/one recipient settles exactly.
- One token split across several recipients uses the aggregate minimum and exact per-recipient amounts.
- Several output tokens settle independently.
- Output token equal to `tokenIn` is rejected before any transfer.
- Aggregate underproduction reverts the entire batch.
- Exact production leaves no surplus event.
- Overproduction pays exact outputs and returns the precise surplus to the caller.
- A fee-on-transfer output or surplus transfer reverts on recipient delta mismatch.
- Sender-side fee behavior reverts on final baseline mismatch.
- Tokens not declared as outputs are not paid or made claimable by a later call.

### Pre-existing balance isolation

- A pre-existing Router balance cannot satisfy an output minimum.
- Exact outputs and surplus leave the pre-existing balance unchanged.
- A later caller cannot sweep a prior caller's or forced token balance.
- A malicious registered adapter cannot reduce a declared pre-existing output balance without causing a revert.
- Forced ETH has no effect on ERC-20 accounting and cannot be withdrawn through Router.

### Reentrancy and atomicity

- A recipient callback attempting either overload reverts with the guard and rolls back the batch.
- A callback-capable input or output token cannot enter Router settlement.
- A registered malicious adapter cannot reenter Router.
- A payout failure after all adapter calls rolls back input transfers and adapter state.
- No event survives any reverted execution.

### Integration and deployment

- Add a mainline LiquidLane interface-shape test for the allowed signed-swap selector and the rejected discount-swap selector.
- Add an integration test with a factory mock exposing only `isEntity` to prove old-stage compatibility of the minimal interface.
- Add a deployment-script test confirming constructor validation and the immutable factory.
- Include Router in bytecode-size and gas snapshots according to repository conventions.

## Deployment Design

Deploy Router directly with one constructor argument: the chain's LiquidLane adapter factory. The contract has no proxy, initializer, owner, roles, storage configuration, or upgrade path. A new factory requires a new Router deployment.

Add:

- `src/Router.sol`;
- `src/interfaces/IRouter.sol`;
- `src/interfaces/ILiquidLaneAdapterAuthorization.sol`;
- the minimal `src/interfaces/IRegistry.sol` when implementing from the old stage base;
- `test/Router.t.sol`;
- `script/deploy/DeployRouter.s.sol`; and
- a deployment-script test under `test/deploy/` where that layout is present after synchronization with current main.

The deployment script reads `LIQUID_LANE_ADAPTER_FACTORY`, deploys Router, asserts the immutable matches, and logs the Router and factory addresses. Production deployment must use the per-chain factory already used by current Reactor configuration.

After deployment, backend and solver configuration must use the deployed Router address as:

- `SignedSwap.caller`;
- `SignedSwap.recipient`.

Every solver-produced leg also needs the current adapter-authorized Router signature described above. Users approve the input ERC-20 to Router and submit the Router transaction themselves.

## Acceptance Criteria

The feature is complete when:

1. Both typed overloads implement the same atomic execution path and the deadline overload expires exactly as specified.
2. Every leg targets a factory entity, uses exactly the pinned signed-swap selector, and has a valid unexpired authorization from its adapter's current owner, market maker, or filler.
3. The authorization binds the caller, signer, input token, adapter, amount, calldata hash, effective execution deadline, and authorization deadline before any leg is funded.
4. Every input leg is transferred directly from the caller, received exactly, and consumed exactly.
5. No declared output minimum can be satisfied by a pre-existing Router balance.
6. Every declared recipient receives exactly its amount, every declared-token surplus goes to the caller, and the Router returns to each declared token's starting balance.
7. Native currency and unsupported token behavior cannot silently participate in a successful batch.
8. Reentrancy, later-leg failure, adapter failure, and payout failure roll back the entire transaction.
9. The contract is ownerless, non-upgradeable, nonpayable, and has no rescue or arbitrary-call surface.
10. Unit, selector-shape, integration, deployment, formatting, size, and gas-snapshot checks pass under the repository's Foundry workflow.
