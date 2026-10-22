// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IRelayer} from "./interfaces/IRelayer.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Relayer
/// @notice Holds the ERC-20 allowances users grant, on behalf of exactly one router.
///
/// @dev This contract exists so the address users approve is *not* the address that makes arbitrary
///      calls. It has one function, one caller, and no other reachable behaviour: it cannot be made
///      to call anything else, so an allowance granted here can only ever move tokens to the router.
///
///      `ROUTER` is the deployer. The router constructs its relayer, which makes the pairing
///      immutable on both sides with no setter and no window in which the relayer is unowned.
contract Relayer is IRelayer {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRelayer
    address public immutable ROUTER;

    constructor() {
        ROUTER = msg.sender;
    }

    /// @inheritdoc IRelayer
    function pull(address token, address from, uint256 amount) external {
        if (msg.sender != ROUTER) {
            revert NotRouter();
        }

        IERC20(token).safeTransferFrom(from, ROUTER, amount);
    }
}
