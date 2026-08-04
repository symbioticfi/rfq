# Inline-Execution Router Implementation Plan

**Goal:** Implement the smallest ownerless Router that directly funds registered LiquidLane adapters, invokes solver-provided calldata inline, and transfers declared outputs atomically.

**Tech stack:** Solidity 0.8.28, Foundry, OpenZeppelin `SafeERC20` and `ReentrancyGuard`.

## Constraints

- Contract name is exactly `Router`.
- `SwapCall` is exactly `(address adapter, uint256 amountIn, bytes data)`.
- `Output` is exactly `(address token, address recipient, uint256 amount)`.
- Input authorization is an ordinary ERC-20 allowance to the Router.
- Validate each adapter through immutable `IRegistry(factory).isEntity(adapter)` immediately before funding that leg.
- Transfer input directly from `msg.sender` to the adapter, then call the supplied calldata unchanged.
- Transfer outputs only after every adapter call succeeds.
- Keep both immediate and deadline overloads under one reentrancy guard.
- Do not add outer signatures, selector inspection, balance accounting, surplus handling, or structural request validation.

## Completed Work

- [x] Replace the authenticated six-field call tuple with the three-field ABI and pin its raw function selector in tests.
- [x] Preserve zero/non-contract factory rejection and the immutable factory getter.
- [x] Implement inline per-leg registry checks, direct `safeTransferFrom`, and opaque adapter `call`.
- [x] Preserve adapter revert bytes in `AdapterCallFailed`.
- [x] Implement ordered `safeTransfer` output distribution.
- [x] Keep atomic rollback, shared reentrancy protection, and optional deadline semantics.
- [x] Remove EIP-712, `SignatureChecker`, adapter authorization interfaces, selector parsing, amount sums, input/output delta checks, isolation, surplus, and related errors/events.
- [x] Cover aggregated legs, arbitrary calldata, empty/zero entries, direct funding, output ordering, pre-existing balances, retained surplus, invalid adapters, adapter/output failures, rollback, reentrancy, deployment, deadlines, and fuzzed leg amounts.
- [x] Update Router documentation and deployment wording.

## Verification

Run from the full Foundry workspace:

```bash
forge fmt --check
FOUNDRY_PROFILE=pr forge test --match-path test/Router.t.sol
forge lint
forge build --sizes
forge coverage --match-path test/Router.t.sol
```
