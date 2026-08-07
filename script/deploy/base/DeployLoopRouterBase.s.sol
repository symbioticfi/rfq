// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {RfqDeployConfig} from "../RfqDeployConfig.sol";
import {LoopRouter} from "../../../src/LoopRouter.sol";

contract DeployLoopRouterBaseScript is Script {
    /// @dev Morpho Blue singleton. Deployed at the same address on every chain Morpho supports.
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    struct DeployParams {
        address morpho;
        address liquidLaneAdapterFactory;
        address owner;
    }

    struct DeploymentData {
        address morpho;
        address liquidLaneAdapterFactory;
        address owner;
        LoopRouter loopRouter;
    }

    function runBase() public virtual returns (DeploymentData memory data) {
        data = runBase(
            DeployParams({
                morpho: MORPHO_BLUE,
                liquidLaneAdapterFactory: RfqDeployConfig.currentLiquidLaneAdapterFactory(),
                owner: _defaultOwner()
            })
        );
    }

    function runBase(DeployParams memory params) public virtual returns (DeploymentData memory data) {
        _validateParams(params);

        data.morpho = params.morpho;
        data.liquidLaneAdapterFactory = params.liquidLaneAdapterFactory;
        data.owner = params.owner;

        _startBroadcast();
        data.loopRouter = new LoopRouter(params.morpho, params.liquidLaneAdapterFactory, params.owner);
        _stopBroadcast();

        _validateDeployment(data);
        _logDeployment(data);
    }

    function _defaultOwner() internal view virtual returns (address) {
        return vm.envAddress("LOOP_ROUTER_OWNER");
    }

    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    function _validateParams(DeployParams memory params) internal view virtual {
        require(params.morpho.code.length > 0, "morpho has no code");
        require(params.liquidLaneAdapterFactory.code.length > 0, "adapter factory has no code");
        require(params.owner != address(0), "owner is zero");
    }

    function _validateDeployment(DeploymentData memory data) internal view virtual {
        require(data.loopRouter.MORPHO() == data.morpho, "morpho mismatch");
        require(
            data.loopRouter.LIQUID_LANE_ADAPTER_FACTORY() == data.liquidLaneAdapterFactory, "adapter factory mismatch"
        );
        require(data.loopRouter.owner() == data.owner, "owner mismatch");
    }

    function _logDeployment(DeploymentData memory data) internal virtual {
        console2.log("Deployed LoopRouter");
        console2.log("    loopRouter:", address(data.loopRouter));
        console2.log("    morpho:", data.morpho);
        console2.log("    liquidLaneAdapterFactory:", data.liquidLaneAdapterFactory);
        console2.log("    owner:", data.owner);
        console2.log("Next: allowlist acquisition/settlement venues with setVenue before the Loop tab goes live.");
    }
}
