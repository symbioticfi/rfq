// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {ILiquidLaneAdapter} from "./interfaces/ILiquidLaneAdapter.sol";
import {IReactor, NATIVE} from "./interfaces/IReactor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title Executor
/// @notice Caller-gated executor that forwards fills into Reactor and handles execution callbacks.
/// @dev Deployed behind a transparent proxy; the Reactor address is immutable in the implementation
/// while ownership and the caller list live in proxy storage set by {initialize}.
contract Executor is Initializable, OwnableUpgradeable, IExecutor {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using Address for address;

    /* IMMUTABLES */

    /// @dev Reactor that is allowed to trigger execution callbacks.
    address internal immutable REACTOR;

    /* STATE VARIABLES */

    /// @dev Callers that are allowed to fill orders.
    address[] public callers;

    /* CONSTRUCTOR */

    constructor(address reactor) {
        REACTOR = reactor;
        _disableInitializers();
    }

    /// @inheritdoc IExecutor
    function initialize(address owner, address[] calldata initCallers) external initializer {
        __Ownable_init(owner);

        callers = initCallers;
    }

    /* MODIFIERS */

    /// @dev Reverts unless the caller is in the allowed caller list.
    modifier onlyCaller() {
        if (!_isCaller(msg.sender)) {
            revert NotCaller();
        }

        _;
    }

    /* PUBLIC FUNCTIONS (CALLER) */

    /// @inheritdoc IExecutor
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput calldata swapInput,
        bytes calldata executorData
    ) public onlyCaller {
        IReactor(REACTOR).fill(order, protocolSignature, swapInput, executorData);
    }

    /// @inheritdoc IExecutor
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput[] calldata swapInputs,
        bytes calldata executorData
    ) public onlyCaller {
        IReactor(REACTOR).fill(order, protocolSignature, swapInputs, executorData);
    }

    /// @inheritdoc IExecutor
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) public onlyCaller {
        IReactor(REACTOR).fill(order, protocolSignature, swapInputs, discountSwapInputs, executorData);
    }

    /// @inheritdoc IExecutor
    function execute(
        IReactor.Order calldata order,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) public {
        if (REACTOR != msg.sender) {
            revert NotReactor();
        }

        for (uint256 i; i < swapInputs.length; ++i) {
            ILiquidLaneAdapter(swapInputs[i].adapter).swap(swapInputs[i].swap);
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            ILiquidLaneAdapter(discountSwapInputs[i].adapter)
                .swap(
                    discountSwapInputs[i].discountSwap,
                    discountSwapInputs[i].protocolSignature,
                    discountSwapInputs[i].recipient,
                    discountSwapInputs[i].amountIn
                );
        }

        Call[] memory calls = abi.decode(executorData, (Call[]));
        for (uint256 i; i < calls.length; ++i) {
            calls[i].target.functionCallWithValue(calls[i].data, calls[i].value);
        }

        for (uint256 i; i < order.outputs.length; ++i) {
            address token = order.outputs[i].token;
            if (token != NATIVE && IERC20(token).allowance(address(this), REACTOR) < type(uint256).max) {
                IERC20(token).forceApprove(REACTOR, type(uint256).max);
            }
        }

        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(REACTOR).sendValue(balance);
        }
    }

    /* PUBLIC FUNCTIONS (OWNER) */

    /// @inheritdoc IExecutor
    function setCallers(address[] calldata newCallers) public onlyOwner {
        callers = newCallers;

        emit SetCallers(newCallers);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns whether `caller` can invoke fill entrypoints.
    function _isCaller(address caller) internal view returns (bool) {
        for (uint256 i; i < callers.length; ++i) {
            if (callers[i] == caller) {
                return true;
            }
        }
        return false;
    }

    /* RECEIVE FUNCTION */

    /// @dev Accepts native asset used for downstream output delivery or refunds.
    receive() external payable {}
}
