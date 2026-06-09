// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IWhitelist} from "3f-request-whitelist/src/IWhitelist.sol";

/// @title  MockWhitelist
/// @notice Test-only `IWhitelist` that attests every address as `Whitelisted`. For Sepolia / local
///         use, where 3F's real `RequestWhitelist` registry is not deployed (it ships in prod only).
/// @dev    DO NOT use in production: it performs no attestation and never pauses. Wire it as the
///         `BridgeFacilitatorAdapter`'s `REQUEST_WHITELIST` only on testnets.
contract MockWhitelist is IWhitelist {
    /// @inheritdoc IWhitelist
    function isWhitelisted(address) external pure override returns (WhitelistStatus) {
        return WhitelistStatus.Whitelisted;
    }
}
