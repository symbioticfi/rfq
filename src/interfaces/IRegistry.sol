// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice Minimal LiquidLane adapter-factory registry interface.
interface IRegistry {
    function isEntity(address entity) external view returns (bool);
}
