# RecipeExecutor fixture

`RecipeExecutor.json` contains test-only creation bytecode from `symbioticfi/adapters`, revision `bd5e235899de5e175a0001a913d47596f6f4f801`, source `src/contracts/merkle-adapter/automations/RecipeExecutor.sol`. The copied RFQ interfaces come from the same revision.

Reproduce the bytecode in an adapters checkout at that revision, with its pinned submodules initialized:

```sh
forge inspect RecipeExecutor bytecode --use 0.8.37 --evm-version cancun --via-ir --optimizer-runs 200
```

Compiler: `0.8.37+commit.f401782d`; optimizer: 200 runs; IR pipeline enabled; EVM target: Cancun. Creation bytecode is 6,665 bytes; SHA-256 of the decoded bytes is `c6b153324778a428586efda2e1e3524b25328670250bf26a9000fa0ce36c2c8a`. `RecipeRouteBuilder.deployReal` verifies that digest before deployment and supplies the owner/account constructor arguments. This fixture does not change RFQ's compiler or add adapters as a production dependency.

The real RecipeExecutor interpreter verifies caller, recipe commitment, instruction schema and managed-action leaves. RFQ tests forward both call instructions with numeric bindings and manage instructions with nonempty runtime containing an account action and a Merkle proof. The account is a fixture that validates the proof and calls a version 2 connector fixture. That connector enforces its account-only caller, returns funded input to the account, and pulls output assets from the account. The LI.FI settlers, UniswapX Reactor and factory membership registry are also fixtures. These tests verify the integration with the real interpreter, not a deployed Merkle account's complete role/policy system or a deployed LiquidLaneConnector's complete oracle, limit and discount-policy system. Native-output cases use an additional mock account action; LiquidLaneConnector itself pays ERC-20 outputs.

The smaller `MockRecipeExecutor` is used for fuzzed amounts, multi-route execution and rollback assertions. Its committed call encoding matches `IRecipes`, but it implements only the test's call instruction and caller/commitment checks. It does not substitute for the real interpreter tests.
