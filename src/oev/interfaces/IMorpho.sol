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

/// @notice Opaque Morpho market identifier.
type Id is bytes32;

/// @notice Minimal subset of the Morpho Blue interface used by the OEV solver.
interface IMorpho {
    function idToMarketParams(Id id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);

    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

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
