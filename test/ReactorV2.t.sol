// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.36;

import {ReactorV2} from "src/ReactorV2.sol";
import {DeployReactorV2Script} from "script/deploy/DeployReactorV2.s.sol";
import {IReactorV2} from "src/interfaces/IReactorV2.sol";
import {IReactorV2Callback} from "src/interfaces/IReactorV2Callback.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Test} from "forge-std/Test.sol";

contract ReactorV2Test is Test, DeployPermit2 {
    // Public, deterministic test-only keys; never used for deployment.
    uint256 internal constant SWAPPER_KEY = 0xBEEF;
    uint256 internal constant PROTOCOL_KEY = 0xA11CE;
    string internal constant OUTPUT_TYPE = "Output(address token,uint256 amount,address recipient)";
    string internal constant REQUEST_TYPE =
        "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)";
    string internal constant ORDER_TYPE =
        "Order(Request request,bytes swapperSignature,address swapper,address filler,address adapter,Output[] outputs)";
    string internal constant PERMIT_TYPE =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Request witness)";

    struct PermitWitness {
        ISignatureTransfer.TokenPermissions permitted;
        address spender;
        uint256 nonce;
        uint256 deadline;
        IReactorV2.Request witness;
    }

    ISignatureTransfer internal permit2;
    ReactorV2 internal reactor;
    ReactorV2Filler internal filler;
    ReactorV2Registry internal adapterFactory;
    ReactorV2Registry internal connectorFactory;
    ReactorV2Token internal rwa;
    ReactorV2Token internal usd;
    address internal swapper;
    address internal protocol;
    address internal adapter;
    address internal connector;
    address internal referrer;

    function setUp() public {
        vm.warp(1_800_000_000);
        permit2 = ISignatureTransfer(deployPermit2());
        adapterFactory = new ReactorV2Registry();
        connectorFactory = new ReactorV2Registry();
        // Destination code is immaterial to Reactor; the factory establishes eligibility.
        adapter = address(new ReactorV2Destination());
        connector = address(new ReactorV2Destination());
        adapterFactory.setEntity(adapter, true);
        connectorFactory.setEntity(connector, true);
        reactor = new ReactorV2(address(permit2), address(adapterFactory), address(connectorFactory));
        filler = new ReactorV2Filler(reactor);
        rwa = new ReactorV2Token();
        usd = new ReactorV2Token();
        swapper = vm.addr(SWAPPER_KEY);
        protocol = vm.addr(PROTOCOL_KEY);
        referrer = makeAddr("referrer");
        rwa.mint(swapper, 100 ether);
        usd.mint(address(filler), 100 ether);
        vm.prank(swapper);
        rwa.approve(address(permit2), type(uint256).max);
    }

    function testFillFundsOneAdapterThroughPermit2AndPaysOutputs() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        _fill(order);

        assertEq(rwa.balanceOf(adapter), 10 ether);
        assertEq(rwa.balanceOf(connector), 0);
        assertEq(rwa.balanceOf(swapper), 90 ether);
        assertEq(rwa.balanceOf(address(reactor)), 0);
        assertEq(rwa.balanceOf(address(filler)), 0);
        assertEq(rwa.allowance(swapper, address(reactor)), 0);
        assertEq(usd.balanceOf(swapper), 9 ether);
        assertEq(usd.balanceOf(referrer), 1 ether);
        assertTrue(reactor.isUsedNonce(swapper, 7));
        assertEq(filler.callbackCount(), 1);
    }

    function testDeploymentScriptWiresBothSettlementRoutes() public {
        reactor = new DeployReactorV2Script().run(address(permit2), address(adapterFactory), address(connectorFactory));
        filler = new ReactorV2Filler(reactor);
        usd.mint(address(filler), 100 ether);
        _fill(_order(adapter, 10 ether, 7));
        _fill(_order(connector, 10 ether, 8));
        assertEq(rwa.balanceOf(adapter), 10 ether);
        assertEq(rwa.balanceOf(connector), 10 ether);
        assertEq(usd.balanceOf(swapper), 18 ether);
        assertTrue(reactor.isUsedNonce(swapper, 7));
        assertTrue(reactor.isUsedNonce(swapper, 8));
    }

    function testFillAcceptsConnectorFactoryEntity() public {
        _fill(_order(connector, 10 ether, 8));
        assertEq(rwa.balanceOf(connector), 10 ether);
        assertEq(rwa.balanceOf(adapter), 0);
        assertEq(usd.balanceOf(swapper), 9 ether);
    }

    function testFuzzSingleDestinationAndNonce(uint96 amount, uint256 nonce, bool useConnector) public {
        amount = uint96(bound(amount, 10, 100 ether));
        address destination = useConnector ? connector : adapter;
        _fill(_order(destination, amount, nonce));
        assertEq(rwa.balanceOf(destination), amount);
        assertEq(rwa.balanceOf(useConnector ? adapter : connector), 0);
        assertEq(rwa.balanceOf(swapper), 100 ether - amount);
        assertEq(usd.balanceOf(swapper) + usd.balanceOf(referrer), amount);
        assertTrue(reactor.isUsedNonce(swapper, nonce));
        assertEq(permit2.nonceBitmap(swapper, nonce >> 8), uint256(1) << uint8(nonce));
    }

    function testRejectsDestinationOutsideBothFactories() public {
        IReactorV2.Order memory order = _order(address(new ReactorV2Destination()), 10 ether, 7);
        bytes memory signature = _signOrder(order);
        vm.expectRevert(IReactorV2.ReactorV2__InvalidAdapter.selector);
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testRejectsWrongFiller() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        vm.expectRevert(IReactorV2.ReactorV2__InvalidFiller.selector);
        reactor.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testProtocolSignatureBindsDestination() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        order.adapter = connector;
        vm.expectRevert(IReactorV2.ReactorV2__InvalidProtocolSignature.selector);
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testWitnessBindsRequestEvenWithValidProtocolSignature() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.request.outputs[0].recipient = makeAddr("attacker");
        order.outputs[0].recipient = order.request.outputs[0].recipient;
        bytes memory signature = _signOrder(order);
        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testReplayReverts() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        _fill(order);
        bytes memory signature = _signOrder(order);
        vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
        filler.fill(order, signature, "");
        assertEq(rwa.balanceOf(adapter), 10 ether);
        assertEq(filler.callbackCount(), 1);
    }

    function testSwapperCancelsDirectlyInPermit2() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 513);
        vm.prank(swapper);
        permit2.invalidateUnorderedNonces(2, 2);
        assertTrue(reactor.isUsedNonce(swapper, 513));
        assertFalse(reactor.isUsedNonce(swapper, 512));
        bytes memory signature = _signOrder(order);
        vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
        filler.fill(order, signature, "");
        assertEq(rwa.balanceOf(swapper), 100 ether);
    }

    function testExpiryReverts() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        vm.warp(order.request.deadline + 1);
        vm.expectRevert(abi.encodeWithSignature("SignatureExpired(uint256)", order.request.deadline));
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testFillsAtExactDeadline() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        vm.warp(order.request.deadline);
        _fill(order);
        assertEq(rwa.balanceOf(adapter), 10 ether);
    }

    function testRejectsOutputBelowRequestedMinimum() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.outputs[0].amount--;
        bytes memory signature = _signOrder(order);
        vm.expectRevert(IReactorV2.ReactorV2__InvalidOutput.selector);
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testProtocolCanImproveOutputs() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.outputs[0].amount += 1 ether;
        _fill(order);
        assertEq(usd.balanceOf(swapper), 10 ether);
    }

    function testInsufficientOutputRollsBackInputAndNonce() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.outputs[0].amount = 101 ether;
        bytes memory signature = _signOrder(order);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(filler), 100 ether, 101 ether
            )
        );
        filler.fill(order, signature, "");
        _assertUnspent(order);
        assertEq(usd.balanceOf(swapper), 0);
        assertEq(filler.callbackCount(), 0);
    }

    function testCallbackRevertRollsBackInputAndNonce() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        bytes memory data = abi.encode(adapter, abi.encodeCall(ReactorV2Destination.fail, ()));
        vm.expectRevert(ReactorV2Destination.CallbackFailed.selector);
        filler.fill(order, signature, data);
        _assertUnspent(order);
    }

    function testCallbackRunsAfterInputFunding() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory data =
            abi.encode(adapter, abi.encodeCall(ReactorV2Destination.forward, (address(rwa), referrer, 10 ether)));
        filler.fill(order, _signOrder(order), data);
        assertEq(rwa.balanceOf(referrer), 10 ether);
        assertEq(rwa.balanceOf(adapter), 0);
    }

    function testNativeOutputAndSurplusRefund() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.request.outputs[0].token = address(0);
        order.outputs[0].token = address(0);
        order.swapperSignature = _signPermit(order.request, address(reactor), SWAPPER_KEY);
        vm.deal(address(filler), 10 ether);
        _fill(order);
        assertEq(swapper.balance, 9 ether);
        assertEq(address(filler).balance, 1 ether);
        assertEq(address(reactor).balance, 0);
        assertEq(usd.balanceOf(referrer), 1 ether);
    }

    function testNativeRecipientCannotReenterThroughFiller() public {
        ReactorV2NativeRecipient recipient = new ReactorV2NativeRecipient();
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.request.outputs[0] = IReactorV2.Output(address(0), 9 ether, address(recipient));
        order.outputs[0] = order.request.outputs[0];
        order.swapperSignature = _signPermit(order.request, address(reactor), SWAPPER_KEY);
        bytes memory signature = _signOrder(order);
        recipient.setReentry(address(filler), abi.encodeCall(filler.fill, (order, signature, bytes(""))));
        vm.deal(address(filler), 9 ether);

        filler.fill(order, signature, "");

        assertTrue(recipient.reentryBlocked());
        assertEq(address(recipient).balance, 9 ether);
        assertEq(rwa.balanceOf(adapter), 10 ether);
        assertEq(usd.balanceOf(referrer), 1 ether);
        assertEq(filler.callbackCount(), 1);
    }

    function testNativeRefundCannotReenter() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        filler.setRefundReentry(abi.encodeCall(reactor.fill, (order, signature, bytes(""))));
        vm.deal(address(filler), 1 ether);

        filler.fill(order, signature, "");

        assertTrue(filler.refundReentryBlocked());
        assertEq(address(filler).balance, 1 ether);
        assertEq(address(reactor).balance, 0);
        assertEq(rwa.balanceOf(adapter), 10 ether);
        assertEq(filler.callbackCount(), 1);
    }

    function testContractSwapperAndProtocolSignatures() public {
        ReactorV2Wallet swapperWallet = new ReactorV2Wallet(swapper);
        ReactorV2Wallet protocolWallet = new ReactorV2Wallet(protocol);
        rwa.mint(address(swapperWallet), 100 ether);
        swapperWallet.approve(address(rwa), address(permit2));
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.swapper = address(swapperWallet);
        order.request.protocol = address(protocolWallet);
        order.swapperSignature = _signPermit(order.request, address(reactor), SWAPPER_KEY);
        _fill(order);
        assertEq(rwa.balanceOf(address(swapperWallet)), 90 ether);
        assertTrue(reactor.isUsedNonce(address(swapperWallet), 7));
    }

    function testRejectsReentrantFillFromCallback() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        bytes memory data = abi.encode(address(reactor), abi.encodeCall(reactor.fill, (order, signature, bytes(""))));
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        filler.fill(order, signature, data);
        _assertUnspent(order);
    }

    function testFuzzRejectsMissingDependency(uint8 dependency) public {
        dependency = uint8(bound(dependency, 0, 2));
        address[] memory dependencies = new address[](3);
        dependencies[0] = address(permit2);
        dependencies[1] = address(adapterFactory);
        dependencies[2] = address(connectorFactory);
        dependencies[dependency] = makeAddr("not a contract");
        vm.expectRevert(IReactorV2.ReactorV2__InvalidConfiguration.selector);
        new ReactorV2(dependencies[0], dependencies[1], dependencies[2]);
    }

    function testFuzzWitnessBindsEveryRequestField(uint8 field) public {
        field = uint8(bound(field, 0, 7));
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        if (field == 0) {
            order.request.tokenIn = address(usd);
        } else if (field == 1) {
            order.request.amountIn++;
        } else if (field == 2) {
            order.request.outputs[0].token = address(rwa);
            order.outputs[0].token = address(rwa);
        } else if (field == 3) {
            order.request.outputs[0].amount--;
        } else if (field == 4) {
            order.request.outputs[0].recipient = referrer;
            order.outputs[0].recipient = referrer;
        } else if (field == 5) {
            order.request.deadline++;
        } else if (field == 6) {
            order.request.nonce++;
        } else {
            order.request.protocol = address(new ReactorV2Wallet(protocol));
        }
        bytes memory signature = _signOrder(order);
        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testFuzzRejectsChangedOutputObligations(uint8 field) public {
        field = uint8(bound(field, 0, 2));
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        if (field == 0) order.outputs = new IReactorV2.Output[](0);
        else if (field == 1) order.outputs[0].token = address(rwa);
        else order.outputs[0].recipient = referrer;
        bytes memory signature = _signOrder(order);
        vm.expectRevert(IReactorV2.ReactorV2__InvalidOutput.selector);
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testPermitSignatureBindsReactorSpender() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.swapperSignature = _signPermit(order.request, address(filler), SWAPPER_KEY);
        bytes memory signature = _signOrder(order);
        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testPermitSignatureBindsChain() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        vm.chainId(block.chainid + 1);
        bytes memory signature = _signOrder(order);
        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testProtocolSignatureBindsFinalOutputs() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        bytes memory signature = _signOrder(order);
        order.outputs[0].amount++;
        vm.expectRevert(IReactorV2.ReactorV2__InvalidProtocolSignature.selector);
        filler.fill(order, signature, "");
        _assertUnspent(order);
    }

    function testLaterOutputFailureRollsBackEarlierPayments() public {
        IReactorV2.Order memory order = _order(adapter, 10 ether, 7);
        order.outputs[1].amount = 100 ether;
        bytes memory signature = _signOrder(order);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(filler), 91 ether, 100 ether
            )
        );
        filler.fill(order, signature, "");
        _assertUnspent(order);
        assertEq(usd.balanceOf(swapper), 0);
        assertEq(usd.balanceOf(referrer), 0);
    }

    function _order(address destination, uint256 amount, uint256 nonce)
        internal
        view
        returns (IReactorV2.Order memory order)
    {
        IReactorV2.Output[] memory outputs = new IReactorV2.Output[](2);
        outputs[0] = IReactorV2.Output(address(usd), amount - amount / 10, swapper);
        outputs[1] = IReactorV2.Output(address(usd), amount / 10, referrer);
        order.request = IReactorV2.Request(address(rwa), amount, outputs, block.timestamp + 1 hours, nonce, protocol);
        order.swapperSignature = _signPermit(order.request, address(reactor), SWAPPER_KEY);
        order.swapper = swapper;
        order.filler = address(filler);
        order.adapter = destination;
        // Independent arrays: changing an order must not silently change the signed request in tests.
        order.outputs = abi.decode(abi.encode(outputs), (IReactorV2.Output[]));
    }

    function _fill(IReactorV2.Order memory order) internal {
        filler.fill(order, _signOrder(order), "");
    }

    function _assertUnspent(IReactorV2.Order memory order) internal view {
        assertEq(rwa.balanceOf(swapper), 100 ether);
        assertEq(rwa.balanceOf(order.adapter), 0);
        assertFalse(reactor.isUsedNonce(swapper, order.request.nonce));
    }

    function _signOrder(IReactorV2.Order memory order) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Reactor"),
                keccak256("2"),
                block.chainid,
                address(reactor)
            )
        );
        // Foundry's independent EIP-712 encoder handles nested structs and arrays.
        bytes32 structHash =
            vm.eip712HashStruct(string.concat(ORDER_TYPE, OUTPUT_TYPE, REQUEST_TYPE), abi.encode(order));
        return _sign(PROTOCOL_KEY, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
    }

    function _signPermit(IReactorV2.Request memory request, address spender, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        PermitWitness memory witness = PermitWitness({
            permitted: ISignatureTransfer.TokenPermissions(request.tokenIn, request.amountIn),
            spender: spender,
            nonce: request.nonce,
            deadline: request.deadline,
            witness: request
        });
        bytes32 structHash = vm.eip712HashStruct(
            string.concat(PERMIT_TYPE, OUTPUT_TYPE, REQUEST_TYPE, "TokenPermissions(address token,uint256 amount)"),
            abi.encode(witness)
        );
        return _sign(key, keccak256(abi.encodePacked(hex"1901", permit2.DOMAIN_SEPARATOR(), structHash)));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract ReactorV2Token is ERC20 {
    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReactorV2Registry {
    mapping(address => bool) public isEntity;

    function setEntity(address entity, bool registered) external {
        isEntity[entity] = registered;
    }
}

contract ReactorV2Destination {
    error CallbackFailed();

    function fail() external pure {
        revert CallbackFailed();
    }

    function forward(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

contract ReactorV2Filler is IReactorV2Callback {
    using SafeERC20 for IERC20;
    ReactorV2 internal immutable reactor;
    uint256 public callbackCount;
    bytes internal refundReentry;
    bool public refundReentryBlocked;

    constructor(ReactorV2 reactor_) {
        reactor = reactor_;
    }

    function fill(IReactorV2.Order calldata order, bytes calldata signature, bytes calldata data) external {
        reactor.fill(order, signature, data);
    }

    function setRefundReentry(bytes calldata payload) external {
        refundReentry = payload;
    }

    function reactorCallback(IReactorV2.Order calldata order, bytes calldata data) external {
        require(msg.sender == address(reactor), "not reactor");
        callbackCount++;
        if (data.length != 0) {
            (address target, bytes memory payload) = abi.decode(data, (address, bytes));
            (bool success, bytes memory result) = target.call(payload);
            if (!success) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
        for (uint256 i; i < order.outputs.length; ++i) {
            if (order.outputs[i].token != address(0)) {
                IERC20(order.outputs[i].token).forceApprove(msg.sender, type(uint256).max);
            }
        }
        if (address(this).balance != 0) {
            (bool success,) = msg.sender.call{value: address(this).balance}("");
            require(success, "native transfer failed");
        }
    }

    receive() external payable {
        if (refundReentry.length != 0) {
            (bool success, bytes memory result) = address(reactor).call(refundReentry);
            refundReentryBlocked = !success && bytes4(result) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        }
    }
}

contract ReactorV2NativeRecipient {
    address internal target;
    bytes internal reentry;
    bool public reentryBlocked;

    function setReentry(address target_, bytes calldata payload) external {
        target = target_;
        reentry = payload;
    }

    receive() external payable {
        (bool success, bytes memory result) = target.call(reentry);
        reentryBlocked = !success && bytes4(result) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    }
}

contract ReactorV2Wallet {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function approve(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
