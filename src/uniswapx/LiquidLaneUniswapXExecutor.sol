// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.38;

import {IExecutor} from "src/interfaces/IExecutor.sol";
import {ILiquidLaneUniswapXExecutor} from "./interfaces/ILiquidLaneUniswapXExecutor.sol";
import {IUniswapXReactor, UniswapXResolvedOrder, UniswapXSignedOrder} from "./interfaces/IUniswapXReactor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidLaneUniswapXExecutor
/// @notice UniswapX Reactor callback that executes supplied calls and settles outputs atomically.
contract LiquidLaneUniswapXExecutor is Initializable, OwnableUpgradeable, ILiquidLaneUniswapXExecutor {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using Address for address;

    address internal immutable REACTOR;
    address[] public callers;

    constructor(address reactor) {
        REACTOR = reactor;
        _disableInitializers();
    }

    function initialize(address owner, address[] calldata initCallers) external initializer {
        __Ownable_init(owner);
        callers = initCallers;
    }

    modifier onlyCaller() {
        if (!_isCaller(msg.sender)) revert NotCaller();
        _;
    }

    /// @inheritdoc ILiquidLaneUniswapXExecutor
    function execute(UniswapXSignedOrder calldata order, IExecutor.Call[] calldata calls) external onlyCaller {
        IUniswapXReactor(REACTOR).executeWithCallback(order, abi.encode(calls));
    }

    function reactorCallback(UniswapXResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external {
        if (msg.sender != REACTOR) revert NotReactor();

        IExecutor.Call[] memory calls = abi.decode(callbackData, (IExecutor.Call[]));

        for (uint256 i; i < calls.length; ++i) {
            calls[i].target.functionCallWithValue(calls[i].data, calls[i].value);
        }

        for (uint256 i; i < resolvedOrders[0].outputs.length; ++i) {
            address token = resolvedOrders[0].outputs[i].token;
            // Native output (address(0)) is forwarded below; only ERC-20 outputs need a Reactor allowance.
            if (token != address(0) && IERC20(token).allowance(address(this), REACTOR) < type(uint256).max) {
                IERC20(token).forceApprove(REACTOR, type(uint256).max);
            }
        }

        uint256 balance = address(this).balance;
        if (balance > 0) payable(REACTOR).sendValue(balance);
    }

    function setCallers(address[] calldata newCallers) public onlyOwner {
        callers = newCallers;
        emit SetCallers(newCallers);
    }

    function _isCaller(address caller) internal view returns (bool) {
        for (uint256 i; i < callers.length; ++i) {
            if (callers[i] == caller) return true;
        }
        return false;
    }

    receive() external payable {}
}
