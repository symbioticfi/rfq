// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {RfqDeployConfig} from "../../script/deploy/RfqDeployConfig.sol";
import {DeployReactorBaseScript} from "../../script/deploy/base/DeployReactorBase.s.sol";

import {Test} from "forge-std/Test.sol";

contract RfqDeployConfigTest is Test {
    function testHoodiConfigReturnsLiquidLaneAdapterFactory() public pure {
        assertEq(
            RfqDeployConfig.liquidLaneAdapterFactory(RfqDeployConfig.HOODI_CHAIN_ID),
            0x7Ce3f158f22aC66F8Ed2973B7a10F666818301C5
        );
    }

    function testSepoliaConfigReturnsLiquidLaneAdapterFactory() public pure {
        assertEq(
            RfqDeployConfig.liquidLaneAdapterFactory(RfqDeployConfig.SEPOLIA_CHAIN_ID),
            0xE929Cf04D2A587817773E6B5cB9Bc8D01f909Faa
        );
    }

    function testMainnetConfigUsesLiquidLaneDeployment() public pure {
        assertEq(
            RfqDeployConfig.liquidLaneAdapterFactory(RfqDeployConfig.MAINNET_CHAIN_ID),
            0x3275aE068F4951e2e4d3Dca107a54E4c219b02e7
        );
    }

    function testDeployReactorAcceptsMainnetLiquidLaneConfig() public {
        DeployReactorBaseHarness harness = new DeployReactorBaseHarness();
        DeployReactorBaseScript.DeploymentData memory data = harness.runBase(
            DeployReactorBaseScript.DeployParams({
                liquidLaneAdapterFactory: RfqDeployConfig.liquidLaneAdapterFactory(RfqDeployConfig.MAINNET_CHAIN_ID)
            })
        );

        assertEq(data.reactor.LIQUID_LANE_ADAPTER_FACTORY(), 0x3275aE068F4951e2e4d3Dca107a54E4c219b02e7);
    }

    function testUnsupportedChainReverts() public {
        RfqDeployConfigHarness harness = new RfqDeployConfigHarness();

        vm.expectRevert(abi.encodeWithSelector(RfqDeployConfig.UnsupportedChain.selector, uint256(42)));
        harness.liquidLaneAdapterFactory(42);
    }
}

contract RfqDeployConfigHarness {
    function liquidLaneAdapterFactory(uint256 chainId) external pure returns (address factory) {
        factory = RfqDeployConfig.liquidLaneAdapterFactory(chainId);
    }
}

contract DeployReactorBaseHarness is DeployReactorBaseScript {
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}
}
