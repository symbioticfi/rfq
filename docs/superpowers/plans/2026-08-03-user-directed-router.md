# User-Directed Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an ownerless `Router` that atomically funds registered LiquidLane adapters from the caller, executes signed-swap calldata, and distributes transaction-local ERC-20 output deltas.

**Architecture:** `IRouter` fixes the typed batch ABI, per-leg EIP-712 authorization, allowed selectors, errors, and events. `Router` validates the entire batch and every current adapter signer before funding, snapshots unique output-token balances, transfers each leg directly from `msg.sender` to its registered adapter, calls the adapter, verifies exact input consumption, enforces aggregate outputs, pays recipients, and returns surplus while preserving pre-existing balances.

**Tech Stack:** Solidity 0.8.28, Foundry, OpenZeppelin `SafeERC20`, `EIP712`, `SignatureChecker`, and `ReentrancyGuard`, forge-std.

## Global Constraints

- Contract name is exactly `Router` and it is deployed directly, without proxy, owner, roles, pause, rescue, or upgrade state.
- Input authorization is ordinary ERC-20 allowance to Router; do not add Permit2 or EIP-2612.
- ABI field order is `SwapCall(adapter, amountIn, data, authSigner, authDeadline, authSignature)` and `Output(token, recipient, amount)`.
- Every leg uses EIP-712 domain `Router` version `1` and the exact `SwapAuthorization(address swapper,address authSigner,address tokenIn,address adapter,uint256 amountIn,bytes32 dataHash,uint256 executionDeadline,uint256 authorizationDeadline)` primary type.
- Require a nonzero, unexpired `authDeadline`, current adapter owner/market-maker/filler authority, and a valid OpenZeppelin `SignatureChecker` result before funding any leg.
- Prevalidate the total input sum with checked arithmetic before adapter execution. Replay protection remains in the nonce consumed by the allowed signed-swap selector; do not add Router replay storage.
- Expose both nonpayable overloads: `execute(tokenIn,calls,outputs)` and `execute(tokenIn,calls,outputs,deadline)`.
- Allow only selector `0x9a4568b6` (signed swap). Reject `0x8fa5c671` (discount swap): a private discount may inform pricing, but the selected leg must be rebuilt as a fresh signed swap bound to the Router.
- Validate every adapter through immutable `IRegistry(factory).isEntity(adapter)`.
- Use `call`, never `delegatecall`, and forward zero native value.
- Transfer every leg directly from `msg.sender` to its adapter; Router must never custody input.
- Support standard ERC-20 only; reject native, same-token output, fee-on-transfer behavior, empty economics, and zero values.
- Settle only transaction-local output deltas; never sweep or spend a pre-existing Router balance.
- Every failure reverts the complete batch.
- Target branch is `origin/stage`; preserve existing Reactor/Executor behavior.

The authorization constraints above are the approved security amendment and supersede older task snippets below wherever they show the original three-field `SwapCall` or transient reentrancy guard.

---

### Task 1: Pin the Router interface and structural validation

**Files:**

- Create: `src/interfaces/IRegistry.sol`
- Create: `src/interfaces/IRouter.sol`
- Create: `src/Router.sol`
- Create: `test/Router.t.sol`

**Interfaces:**

- Produces `IRegistry.isEntity(address) external view returns (bool)`.
- Produces `IRouter.SwapCall`, `IRouter.Output`, the two `execute` overloads, custom errors, and events.
- Produces `Router.LIQUID_LANE_ADAPTER_FACTORY()` and pre-execution validation shared by both overloads.

- [ ] **Step 1: Write failing ABI and constructor tests**

Create `test/Router.t.sol` with minimal registry/token/adapter mocks and assertions that pin the field order, immutable, selector constants, empty arrays, deadline boundary, zero/non-contract factory, zero/non-contract input token, same-token output, invalid recipients, zero amounts, unregistered adapters, short calldata, and unapproved selectors. The core fixtures are:

```solidity
contract MockRegistry {
    mapping(address => bool) public isEntity;
    function setEntity(address entity, bool status) external { isEntity[entity] = status; }
}

contract RouterTest is Test {
    MockRegistry registry;
    Router router;

    function setUp() public {
        registry = new MockRegistry();
        router = new Router(address(registry));
    }

    function testDeadlineEqualityIsValid() public {
        vm.warp(100);
        vm.expectRevert(IRouter.EmptySwapCalls.selector);
        router.execute(address(registry), new IRouter.SwapCall[](0), new IRouter.Output[](0), 100);
    }

    function testExpiredDeadlineRevertsBeforeTokenInteraction() public {
        vm.warp(101);
        vm.expectRevert(abi.encodeWithSelector(IRouter.Expired.selector, 100));
        router.execute(address(registry), new IRouter.SwapCall[](0), new IRouter.Output[](0), 100);
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
forge test --match-path test/Router.t.sol -vvv
```

Expected: compilation fails because `Router`, `IRouter`, and `IRegistry` do not exist.

- [ ] **Step 3: Define the exact interfaces**

Create `IRegistry.sol` with only the read method. Create `IRouter.sol` with:

```solidity
interface IRouter {
    struct SwapCall {
        address adapter;
        uint256 amountIn;
        bytes data;
        address authSigner;
        uint256 authDeadline;
        bytes authSignature;
    }
    struct Output { address token; address recipient; uint256 amount; }

    error AdapterCallFailed(uint256 index, address adapter, bytes reason);
    error BalanceIsolationViolation(address token, uint256 baseline, uint256 actual);
    error EmptyOutputs();
    error EmptySwapCalls();
    error Expired(uint256 deadline);
    error InputConsumptionMismatch(uint256 index, uint256 expectedBaseline, uint256 actual);
    error InputTransferMismatch(uint256 index, uint256 expected, uint256 actual);
    error InsufficientOutput(address token, uint256 required, uint256 produced);
    error InvalidAdapter(uint256 index, address adapter);
    error InvalidAmount(uint256 index);
    error InvalidCalldata(uint256 index);
    error InvalidOutputToken(uint256 index, address token);
    error InvalidRecipient(uint256 index, address recipient);
    error InvalidSelector(uint256 index, bytes4 selector);
    error InvalidTokenIn(address token);
    error OutputTransferMismatch(uint256 index, uint256 expected, uint256 actual);
    error SurplusTransferMismatch(address token, uint256 expected, uint256 actual);

    event OutputTransferred(address indexed token, address indexed recipient, uint256 amount);
    event SurplusTransferred(address indexed token, address indexed swapper, uint256 amount);
    event Execute(address indexed swapper, address indexed tokenIn, uint256 totalAmountIn, uint256 swapCallCount, uint256 outputCount);

    function LIQUID_LANE_ADAPTER_FACTORY() external view returns (address);
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external;
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline) external;
}
```

- [ ] **Step 4: Implement constructor, overload routing, and full prevalidation**

Create `Router.sol` inheriting `IRouter, ReentrancyGuard`. Constructor-reject a zero/non-contract factory. Route both overloads into `_execute`; the deadline overload checks `block.timestamp > deadline`. In `_validate`, require contract `tokenIn`, nonempty arrays, nonzero output/call amounts, output token code, `output.token != tokenIn`, nonzero recipient not Router, registered adapter, at least four calldata bytes, and one allowed selector:

```solidity
bytes4 internal constant SIGNED_SWAP_SELECTOR = 0x9a4568b6;

function _selector(bytes calldata data) internal pure returns (bytes4 selector) {
    assembly ("memory-safe") { selector := calldataload(data.offset) }
}
```

Prevalidate every entry before any token transfer or adapter invocation.

- [ ] **Step 5: Run structural tests and verify GREEN**

Run:

```bash
forge test --match-path test/Router.t.sol -vvv
forge fmt --check
```

Expected: constructor, ABI, selector, deadline, and structural-validation tests pass.

- [ ] **Step 6: Commit the interface slice**

```bash
git add src/interfaces/IRegistry.sol src/interfaces/IRouter.sol src/Router.sol test/Router.t.sol
git commit -m "feat: add typed Router interface"
```

---

### Task 2: Fund registered adapters and enforce exact leg consumption

**Files:**

- Modify: `src/Router.sol`
- Modify: `test/Router.t.sol`

**Interfaces:**

- Consumes the validated `IRouter.SwapCall[]` from Task 1.
- Produces `_executeCalls(address tokenIn, SwapCall[] calldata calls) returns (uint256 totalAmountIn)`.
- Guarantees input moves caller-to-adapter directly and each adapter returns to its pre-leg input balance.

- [ ] **Step 1: Write failing direct-funding tests**

Extend the mocks with a registered adapter that accepts the signed selector, consumes its prefunded input, transfers output to the Router, optionally reverts, and records calldata. Keep a discount-selector mock path only for the explicit Router-rejection regression. Add tests for one leg, multiple adapters, call order, missing allowance, fee-on-transfer input, under-consumption, adapter revert data, and late-leg rollback:

```solidity
function testTransfersEachInputDirectlyAndCallsInOrder() public {
    IRouter.SwapCall[] memory calls = _twoCalls(4 ether, 6 ether);
    IRouter.Output[] memory outputs = _oneOutput(10 ether, swapper);

    vm.prank(swapper);
    router.execute(address(inputToken), calls, outputs, block.timestamp);

    assertEq(inputToken.balanceOf(address(router)), 0);
    assertEq(adapter0.consumed(), 4 ether);
    assertEq(adapter1.consumed(), 6 ether);
}
```

- [ ] **Step 2: Run input tests and verify RED**

Run:

```bash
forge test --match-path test/Router.t.sol --match-test 'testTransfers|testReverts.*Input|testLateLeg' -vvv
```

Expected: tests fail because calls are not funded or invoked.

- [ ] **Step 3: Implement exact funding and calls**

Use `SafeERC20` and balance deltas for every leg:

```solidity
uint256 baseline = IERC20(tokenIn).balanceOf(call.adapter);
IERC20(tokenIn).safeTransferFrom(msg.sender, call.adapter, call.amountIn);
uint256 funded = IERC20(tokenIn).balanceOf(call.adapter);
if (funded != baseline + call.amountIn) {
    revert InputTransferMismatch(i, baseline + call.amountIn, funded);
}
(bool success, bytes memory reason) = call.adapter.call(call.data);
if (!success) revert AdapterCallFailed(i, call.adapter, reason);
uint256 remaining = IERC20(tokenIn).balanceOf(call.adapter);
if (remaining != baseline) revert InputConsumptionMismatch(i, baseline, remaining);
totalAmountIn += call.amountIn;
```

Do not approve adapters, transfer input into Router, decode payload arguments, use returned adapter bytes, or allow per-leg failure.

- [ ] **Step 4: Run input tests and verify GREEN**

Run:

```bash
forge test --match-path test/Router.t.sol --match-test 'testTransfers|testReverts.*Input|testLateLeg' -vvv
```

Expected: all direct-funding and atomic rollback tests pass.

- [ ] **Step 5: Commit exact adapter execution**

```bash
git add src/Router.sol test/Router.t.sol
git commit -m "feat: execute registered adapter swap calls"
```

---

### Task 3: Enforce output deltas, recipients, surplus, and reentrancy

**Files:**

- Modify: `src/Router.sol`
- Modify: `test/Router.t.sol`

**Interfaces:**

- Produces unique-token snapshot accounting inside `_execute`.
- Produces exact recipient receipts, surplus-to-caller, and final baseline restoration.
- Completes the atomic `execute` behavior and events.

- [ ] **Step 1: Write failing settlement and attack tests**

Cover duplicate output tokens/recipients, multiple tokens, aggregate underproduction, exact production, surplus, pre-existing balances, undeclared tokens, fee-on-transfer output, sender-side fee, malicious adapter balance reduction, recipient/token/adapter reentrancy, and event rollback:

```solidity
function testPreexistingBalanceCannotSatisfyMinimumOrBecomeSurplus() public {
    outputToken.mint(address(router), 100 ether);
    adapter.setOutput(9 ether);
    vm.expectRevert(abi.encodeWithSelector(IRouter.InsufficientOutput.selector, address(outputToken), 10 ether, 9 ether));
    vm.prank(swapper);
    router.execute(address(inputToken), _oneCall(10 ether), _oneOutput(10 ether, swapper));
    assertEq(outputToken.balanceOf(address(router)), 100 ether);
}

function testSurplusGoesToCallerAfterExactRecipientPayments() public {
    adapter.setOutput(12 ether);
    vm.prank(swapper);
    router.execute(address(inputToken), _oneCall(10 ether), _oneOutput(10 ether, referrer));
    assertEq(outputToken.balanceOf(referrer), 10 ether);
    assertEq(outputToken.balanceOf(swapper), 2 ether);
}
```

- [ ] **Step 2: Run settlement tests and verify RED**

Run:

```bash
forge test --match-path test/Router.t.sol --match-test 'testPreexisting|testSurplus|testReentr|testOutput|testDuplicate' -vvv
```

Expected: tests fail because output accounting and payouts are absent.

- [ ] **Step 3: Implement grouped snapshots and aggregate minimums**

Build fixed-size memory arrays with `outputs.length` capacity and a `uniqueCount`. For each output, linearly find or append its token, record the Router baseline exactly once, and checked-add its required amount. After adapter calls:

```solidity
uint256 finalBalance = IERC20(tokens[i]).balanceOf(address(this));
if (finalBalance < baselines[i]) {
    revert BalanceIsolationViolation(tokens[i], baselines[i], finalBalance);
}
uint256 produced = finalBalance - baselines[i];
if (produced < required[i]) revert InsufficientOutput(tokens[i], required[i], produced);
producedByToken[i] = produced;
```

- [ ] **Step 4: Implement exact payouts, surplus, and final restoration**

For every declared output, snapshot recipient balance, safe-transfer, require an exact increase, and emit `OutputTransferred`. Then for each unique token transfer `produced - required` to `msg.sender`, check its exact receipt, emit `SurplusTransferred`, and require Router's final token balance equals its baseline. Emit `Execute` only after all final assertions.

Keep both external overloads under the same `nonReentrant` guard. Do not call one guarded overload from the other; both call one unguarded internal `_execute`.

- [ ] **Step 5: Run the complete Router test suite and verify GREEN**

Run:

```bash
forge test --match-path test/Router.t.sol -vvv
forge test --match-path test/Router.t.sol --fuzz-runs 10000
forge fmt --check
```

Expected: all validation, accounting, rollback, fee-token, balance-isolation, and reentrancy tests pass.

- [ ] **Step 6: Commit settlement**

```bash
git add src/Router.sol test/Router.t.sol
git commit -m "feat: settle Router output deltas"
```

---

### Task 4: Add deployment integration and package documentation

**Files:**

- Create: `script/deploy/DeployRouter.s.sol`
- Modify: `README.md`
- Modify: `test/Router.t.sol`

**Interfaces:**

- Produces `DeployRouterScript.run() returns (Router)` using `LIQUID_LANE_ADAPTER_FACTORY`.
- Documents approval, typed execution, the signed-only selector restriction, and deployment.

- [ ] **Step 1: Write a failing deployment-script assertion**

Add a test that sets the environment value, runs the script, and verifies the immutable:

```solidity
function testDeployRouterUsesFactoryEnvironment() public {
    vm.setEnv("LIQUID_LANE_ADAPTER_FACTORY", vm.toString(address(registry)));
    Router deployed = new DeployRouterScript().run();
    assertEq(deployed.LIQUID_LANE_ADAPTER_FACTORY(), address(registry));
}
```

- [ ] **Step 2: Run the deployment test and verify RED**

Run:

```bash
forge test --match-path test/Router.t.sol --match-test testDeployRouterUsesFactoryEnvironment -vvv
```

Expected: compilation fails because `DeployRouterScript` does not exist.

- [ ] **Step 3: Add the deployment script**

Create a script matching existing style:

```solidity
contract DeployRouterScript is Script {
    function run() public returns (Router router) {
        address factory = vm.envAddress("LIQUID_LANE_ADAPTER_FACTORY");
        vm.startBroadcast();
        router = new Router(factory);
        vm.stopBroadcast();
        console2.log("Deployed Router:", address(router));
    }
}
```

- [ ] **Step 4: Document the exact user flow**

Add Router to `README.md`: approve input ERC-20 to Router, obtain backend `/swap` transaction, submit typed deadline `execute`, and note that only registered signed-swap calls, standard ERC-20, and distinct token pairs are supported. Document that discount calldata is rejected and must be rebuilt as a fresh signed swap. Add a deployment command using `LIQUID_LANE_ADAPTER_FACTORY`.

- [ ] **Step 5: Run package verification**

Run from a Foundry workspace containing the stage package dependencies:

```bash
forge fmt --check
forge build
forge test --match-path test/Router.t.sol --fuzz-runs 10000
```

Expected: formatting, compilation, and all Router tests pass. If the sparse stage checkout cannot resolve its existing workspace-only remappings, run the same commands from the parent RFQ Foundry workspace with this worktree mounted as `rfq/reactor`; do not vendor or change dependencies merely to make the sparse branch standalone.

- [ ] **Step 6: Commit deployment and docs**

```bash
git add script/deploy/DeployRouter.s.sol README.md test/Router.t.sol
git commit -m "docs: add Router deployment flow"
```

- [ ] **Step 7: Review the final diff against stage**

```bash
git diff --check origin/stage...HEAD
git diff --stat origin/stage...HEAD
git status --short
```

Expected: only Router interface/implementation/tests/deployment/docs plus approved spec and plan are changed; status is clean.
