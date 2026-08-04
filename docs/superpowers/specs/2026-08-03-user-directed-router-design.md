# Inline-Execution Router Design

**Date:** 2026-08-03
**Status:** Implemented

## Summary

`Router` is a small, ownerless execution surface for user-directed RFQ swaps. The caller grants the Router an ordinary ERC-20 allowance and submits one or more solver-produced adapter legs. For every leg, the Router verifies that the target is registered by the immutable LiquidLane adapter factory, transfers that leg's input directly from the caller to the adapter, and invokes the supplied calldata inline. Once every call succeeds, it transfers each declared output from its own balance to the declared recipient.

Multiple legs let the backend aggregate liquidity across chosen solvers. A caller selecting one solver supplies one leg; an aggregated quote supplies the selected legs and aggregate output instructions.

## Public API

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

function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external;

function execute(
    address tokenIn,
    SwapCall[] calldata calls,
    Output[] calldata outputs,
    uint256 deadline
) external;
```

Both overloads are nonpayable and protected by one reentrancy guard. The deadline overload permits execution while `block.timestamp <= deadline` and reverts when `block.timestamp > deadline`.

## Execution

For each `SwapCall`, in caller-supplied order:

1. Require `IRegistry(LIQUID_LANE_ADAPTER_FACTORY).isEntity(adapter)`.
2. Call `tokenIn.safeTransferFrom(msg.sender, adapter, amountIn)`.
3. Call `adapter.call(data)` with zero native value.
4. If the adapter call fails, revert with `AdapterCallFailed(index, adapter, reason)`.

After every adapter call succeeds, process each `Output` in caller-supplied order with `IERC20(token).safeTransfer(recipient, amount)`.

Any revert rolls back the complete batch, including earlier transfers and adapter effects.

## Deliberately Minimal Validation

The Router validates only:

- the factory is a nonzero contract at construction;
- each adapter is currently registered; and
- the optional deadline has not expired.

It does not validate nonempty arrays, nonzero amounts, token or recipient addresses, adapter code, calldata length or selector, signatures, nonces, input consumption, output production, balance deltas, conservation, or surplus. Those checks remain with ERC-20 contracts, registered adapters, backend quote construction, and the caller's transaction review.

Adapter calldata is opaque and forwarded unchanged. Signed-swap and discounted-swap payloads are both supported when their registered adapter accepts them. The Router has no EIP-712 domain, signature checker, replay state, selector allowlist, or adapter-specific interface.

Output entries are ordinary transfers from the Router's current balances. Pre-existing balances may therefore satisfy an output, underproduction fails only if the token transfer fails, and undeclared surplus remains in the Router.

## Trust Boundary and Invariants

1. Only entities registered by the immutable factory can be called.
2. Input is transferred directly from `msg.sender` to each adapter; it does not pass through the Router.
3. Calls and output transfers preserve caller-supplied ordering.
4. No native value or `delegatecall` is used.
5. The complete execution is atomic.
6. Reentrant entry into either overload is rejected.

Registered adapters are trusted to authenticate and consume their calldata correctly. Backend responses must bind each leg to the intended adapter and transaction semantics. Users must review `tokenIn`, all input amounts, adapter targets, calldata, outputs, and the optional deadline before signing.

## Errors

| Error | Meaning |
| --- | --- |
| `InvalidFactory(factory)` | The constructor received zero or an address without code. |
| `Expired(deadline)` | The deadline overload was called after its deadline. |
| `InvalidAdapter(index, adapter)` | The indexed call target is not currently registered. |
| `AdapterCallFailed(index, adapter, reason)` | The indexed adapter reverted; `reason` preserves its revert data. |

ERC-20 failures use OpenZeppelin `SafeERC20` behavior and are not wrapped in Router-specific errors.

## Deployment

The deployment script reads `LIQUID_LANE_ADAPTER_FACTORY` and deploys `Router` directly. There is no proxy, owner, role, pause, mutable allowlist, rescue, or upgrade mechanism.
