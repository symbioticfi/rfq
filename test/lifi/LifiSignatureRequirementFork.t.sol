// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../../src/interfaces/ILiquidLaneAdapter.sol";
import {LiquidLaneLifiExecutor} from "../../src/lifi/LiquidLaneLifiExecutor.sol";
import {IInputSettler} from "../../src/lifi/interfaces/IInputSettler.sol";
import {ILiquidLaneLifiExecutor} from "../../src/lifi/interfaces/ILiquidLaneLifiExecutor.sol";
import {MandateOutput} from "../../src/lifi/interfaces/IOutputSettler.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

interface IInputSettlerEscrowLike {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function open(IInputSettler.StandardOrder calldata order) external;
    function orderIdentifier(IInputSettler.StandardOrder calldata order) external view returns (bytes32);
    function orderStatus(bytes32 orderId) external view returns (uint8);
}

contract LifiSignatureRequirementForkTest is Test {
    address internal constant INPUT_SETTLER = 0x000025c3226C00B2Cdc200005a1600509f4e00C0;
    address internal constant OUTPUT_SETTLER = 0x0000000000eC36B683C2E6AC89e9A75989C22a2e;

    address internal user = makeAddr("user");
    address internal solver;
    uint256 internal solverKey;
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");

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
        (solver, solverKey) = makeAddrAndKey("solver");

        inputToken = new ForkTestToken("Fork RWA", "FRWA");
        outputToken = new ForkTestToken("Fork USD", "FUSD");
        adapter = new ForkMintingAdapter(outputToken);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        executor = new LiquidLaneLifiExecutor(INPUT_SETTLER, OUTPUT_SETTLER, owner, adapters);
    }

    function testEmptyOrderOwnerSignatureRevertsOnRealSettler() external {
        IInputSettler.StandardOrder memory order = _openOrder(10 ether, 9 ether, "empty");
        bytes32 orderId = IInputSettlerEscrowLike(INPUT_SETTLER).orderIdentifier(order);
        bytes memory call = _fillCall(order, orderId);

        vm.expectRevert();
        executor.finaliseWithCurrentTimestamp(INPUT_SETTLER, order, solver, address(executor), call, "");
    }

    function testSignedAllowOpenSettlesOnRealSettler() external {
        IInputSettler.StandardOrder memory order = _openOrder(10 ether, 9 ether, "signed");
        bytes32 orderId = IInputSettlerEscrowLike(INPUT_SETTLER).orderIdentifier(order);
        bytes memory call = _fillCall(order, orderId);

        executor.finaliseWithCurrentTimestamp(
            INPUT_SETTLER, order, solver, address(executor), call, _allowOpenSignature(orderId, address(executor), call)
        );

        assertEq(IInputSettlerEscrowLike(INPUT_SETTLER).orderStatus(orderId), 2, "claimed");
        assertEq(outputToken.balanceOf(recipient), 9 ether, "recipient output");
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
            nonce: uint256(keccak256(abi.encodePacked("signature-requirement", salt))),
            originChainId: block.chainid,
            expires: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 30 minutes),
            inputOracle: OUTPUT_SETTLER,
            inputs: inputs,
            outputs: outputs
        });
    }

    function _fillCall(IInputSettler.StandardOrder memory order, bytes32 orderId) internal view returns (bytes memory) {
        ILiquidLaneLifiExecutor.FillRoute[] memory routes = new ILiquidLaneLifiExecutor.FillRoute[](1);
        routes[0] = ILiquidLaneLifiExecutor.FillRoute({
            adapter: address(adapter),
            amountIn: order.inputs[0][1],
            expectedAmountOut: 10 ether,
            minAmountOut: 10 ether,
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
        return abi.encode(
            ILiquidLaneLifiExecutor.FillCall({
                orderId: orderId,
                output: order.outputs[0],
                fillDeadline: order.fillDeadline,
                solver: _id(solver),
                fillAfter: 0,
                routes: routes
            })
        );
    }

    function _allowOpenSignature(bytes32 orderId, address destination, bytes memory call)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AllowOpen(bytes32 orderId,bytes32 destination,bytes call)"),
                orderId,
                _id(destination),
                keccak256(call)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", IInputSettlerEscrowLike(INPUT_SETTLER).DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solverKey, digest);
        return abi.encodePacked(r, s, v);
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

    function getAmountOut(address, uint256 amountIn) external pure returns (uint256) {
        return amountIn;
    }

    function getMaxAssets(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function minDiscount(address) external pure returns (uint256) {
        return 0;
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
