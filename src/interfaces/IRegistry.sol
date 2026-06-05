// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/**
 * @title IRegistry
 * @notice Minimal entity registry interface used for factory validation.
 */
interface IRegistry {
    /**
     * @notice Returns whether `account` is an entity created by the registry/factory.
     * @param account Address to check.
     * @return status Whether the account is a registered entity.
     */
    function isEntity(address account) external view returns (bool status);
}
