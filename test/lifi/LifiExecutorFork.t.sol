// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../../src/interfaces/ILiquidLaneAdapter.sol";
import {LiquidLaneLifiExecutor} from "../../src/lifi/LiquidLaneLifiExecutor.sol";
import {IInputSettler} from "../../src/lifi/interfaces/IInputSettler.sol";
import {ILiquidLaneLifiExecutor} from "../../src/lifi/interfaces/ILiquidLaneLifiExecutor.sol";
import {MandateOutput} from "../../src/lifi/interfaces/IOutputSettler.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

interface IInputSettlerEscrowLike {
    function open(IInputSettler.StandardOrder calldata order) external;
    function orderIdentifier(IInputSettler.StandardOrder calldata order) external view returns (bytes32);
    function orderStatus(bytes32 orderId) external view returns (uint8);
}

contract LifiExecutorForkTest is Test {
    address internal constant INPUT_SETTLER = 0x000025c3226C00B2Cdc200005a1600509f4e00C0;
    address internal constant OUTPUT_SETTLER = 0x0000000000eC36B683C2E6AC89e9A75989C22a2e;

    address internal user = makeAddr("user");
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");

    ForkTestToken internal inputToken;
    ForkTestToken internal outputToken;
    ForkMintingAdapter internal adapter;
    LiquidLaneLifiExecutor internal executor;

    function setUp() external {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL_SEPOLIA", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "ETH_RPC_URL_SEPOLIA not set");
        }

        vm.createSelectFork(rpcUrl);
        inputToken = new ForkTestToken("Fork RWA", "FRWA");
        outputToken = new ForkTestToken("Fork USD", "FUSD");
        adapter = new ForkMintingAdapter(outputToken);

        LiquidLaneLifiExecutor impl = new LiquidLaneLifiExecutor(INPUT_SETTLER, OUTPUT_SETTLER);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), proxyAdminOwner, abi.encodeCall(LiquidLaneLifiExecutor.initialize, (owner))
        );
        executor = LiquidLaneLifiExecutor(address(proxy));
    }

    function testExecutorFinalisesOpenedOrderOnRealSettler() external {
        IInputSettler.StandardOrder memory order = _openOrder(10 ether, 9 ether, "executor");
        bytes32 orderId = IInputSettlerEscrowLike(INPUT_SETTLER).orderIdentifier(order);

        vm.prank(owner);
        executor.finaliseWithCurrentTimestamp(order, _routes(order));

        assertEq(IInputSettlerEscrowLike(INPUT_SETTLER).orderStatus(orderId), 2, "claimed");
        assertEq(outputToken.balanceOf(recipient), 9 ether, "recipient output");
        assertEq(outputToken.balanceOf(address(executor)), 1 ether, "executor surplus");
    }

    function _openOrder(uint256 amountIn, uint256 amountOut, string memory salt)
        internal
        returns (IInputSettler.StandardOrder memory order)
    {
        order = _order(amountIn, amountOut, salt);

        inputToken.mint(user, amountIn);
        vm.startPrank(user);
        inputToken.approve(INPUT_SETTLER, amountIn);
        IInputSettlerEscrowLike(INPUT_SETTLER).open(order);
        vm.stopPrank();

        bytes32 orderId = IInputSettlerEscrowLike(INPUT_SETTLER).orderIdentifier(order);
        assertEq(IInputSettlerEscrowLike(INPUT_SETTLER).orderStatus(orderId), 1, "deposited");
    }

    function _order(uint256 amountIn, uint256 amountOut, string memory salt)
        internal
        view
        returns (IInputSettler.StandardOrder memory order)
    {
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(inputToken))), amountIn];

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            oracle: _id(OUTPUT_SETTLER),
            settler: _id(OUTPUT_SETTLER),
            chainId: block.chainid,
            token: _id(address(outputToken)),
            amount: amountOut,
            recipient: _id(recipient),
            callbackData: hex"",
            context: hex""
        });

        order = IInputSettler.StandardOrder({
            user: user,
            nonce: uint256(keccak256(abi.encodePacked("lifi-executor", salt))),
            originChainId: block.chainid,
            expires: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 30 minutes),
            inputOracle: OUTPUT_SETTLER,
            inputs: inputs,
            outputs: outputs
        });
    }

    function _routes(IInputSettler.StandardOrder memory order)
        internal
        view
        returns (ILiquidLaneLifiExecutor.FillRoute[] memory routes)
    {
        routes = new ILiquidLaneLifiExecutor.FillRoute[](1);
        routes[0] = ILiquidLaneLifiExecutor.FillRoute({
            adapter: address(adapter),
            amountIn: order.inputs[0][1],
            amountOut: 10 ether,
            discount: ILiquidLaneLifiExecutor.FillDiscount({
                discountId: bytes32(0),
                discountSwap: ILiquidLaneAdapter.DiscountSwap({
                    discount: ILiquidLaneAdapter.Discount({
                        tokenToRedeem: address(0),
                        discount: 0,
                        signer: address(0),
                        protocol: address(0),
                        nonce: 0,
                        deadline: 0
                    }),
                    signerSignature: "",
                    protocolDeadline: 0
                }),
                protocolSignature: ""
            })
        });
    }

    function _id(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}

contract ForkMintingAdapter is ILiquidLaneAdapter {
    ForkTestToken public immutable outputToken;

    constructor(ForkTestToken outputToken_) {
        outputToken = outputToken_;
    }

    function swap(Swap calldata swap_) external {
        require(ForkTestToken(swap_.tokenIn).balanceOf(address(this)) >= swap_.amountIn, "missing input");
        outputToken.mint(swap_.recipient, swap_.amountOut);
    }

    function swap(SignedSwap calldata, bytes calldata) external {}

    function swap(DiscountSwap calldata, bytes calldata, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract ForkTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
