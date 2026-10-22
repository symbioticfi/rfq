// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice Holds user token allowances on behalf of exactly one router.
/// @dev Split from the router so that the contract users approve is not the contract that makes
///      arbitrary calls. The router can pull, and nothing else can.
interface IRelayer {
    error NotRouter();

    /// @notice The only address permitted to call `pull`.
    function ROUTER() external view returns (address router);

    /// @notice Moves `amount` of `token` from `from` to the router.
    /// @dev Callable only by `ROUTER`, which passes its own caller as `from`.
    function pull(address token, address from, uint256 amount) external;
}
