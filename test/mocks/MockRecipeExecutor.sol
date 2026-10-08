// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRecipeExecutor} from "src/interfaces/IRecipeExecutor.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IRecipeRoute} from "src/interfaces/IRecipeRoute.sol";
import {IRecipes, OP_CALL, OP_MANAGE, SRC_INPUT} from "src/interfaces/IRecipes.sol";

import {Vm} from "forge-std/Vm.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Interface fixture implementing caller/commitment checks and the production OP_CALL encoding.
/// It does not replace the upstream RecipeExecutor's full interpreter or Merkle-account verification.
contract MockRecipeExecutor {
    using Address for address;

    address public immutable account;
    address public caller;
    bytes32 public recipeHash;
    uint256 public executions;

    constructor(address newCaller) {
        caller = newCaller;
        account = address(new MockRecipeAccount(address(this)));
    }

    function setCaller(address newCaller) external {
        caller = newCaller;
    }

    function setRecipe(bytes[] calldata queries, bytes[] calldata steps) external {
        recipeHash = keccak256(abi.encode(queries, steps));
    }

    function execute(
        bytes[] calldata queries,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) external returns (uint256[] memory values) {
        if (msg.sender != caller) revert IRecipeExecutor.InvalidCaller();
        if (keccak256(abi.encode(queries, steps)) != recipeHash) revert IRecipeExecutor.InvalidRecipe();
        if (runtime.length != 0) revert IRecipes.InvalidRuntime();

        ++executions;
        values = new uint256[](steps.length);
        for (uint256 i; i < steps.length; ++i) {
            if (uint8(steps[i][0]) != OP_CALL) revert IRecipes.InvalidOperation();
            (address target, bytes memory data, uint256[] memory bindings) =
                abi.decode(steps[i][1:], (address, bytes, uint256[]));
            for (uint256 j; j < bindings.length; ++j) {
                uint256 offset = bindings[j] >> 224;
                if (offset < 4 || offset + 32 > data.length) revert IRecipes.InvalidCall();
                if (uint8(bindings[j] >> 216) != SRC_INPUT) revert IRecipes.InvalidReference();
                uint256 value = inputs[uint216(bindings[j])];
                assembly ("memory-safe") {
                    mstore(add(add(data, 32), offset), value)
                }
            }
            target.functionCall(data);
        }
    }
}

contract MockRecipeAccount {
    struct Action {
        address target;
        uint96 value;
        bytes data;
        bytes dataMask;
        bytes32[] proof;
    }

    bytes32 public root;
    using Address for address;
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public immutable executor;
    MockLiquidLaneConnector public immutable connector;
    uint256 public connectorInputBeforeSwap;

    constructor(address newExecutor) {
        executor = newExecutor;
        connector = new MockLiquidLaneConnector(address(this));
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        require(msg.sender == executor || msg.sender == address(this), "not recipe executor");
        connectorInputBeforeSwap = IERC20(tokenIn).balanceOf(address(connector));
        connector.setOutputAsset(tokenOut);
        if (tokenOut != address(0)) IERC20(tokenOut).forceApprove(address(connector), amountOut);
        connector.swap(
            ILiquidLaneAdapter.Swap({recipient: recipient, tokenIn: tokenIn, amountIn: amountIn, amountOut: amountOut})
        );
        if (tokenOut == address(0)) payable(recipient).sendValue(amountOut);
    }

    function setRoot(bytes32 newRoot) external {
        root = newRoot;
    }

    function manage(Action[] calldata actions) external returns (bytes[] memory results) {
        require(msg.sender == executor, "not recipe executor");
        results = new bytes[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            Action calldata action = actions[i];
            require(action.data.length == action.dataMask.length, "mask length");
            bytes memory masked = new bytes(action.data.length);
            for (uint256 j; j < masked.length; ++j) {
                masked[j] = action.data[j] & ~action.dataMask[j];
            }
            bytes32 leaf = keccak256(
                bytes.concat(
                    keccak256(
                        abi.encode(
                            action.target,
                            action.value == 0 ? bytes1(0) : bytes1(0xff),
                            keccak256(action.dataMask),
                            keccak256(masked)
                        )
                    )
                )
            );
            require(MerkleProof.verify(action.proof, root, leaf), "invalid proof");
            results[i] = action.target.functionCallWithValue(action.data, action.value);
        }
    }

    receive() external payable {}
}

/// @dev Version 2 connector fixture: account-only swap, input returned to account, output pulled from account.
contract MockLiquidLaneConnector {
    using SafeERC20 for IERC20;
    address public immutable account;
    address public outputAsset;
    uint256 public swaps;

    constructor(address newAccount) {
        account = newAccount;
    }

    function version() external pure returns (uint64) {
        return 2;
    }

    function setOutputAsset(address asset) external {
        require(msg.sender == account, "not account");
        outputAsset = asset;
    }

    function swap(ILiquidLaneAdapter.Swap calldata newSwap) external {
        require(msg.sender == account, "not account");
        ++swaps;
        IERC20(newSwap.tokenIn).safeTransfer(account, newSwap.amountIn);
        if (outputAsset != address(0)) {
            IERC20(outputAsset).safeTransferFrom(account, newSwap.recipient, newSwap.amountOut);
        }
    }
}

library RecipeRouteBuilder {
    /// @dev Deploys the pinned upstream contract bytecode without adding adapters as a production dependency.
    function deployReal(Vm vm, address caller) internal returns (IRecipeExecutor executor) {
        string memory fixture = vm.readFile("test/fixtures/RecipeExecutor.json");
        bytes memory bytecode = vm.parseJsonBytes(fixture, ".bytecode");
        require(
            sha256(bytecode) == 0xc6b153324778a428586efda2e1e3524b25328670250bf26a9000fa0ce36c2c8a,
            "upstream bytecode changed"
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockRecipeAccount account = new MockRecipeAccount(predicted);
        bytes memory creation = bytes.concat(bytecode, abi.encode(address(this), address(account)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(creation, 32), mload(creation))
        }
        require(deployed == predicted, "recipe deployment failed");
        executor = IRecipeExecutor(deployed);
        executor.setCaller(caller);
    }

    /// @dev Actual OP_MANAGE schema and nonempty runtime/proofs against an account interface fixture.
    function buildManaged(
        IRecipeExecutor executor,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    ) internal returns (IRecipeRoute.RecipeRoute memory route) {
        route.executor = address(executor);
        route.connector = address(MockRecipeAccount(payable(executor.account())).connector());
        route.amountIn = amountIn;
        route.queries = new bytes[](1);
        route.queries[0] =
            abi.encode(tokenIn, abi.encodeCall(IERC20.balanceOf, (executor.account())), new uint256[](0), 0);
        route.steps = new bytes[](1);
        route.inputs = new uint256[](2);
        route.inputs[0] = amountIn;
        route.inputs[1] = amountOut;
        route.runtime = new bytes[](1);
        (bytes32 leaf, bytes32 root, bytes memory runtime) = _managedRuntime(
            executor.account(),
            abi.encodeCall(MockRecipeAccount.swap, (tokenIn, tokenOut, amountIn, amountOut, recipient))
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](0);
        route.steps[0] = bytes.concat(bytes1(OP_MANAGE), abi.encode(uint256(1), leaves, bindings));
        route.runtime[0] = runtime;
        MockRecipeAccount(payable(executor.account())).setRoot(root);
        executor.setRecipe(route.queries, route.steps);
    }

    function _managedRuntime(address account, bytes memory data)
        private
        pure
        returns (bytes32 leaf, bytes32 root, bytes memory runtime)
    {
        bytes memory mask = new bytes(data.length);
        leaf = keccak256(bytes.concat(keccak256(abi.encode(account, bytes1(0), keccak256(mask), keccak256(data)))));
        bytes32 sibling = keccak256("unused account capability");
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        MockRecipeAccount.Action[] memory actions = new MockRecipeAccount.Action[](1);
        actions[0] = MockRecipeAccount.Action({target: account, value: 0, data: data, dataMask: mask, proof: proof});
        runtime = abi.encode(actions);
        root = leaf < sibling ? keccak256(bytes.concat(leaf, sibling)) : keccak256(bytes.concat(sibling, leaf));
    }

    function build(
        MockRecipeExecutor executor,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    ) internal returns (IRecipeRoute.RecipeRoute memory route) {
        route.executor = address(executor);
        route.connector = address(MockRecipeAccount(payable(executor.account())).connector());
        route.amountIn = amountIn;
        route.queries = new bytes[](0);
        route.steps = new bytes[](1);
        route.inputs = new uint256[](2);
        route.inputs[0] = amountIn;
        route.inputs[1] = amountOut;
        route.runtime = new bytes[](0);
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(68) << 224) | (uint256(SRC_INPUT) << 216);
        bindings[1] = (uint256(100) << 224) | (uint256(SRC_INPUT) << 216) | 1;
        route.steps[0] = bytes.concat(
            bytes1(OP_CALL),
            abi.encode(
                executor.account(),
                abi.encodeCall(MockRecipeAccount.swap, (tokenIn, tokenOut, 0, 0, recipient)),
                bindings
            )
        );
        executor.setRecipe(route.queries, route.steps);
    }
}
