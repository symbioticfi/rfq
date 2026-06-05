// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Executor} from "../src/Executor.sol";
import {Reactor} from "../src/Reactor.sol";
import {CALLER_ROLE, IExecutor} from "../src/interfaces/IExecutor.sol";
import {IInstantRedemptionAdapter} from "../src/interfaces/IInstantRedemptionAdapter.sol";
import {
    IReactor,
    ORDER_TYPEHASH,
    OUTPUT_TYPEHASH,
    REQUEST_TYPEHASH,
    REQUEST_WITNESS_TYPE_STRING
} from "../src/interfaces/IReactor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

contract ReactorMainnetForkTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT2_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    uint256 internal constant DAI_AMOUNT = 100 ether;
    uint256 internal constant PROTOCOL_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant SWAPPER_PRIVATE_KEY = 0xBEEF;
    uint256 internal constant USDC_AMOUNT = 100e6;

    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address internal filler = makeAddr("filler");
    address internal protocol = vm.addr(PROTOCOL_PRIVATE_KEY);
    address internal swapper = vm.addr(SWAPPER_PRIVATE_KEY);
    address internal vault = makeAddr("vault");
    address internal vaultAccount = makeAddr("vaultAccount");

    ForkMockAdapter internal adapter;
    ForkAdapterFactory internal adapterFactory;
    Executor internal executor;
    Reactor internal reactor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        vm.etch(swapper, "");

        adapter = new ForkMockAdapter();
        adapterFactory = new ForkAdapterFactory();
        adapterFactory.setEntity(address(adapter), true);
        reactor = new Reactor(address(adapterFactory), PERMIT2);
        executor = new Executor(address(reactor), address(this));
        executor.grantRole(CALLER_ROLE, filler);

        adapter.setAccount(vault, DAI, vaultAccount);

        deal(DAI, swapper, DAI_AMOUNT * 4);
        deal(USDC, address(executor), USDC_AMOUNT * 4);

        vm.prank(swapper);
        IERC20(DAI).approve(PERMIT2, type(uint256).max);
    }

    function testForkFillUsesRealPermit2WitnessTransfer() public {
        IReactor.Output[] memory outputs = _singleUsdcOutput(USDC_AMOUNT);
        IReactor.Order memory order = _signedOrder(outputs, DAI_AMOUNT, 111);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, _swap(DAI_AMOUNT), abi.encode(new IExecutor.Call[](0)));

        assertEq(IERC20(DAI).balanceOf(vaultAccount), DAI_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(swapper), USDC_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(reactor)), 0);
        assertEq(IERC20(DAI).balanceOf(address(adapter)), 0);
    }

    function testForkPermit2RejectsNonceReplay() public {
        IReactor.Output[] memory outputs = _singleUsdcOutput(USDC_AMOUNT);
        IReactor.Order memory order = _signedOrder(outputs, DAI_AMOUNT, 222);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, _swap(DAI_AMOUNT), abi.encode(new IExecutor.Call[](0)));

        vm.expectRevert();
        vm.prank(filler);
        executor.fill(order, protocolSignature, _swap(DAI_AMOUNT), abi.encode(new IExecutor.Call[](0)));
    }

    function testForkPermit2RejectsWrongWitness() public {
        IReactor.Output[] memory outputs = _singleUsdcOutput(USDC_AMOUNT);
        IReactor.Order memory order = _signedOrder(outputs, DAI_AMOUNT, 333);

        order.request.outputs[0].amount = USDC_AMOUNT + 1;
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert();
        vm.prank(filler);
        executor.fill(order, protocolSignature, _swap(DAI_AMOUNT), abi.encode(new IExecutor.Call[](0)));
    }

    function testForkPermit2RejectsExpiredPermit() public {
        IReactor.Output[] memory outputs = _singleUsdcOutput(USDC_AMOUNT);
        IReactor.Order memory order = _signedOrder(outputs, DAI_AMOUNT, 444, block.timestamp - 1);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert();
        vm.prank(filler);
        executor.fill(order, protocolSignature, _swap(DAI_AMOUNT), abi.encode(new IExecutor.Call[](0)));
    }

    function _singleUsdcOutput(uint256 amount) internal view returns (IReactor.Output[] memory outputs) {
        outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: USDC, amount: amount, recipient: swapper});
    }

    function _signedOrder(IReactor.Output[] memory outputs, uint256 amountIn, uint256 nonce)
        internal
        view
        returns (IReactor.Order memory order)
    {
        return _signedOrder(outputs, amountIn, nonce, block.timestamp + 1 days);
    }

    function _signedOrder(IReactor.Output[] memory outputs, uint256 amountIn, uint256 nonce, uint256 deadline)
        internal
        view
        returns (IReactor.Order memory order)
    {
        order = IReactor.Order({
            request: IReactor.Request({
                tokenIn: DAI, amountIn: amountIn, outputs: outputs, deadline: deadline, nonce: nonce, protocol: protocol
            }),
            swapperSignature: "",
            swapper: swapper,
            filler: address(executor)
        });
        order.swapperSignature = _signPermit2Witness(order);
    }

    function _swap(uint256 amountIn) internal view returns (IReactor.SwapInput memory) {
        return IReactor.SwapInput({
            adapter: address(adapter),
            swap: IInstantRedemptionAdapter.Swap({
                recipient: filler, vault: vault, tokenIn: DAI, amountIn: amountIn, amountOut: USDC_AMOUNT
            })
        });
    }

    function _signOrder(IReactor.Order memory order) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        DOMAIN_TYPEHASH,
                        keccak256(bytes("Reactor")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(reactor)
                    )
                ),
                _hashOrder(order)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROTOCOL_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPermit2Witness(IReactor.Order memory order) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                REQUEST_WITNESS_TYPE_STRING
            )
        );
        bytes32 permittedHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, order.request.tokenIn, order.request.amountIn));
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                permittedHash,
                address(reactor),
                order.request.nonce,
                order.request.deadline,
                _hashRequest(order.request)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _permit2DomainSeparator(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SWAPPER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permit2DomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(PERMIT2_DOMAIN_TYPEHASH, keccak256(bytes("Permit2")), block.chainid, PERMIT2));
    }

    function _hashOrder(IReactor.Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _hashRequest(order.request),
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler
            )
        );
    }

    function _hashRequest(IReactor.Request memory request) internal pure returns (bytes32) {
        bytes32[] memory outputHashes = new bytes32[](request.outputs.length);
        for (uint256 i; i < request.outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, request.outputs[i]));
        }

        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                keccak256(abi.encodePacked(outputHashes)),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }
}

contract ForkAdapterFactory {
    mapping(address adapter => bool status) public isEntity;

    function setEntity(address adapter, bool status) public {
        isEntity[adapter] = status;
    }
}

contract ForkMockAdapter is IInstantRedemptionAdapter {
    mapping(address vault => mapping(address token => address account)) internal _accounts;

    function setAccount(address vault, address token, address account) public {
        _accounts[vault][token] = account;
    }

    function getAccount(address vault, address token) public view returns (address account) {
        return _accounts[vault][token];
    }

    function swap(IInstantRedemptionAdapter.Swap calldata swap_) public {
        _sendToAccount(swap_.vault, swap_.tokenIn, swap_.amountIn);
    }

    function swap(IInstantRedemptionAdapter.SignedSwap calldata signedSwap, bytes calldata) public {
        _sendToAccount(signedSwap.vault, signedSwap.tokenIn, signedSwap.amountIn);
    }

    function swap(
        IInstantRedemptionAdapter.DiscountSwap calldata discountSwap,
        bytes calldata,
        address,
        uint256 amountIn,
        uint256
    ) public {
        _sendToAccount(discountSwap.discount.vault, discountSwap.discount.tokenToRedeem, amountIn);
    }

    function _sendToAccount(address vault, address token, uint256 amount) internal {
        address account = _accounts[vault][token];
        require(account != address(0) && IERC20(token).balanceOf(address(this)) >= amount, "missing rwa");
        IERC20(token).transfer(account, amount);
    }
}
