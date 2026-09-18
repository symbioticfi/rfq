// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.34;

import {IReactorV2} from "src/interfaces/IReactorV2.sol";

/// @notice Filler callback after Permit2 funds the order's adapter or connector.
interface IReactorV2Callback {
    /// @dev Implementations must authenticate msg.sender as their trusted ReactorV2.
    /// Adapter swaps, discounts and Merkle execution proofs belong in executorData.
    function reactorCallback(IReactorV2.Order calldata order, bytes calldata executorData) external;
}
