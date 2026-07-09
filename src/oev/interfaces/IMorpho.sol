// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Morpho Blue market parameters.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Morpho Blue user position.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Opaque Morpho market identifier.
type Id is bytes32;

/// @notice Minimal subset of the Morpho Blue interface used by the OEV solver.
interface IMorpho {
    function idToMarketParams(Id id) external view returns (MarketParams memory);

    function position(Id id, address borrower) external view returns (Position memory);

    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256 assetsSeized, uint256 assetsRepaid);
}

/// @notice Callback invoked by Morpho during a liquidation when non-empty `data` is supplied.
interface IMorphoLiquidateCallback {
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external;
}
