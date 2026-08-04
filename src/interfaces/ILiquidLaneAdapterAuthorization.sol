// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice Minimal LiquidLane adapter interface used to validate current swap signers.
interface ILiquidLaneAdapterAuthorization {
    function owner() external view returns (address);
    function marketMaker() external view returns (address);
    function isFiller(address marketMaker, address filler) external view returns (bool);
}
