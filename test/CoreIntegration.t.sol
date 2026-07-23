// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Executor} from "../src/Executor.sol";
import {Reactor} from "../src/Reactor.sol";
import {IExecutor} from "../src/interfaces/IExecutor.sol";
import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneAdapter,
    SIGNED_SWAP_TYPEHASH
} from "../src/interfaces/ILiquidLaneAdapter.sol";
import {IReactor, ORDER_TYPEHASH, OUTPUT_TYPEHASH, REQUEST_TYPEHASH} from "../src/interfaces/IReactor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Test} from "forge-std/Test.sol";

contract LiquidLaneIntegrationTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant PROTOCOL_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant SWAPPER_PRIVATE_KEY = 0xBEEF;

    address internal filler = makeAddr("filler");
    address internal primaryAccount = makeAddr("primaryAccount");
    address internal protocol = vm.addr(PROTOCOL_PRIVATE_KEY);
    address internal secondaryAccount = makeAddr("secondaryAccount");
    address internal swapper = vm.addr(SWAPPER_PRIVATE_KEY);

    IntegrationAdapterFactory internal adapterFactory;
    LiquidLaneAdapterMock internal adapter;
    Executor internal executor;
    IntegrationERC20 internal outputToken;
    Reactor internal reactor;
    IntegrationERC20 internal rwa;
    LiquidLaneAdapterMock internal secondaryAdapter;

    function setUp() public {
        adapter = new LiquidLaneAdapterMock();
        secondaryAdapter = new LiquidLaneAdapterMock();
        adapterFactory = new IntegrationAdapterFactory();
        adapterFactory.setEntity(address(adapter), true);
        adapterFactory.setEntity(address(secondaryAdapter), true);
        reactor = new Reactor(address(adapterFactory));
        executor = new Executor(address(reactor), address(this), _callers(filler));

        rwa = new IntegrationERC20("RWA", "RWA");
        outputToken = new IntegrationERC20("USD", "USD");

        adapter.setAccount(address(rwa), primaryAccount);
        secondaryAdapter.setAccount(address(rwa), secondaryAccount);

        rwa.mint(swapper, 100 ether);
        vm.prank(swapper);
        rwa.approve(address(reactor), type(uint256).max);
    }

    function testLiquidLaneConstantsMatchCoreSchema() public pure {
        assertEq(DISCOUNT_PRECISION, 1_000_000);
        assertEq(
            SIGNED_SWAP_TYPEHASH,
            keccak256(
                "SignedSwap(address recipient,address tokenIn,uint256 amountIn,uint256 amountOut,address caller,address signer,uint256 nonce,uint48 deadline)"
            )
        );
        assertEq(
            DISCOUNT_TYPEHASH,
            keccak256(
                "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
            )
        );
        assertEq(
            DISCOUNT_SWAP_TYPEHASH,
            keccak256(
                "DiscountSwap(Discount discount,bytes signerSignature,uint48 protocolDeadline)"
                "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
            )
        );
    }

    function testLocalStructsExposeLiquidLaneFields() public view {
        ILiquidLaneAdapter.Swap memory swap = _swap(11 ether, 10 ether);
        ILiquidLaneAdapter.SignedSwap memory signedSwap = ILiquidLaneAdapter.SignedSwap({
            recipient: filler,
            tokenIn: address(rwa),
            amountIn: 11 ether,
            amountOut: 10 ether,
            caller: address(executor),
            signer: protocol,
            nonce: 77,
            deadline: uint48(block.timestamp + 1 days)
        });
        ILiquidLaneAdapter.Discount memory discount = _discount();
        ILiquidLaneAdapter.DiscountSwap memory discountSwap = ILiquidLaneAdapter.DiscountSwap({
            discount: discount, signerSignature: hex"1234", protocolDeadline: uint48(block.timestamp + 90)
        });

        assertEq(swap.recipient, filler);
        assertEq(swap.tokenIn, address(rwa));
        assertEq(swap.amountIn, 11 ether);
        assertEq(swap.amountOut, 10 ether);
        assertEq(signedSwap.caller, address(executor));
        assertEq(signedSwap.signer, protocol);
        assertEq(signedSwap.deadline, uint48(block.timestamp + 1 days));
        assertEq(discount.tokenToRedeem, address(rwa));
        assertEq(discount.signer, protocol);
        assertEq(discount.protocol, protocol);
        assertEq(discountSwap.discount.nonce, 2);
        assertEq(discountSwap.signerSignature, hex"1234");
        assertEq(discountSwap.protocolDeadline, uint48(block.timestamp + 90));
    }

    function testLiquidLaneAdapterHandlesDirectSwapFill() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(address(adapter), 5 ether, 5 ether);
        IReactor.Order memory order = _order(outputs, 5 ether);

        vm.prank(filler);
        executor.fill(order, _signOrder(order), swap, abi.encode(calls));

        assertEq(rwa.balanceOf(primaryAccount), 5 ether);
        assertEq(outputToken.balanceOf(swapper), 5 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.discountSwapCount(), 0);
        assertEq(adapter.lastRecipient(), filler);
        assertEq(adapter.lastAmountOut(), 5 ether);
    }

    function testLiquidLaneAdapterHandlesMixedDirectAndDiscountSwapFill() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 10 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](1);
        swapInputs[0] = _swapInput(address(adapter), 4 ether, 4 ether);

        IReactor.DiscountSwapInput[] memory discountSwapInputs = new IReactor.DiscountSwapInput[](1);
        discountSwapInputs[0] = _discountSwapInput(address(secondaryAdapter), 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);

        vm.prank(filler);
        executor.fill(order, _signOrder(order), swapInputs, discountSwapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(primaryAccount), 4 ether);
        assertEq(rwa.balanceOf(secondaryAccount), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(secondaryAdapter.discountSwapCount(), 1);
        assertEq(secondaryAdapter.lastRecipient(), filler);
        assertEq(secondaryAdapter.lastAmountOut(), 6 ether);
    }

    function testLiquidLaneAdapterHandlesLocalSignedSwapSelector() public {
        rwa.mint(address(adapter), 3 ether);

        ILiquidLaneAdapter.SignedSwap memory signedSwap = ILiquidLaneAdapter.SignedSwap({
            recipient: filler,
            tokenIn: address(rwa),
            amountIn: 3 ether,
            amountOut: 3 ether,
            caller: address(executor),
            signer: protocol,
            nonce: 101,
            deadline: uint48(block.timestamp + 1 days)
        });

        ILiquidLaneAdapter(address(adapter)).swap(signedSwap, hex"c0de");

        assertEq(rwa.balanceOf(primaryAccount), 3 ether);
        assertEq(adapter.signedSwapCount(), 1);
        assertEq(adapter.lastRecipient(), filler);
        assertEq(adapter.lastAmountOut(), 3 ether);
    }

    function _callers(address caller) internal pure returns (address[] memory callers_) {
        callers_ = new address[](1);
        callers_[0] = caller;
    }

    function _order(IReactor.Output[] memory outputs, uint256 amountIn) internal view returns (IReactor.Order memory) {
        IReactor.Request memory request = IReactor.Request({
            tokenIn: address(rwa),
            amountIn: amountIn,
            outputs: outputs,
            deadline: block.timestamp + 1 days,
            nonce: 1,
            protocol: protocol
        });
        return IReactor.Order({
            request: request,
            swapperSignature: _signRequest(request),
            swapper: swapper,
            filler: address(executor),
            outputs: _copyOutputs(outputs)
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

    function _signRequest(IReactor.Request memory request) internal view returns (bytes memory) {
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
                _hashRequest(request)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SWAPPER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashOrder(IReactor.Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _hashRequest(order.request),
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler,
                _hashOutputs(order.outputs)
            )
        );
    }

    function _hashRequest(IReactor.Request memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                _hashOutputs(request.outputs),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }

    function _hashOutputs(IReactor.Output[] memory outputs) internal pure returns (bytes32 outputsHash) {
        bytes32[] memory outputHashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, outputs[i]));
        }
        outputsHash = keccak256(abi.encodePacked(outputHashes));
    }

    function _copyOutputs(IReactor.Output[] memory outputs)
        internal
        pure
        returns (IReactor.Output[] memory outputCopies)
    {
        outputCopies = new IReactor.Output[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            outputCopies[i] = outputs[i];
        }
    }

    function _swap(uint256 amountIn, uint256 amountOut) internal view returns (ILiquidLaneAdapter.Swap memory) {
        return
            ILiquidLaneAdapter.Swap({
                recipient: filler, tokenIn: address(rwa), amountIn: amountIn, amountOut: amountOut
            });
    }

    function _swapInput(address adapter_, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.SwapInput memory)
    {
        return IReactor.SwapInput({adapter: adapter_, swap: _swap(amountIn, amountOut)});
    }

    function _discount() internal view returns (ILiquidLaneAdapter.Discount memory) {
        return ILiquidLaneAdapter.Discount({
            tokenToRedeem: address(rwa),
            discount: 50_000,
            signer: protocol,
            protocol: protocol,
            nonce: 2,
            deadline: uint48(block.timestamp + 1 days)
        });
    }

    function _discountSwapInput(address adapter_, uint256 amountIn)
        internal
        view
        returns (IReactor.DiscountSwapInput memory)
    {
        return IReactor.DiscountSwapInput({
            adapter: adapter_,
            discountSwap: ILiquidLaneAdapter.DiscountSwap({
                discount: _discount(), signerSignature: hex"1234", protocolDeadline: uint48(block.timestamp + 90)
            }),
            protocolSignature: hex"5678",
            recipient: filler,
            amountIn: amountIn
        });
    }
}

contract IntegrationAdapterFactory {
    mapping(address adapter => bool status) public isEntity;

    function setEntity(address adapter, bool status) public {
        isEntity[adapter] = status;
    }
}

contract LiquidLaneAdapterMock is ILiquidLaneAdapter {
    mapping(address token => address account) internal _accounts;
    uint256 public discountSwapCount;
    uint256 public signedSwapCount;
    uint256 public swapCount;
    address public lastRecipient;
    uint256 public lastAmountOut;

    function setAccount(address token, address account) public {
        _accounts[token] = account;
    }

    function swap(ILiquidLaneAdapter.Swap calldata swap_) public {
        _transferToAccount(swap_.tokenIn, swap_.amountIn);
        lastRecipient = swap_.recipient;
        lastAmountOut = swap_.amountOut;
        ++swapCount;
    }

    function swap(ILiquidLaneAdapter.SignedSwap calldata signedSwap, bytes calldata) public {
        _transferToAccount(signedSwap.tokenIn, signedSwap.amountIn);
        lastRecipient = signedSwap.recipient;
        lastAmountOut = signedSwap.amountOut;
        ++signedSwapCount;
    }

    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata,
        address recipient,
        uint256 amountIn
    ) public returns (uint256 amountOut) {
        _transferToAccount(discountSwap.discount.tokenToRedeem, amountIn);
        lastRecipient = recipient;
        lastAmountOut = amountIn;
        ++discountSwapCount;
        return amountIn;
    }

    function _transferToAccount(address token, uint256 amount) internal {
        address account = _accounts[token];
        require(account != address(0), "missing account");
        require(IERC20(token).balanceOf(address(this)) >= amount, "missing rwa");
        IERC20(token).transfer(account, amount);
    }
}

contract IntegrationERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
