// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Executor} from "@symbioticfi/reactor/Executor.sol";
import {Reactor} from "@symbioticfi/reactor/Reactor.sol";
import {CALLER_ROLE} from "@symbioticfi/reactor/interfaces/IExecutor.sol";

import {AdapterRegistry} from "@symbioticfi/core/src/contracts/AdapterRegistry.sol";
import {DelegatorFactory} from "@symbioticfi/core/src/contracts/DelegatorFactory.sol";
import {OperatorRegistry} from "@symbioticfi/core/src/contracts/OperatorRegistry.sol";
import {NetworkMiddlewareService} from "@symbioticfi/core/src/contracts/service/NetworkMiddlewareService.sol";
import {OptInService} from "@symbioticfi/core/src/contracts/service/OptInService.sol";
import {NetworkRegistry} from "@symbioticfi/core/src/contracts/NetworkRegistry.sol";
import {SlasherFactory} from "@symbioticfi/core/src/contracts/SlasherFactory.sol";
import {VaultConfigurator} from "@symbioticfi/core/src/contracts/VaultConfigurator.sol";
import {VaultFactory} from "@symbioticfi/core/src/contracts/VaultFactory.sol";
import {FullRestakeDelegator} from "@symbioticfi/core/src/contracts/delegator/FullRestakeDelegator.sol";
import {NetworkRestakeDelegator} from "@symbioticfi/core/src/contracts/delegator/NetworkRestakeDelegator.sol";
import {OperatorNetworkSpecificDelegator} from "@symbioticfi/core/src/contracts/delegator/OperatorNetworkSpecificDelegator.sol";
import {OperatorSpecificDelegator} from "@symbioticfi/core/src/contracts/delegator/OperatorSpecificDelegator.sol";
import {UniversalDelegator} from "@symbioticfi/core/src/contracts/delegator/UniversalDelegator.sol";
import {Slasher} from "@symbioticfi/core/src/contracts/slasher/Slasher.sol";
import {UniversalSlasher} from "@symbioticfi/core/src/contracts/slasher/UniversalSlasher.sol";
import {VetoSlasher} from "@symbioticfi/core/src/contracts/slasher/VetoSlasher.sol";
import {Vault} from "@symbioticfi/core/src/contracts/vault/Vault.sol";
import {VaultV2} from "@symbioticfi/core/src/contracts/vault/VaultV2.sol";
import {VaultTokenized} from "@symbioticfi/core/src/contracts/vault/VaultTokenized.sol";
import {AaveV3Adapter} from "@symbioticfi/core/src/contracts/vault/adapters/AaveV3Adapter.sol";
import {InstantRedemptionAdapter} from "@symbioticfi/core/src/contracts/vault/adapters/InstantRedemptionAdapter.sol";
import {MorphoVaultV2Adapter} from "@symbioticfi/core/src/contracts/vault/adapters/MorphoVaultV2Adapter.sol";
import {ChainlinkOracle} from "@symbioticfi/core/src/contracts/vault/adapters/ir_adapter/oracles/ChainlinkOracle.sol";

import {IVaultConfigurator} from "@symbioticfi/core/src/interfaces/IVaultConfigurator.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {IUniversalSlasher} from "@symbioticfi/core/src/interfaces/slasher/IUniversalSlasher.sol";
import {ICuratorRegistry} from "@symbioticfi/core/src/interfaces/vault/adapters/ICuratorRegistry.sol";
import {UNIVERSAL_DELEGATOR_TYPE} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {UNIVERSAL_SLASHER_TYPE} from "@symbioticfi/core/src/interfaces/slasher/IUniversalSlasher.sol";

import {
    ImmediateSettlementAccount,
    MockAaveAToken,
    MockAavePool,
    MockMorphoVaultFactory,
    MockMorphoVaultV2,
    LocalAggregatorV3,
    LocalMintableERC20,
    LocalSwapRouter
} from "./mocks/LocalRfqMocks.sol";

interface ICuratorRegistryInitializer {
    function initialize() external;
}

interface IFeeRegistryInitializer {
    function initialize(address owner) external;
}

interface IRewardsInitializer {
    function initialize(address owner) external;
}

/// @notice Deploys the local or Hoodi RFQ stack using real protocol contracts wherever possible.
contract DeployRfqStack is Script {
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant CURATOR_REGISTRY_ARTIFACT =
        "lib/rewards-v2-mirror.git/out/CuratorRegistry.sol/CuratorRegistry.json";
    string internal constant FEE_REGISTRY_ARTIFACT = "lib/rewards-v2-mirror.git/out/FeeRegistry.sol/FeeRegistry.json";
    string internal constant REWARDS_ARTIFACT = "lib/rewards-v2-mirror.git/out/Rewards.sol/Rewards.json";
    string internal constant BURNER_ROUTER_ARTIFACT = "lib/burners/out/BurnerRouter.sol/BurnerRouter.json";
    string internal constant BURNER_ROUTER_FACTORY_ARTIFACT =
        "lib/burners/out/BurnerRouterFactory.sol/BurnerRouterFactory.json";

    uint256 internal constant DEFAULT_DEPLOYER_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant DEFAULT_PROTOCOL_SIGNER_PRIVATE_KEY =
        0x59c6995e998f97a5a0044966f09453816aaf9b34d9ccf5a9da9b8d0d4f3b3c9f;
    uint256 internal constant DEFAULT_FILLER_CALLER_PRIVATE_KEY =
        0x5de4111afa1a4b94908f83103e8d6eaf95b78f3046c8c4b7aa90bf34e66b4a79;

    uint48 internal constant DEFAULT_EPOCH_DURATION = 7 days;
    uint48 internal constant ORACLE_STALENESS_DURATION = 365 days;
    uint256 internal constant USDC_VAULT_CAPACITY = 750_000 ether;
    uint256 internal constant AUSD_VAULT_CAPACITY = 500_000 ether;
    uint256 internal constant DEFAULT_MORPHO_ALLOCATION_BPS = 2500;
    uint256 internal constant DEFAULT_AAVE_ALLOCATION_BPS = 2500;
    int256 internal constant ACRED_CHAINLINK_ANSWER = 109_054_000_000;
    int256 internal constant MFONE_CHAINLINK_ANSWER = 107_000_000;
    int256 internal constant COLLATERAL_CHAINLINK_ANSWER = 100_000_000;
    uint256 internal constant AUSD_VAULT_DISCOUNT = 41_667;
    string internal constant ERR_COLLATERAL_ADAPTER_AUTH = "Collateral adapter authorization failed";
    string internal constant ERR_COLLATERAL_ROUTER_AUTH = "Collateral router authorization failed";
    string internal constant ERR_INPUT_ROUTER_AUTH = "Input router authorization failed";

    function _protocolRoot() internal view returns (string memory) {
        return vm.envOr("SYMBIOTIC_PROTOCOL_DIR", vm.projectRoot());
    }

    function _deploymentsRoot() internal view returns (string memory) {
        return vm.envOr("INTEGRATION_DEPLOYMENTS_DIR", string.concat(vm.projectRoot(), "/deployments"));
    }

    function _protocolArtifactPath(string memory relativePath) internal view returns (string memory) {
        return string.concat(_protocolRoot(), "/", relativePath);
    }

    struct DeploymentContext {
        string environment;
        uint256 chainId;
        string chainName;
        string rpcUrl;
        bool testnet;
        uint256 deployerPrivateKey;
        uint256 protocolSignerPrivateKey;
        uint256 fillerCallerPrivateKey;
    }

    struct CoreArtifacts {
        address vaultFactory;
        address delegatorFactory;
        address slasherFactory;
        address operatorRegistry;
        address networkRegistry;
        address networkMiddlewareService;
        address operatorVaultOptInService;
        address operatorNetworkOptInService;
        address adapterRegistry;
        address curatorRegistry;
        address feeRegistry;
        address rewards;
        address vaultConfigurator;
        uint64 universalDelegatorIndex;
        uint64 universalSlasherIndex;
    }

    struct DeploymentArtifacts {
        address acredit;
        address mfone;
        address usdc;
        address ausd;
        address permit2;
        address adapter;
        address morphoAdapter;
        address aaveAdapter;
        address reactor;
        address executor;
        address router;
        address burnerRouterFactory;
        address morphoVaultFactory;
        address usdcMorphoVault;
        address ausdMorphoVault;
        address aavePool;
        address usdcAToken;
        address ausdAToken;
        address usdcVault;
        address ausdVault;
        CoreArtifacts core;
    }

    struct YieldArtifacts {
        address morphoVaultFactory;
        address usdcMorphoVault;
        address ausdMorphoVault;
        address morphoAdapter;
        address aavePool;
        address usdcAToken;
        address ausdAToken;
        address aaveAdapter;
    }

    struct LocalAssetArtifacts {
        address acredit;
        address mfone;
        address usdc;
        address ausd;
        address acreditOracle;
        address mfoneOracle;
        address usdcOracle;
        address ausdOracle;
    }

    struct RewardsArtifacts {
        address curatorRegistry;
        address feeRegistry;
        address rewards;
    }

    struct CoreBaseArtifacts {
        address vaultFactory;
        address delegatorFactory;
        address slasherFactory;
        address operatorRegistry;
        address networkRegistry;
        address networkMiddlewareService;
        address operatorVaultOptInService;
        address operatorNetworkOptInService;
        address adapterRegistry;
    }

    struct MorphoYieldArtifacts {
        address morphoVaultFactory;
        address usdcMorphoVault;
        address ausdMorphoVault;
        address morphoAdapter;
    }

    struct AaveYieldArtifacts {
        address aavePool;
        address usdcAToken;
        address ausdAToken;
        address aaveAdapter;
    }

    struct ProtocolOwnedArtifacts {
        address adapter;
        address reactor;
        address executor;
        address router;
        address burnerRouterFactory;
    }

    struct VaultPairArtifacts {
        address usdcVault;
        address ausdVault;
    }

    /// @notice Deploys the RFQ stack and writes the deployment manifest.
    function run() external {
        DeploymentContext memory context = _deploymentContext();
        address deployer = vm.addr(context.deployerPrivateKey);
        address protocolSigner = vm.addr(context.protocolSignerPrivateKey);
        address fillerCaller = vm.addr(context.fillerCallerPrivateKey);

        vm.startBroadcast(context.deployerPrivateKey);

        DeploymentArtifacts memory artifacts = _deployArtifacts(deployer, fillerCaller);
        _configureArtifacts(artifacts, deployer);
        _fundArtifacts(artifacts, deployer, fillerCaller);

        vm.stopBroadcast();

        _writeManifest(context, protocolSigner, fillerCaller, deployer, artifacts);
    }

    /// @dev Builds the deployment context from the chain id and env overrides.
    /// @return context The deployment context.
    function _deploymentContext() internal view returns (DeploymentContext memory context) {
        string memory environment = vm.envOr("RFQ_DEPLOYMENT_ENV", string("local"));
        uint256 chainId = block.chainid;
        string memory rpcUrl = vm.envOr("RFQ_DEPLOYMENT_RPC_URL", string("http://127.0.0.1:8545"));
        bool testnet = chainId != 1;
        string memory chainName =
            chainId == 1 ? "Ethereum" : chainId == 31_337 ? "Anvil" : chainId == 560_048 ? "Hoodi" : "Chain";

        context = DeploymentContext({
            environment: environment,
            chainId: chainId,
            chainName: chainName,
            rpcUrl: rpcUrl,
            testnet: testnet,
            deployerPrivateKey: vm.envOr("RFQ_DEPLOYER_PRIVATE_KEY", DEFAULT_DEPLOYER_PRIVATE_KEY),
            protocolSignerPrivateKey: vm.envOr("RFQ_PROTOCOL_SIGNER_PRIVATE_KEY", DEFAULT_PROTOCOL_SIGNER_PRIVATE_KEY),
            fillerCallerPrivateKey: vm.envOr("RFQ_FILLER_CALLER_PRIVATE_KEY", DEFAULT_FILLER_CALLER_PRIVATE_KEY)
        });
    }

    /// @dev Deploys the real protocol stack plus the remaining local-only RFQ helpers.
    /// @param deployer The deployment owner.
    /// @param fillerCaller The address allowed to call the executor.
    /// @return artifacts The deployed artifacts.
    function _deployArtifacts(address deployer, address fillerCaller)
        internal
        returns (DeploymentArtifacts memory artifacts)
    {
        CoreArtifacts memory core = _deployCore(deployer);
        bool enableYieldAdapters = vm.envOr("RFQ_ENABLE_YIELD_ADAPTERS", block.chainid != 1);
        LocalAssetArtifacts memory localAssets = _deployLocalAssets(deployer);
        address permit2 = _resolvePermit2();
        ProtocolOwnedArtifacts memory protocol = _deployProtocolOwnedArtifacts(core, deployer, fillerCaller, permit2);
        YieldArtifacts memory yieldArtifacts;

        if (enableYieldAdapters) {
            yieldArtifacts = _deployYieldArtifacts(core, deployer, localAssets.usdc, localAssets.ausd);
            AdapterRegistry(core.adapterRegistry).whitelistAdapter(yieldArtifacts.morphoAdapter);
            AdapterRegistry(core.adapterRegistry).whitelistAdapter(yieldArtifacts.aaveAdapter);
        }

        _configureLocalAdapter(protocol.adapter, localAssets);
        VaultPairArtifacts memory vaults = _deployCollateralVaults(core, deployer, localAssets);

        artifacts = DeploymentArtifacts({
            acredit: localAssets.acredit,
            mfone: localAssets.mfone,
            usdc: localAssets.usdc,
            ausd: localAssets.ausd,
            permit2: permit2,
            adapter: protocol.adapter,
            morphoAdapter: yieldArtifacts.morphoAdapter,
            aaveAdapter: yieldArtifacts.aaveAdapter,
            reactor: protocol.reactor,
            executor: protocol.executor,
            router: protocol.router,
            burnerRouterFactory: protocol.burnerRouterFactory,
            morphoVaultFactory: yieldArtifacts.morphoVaultFactory,
            usdcMorphoVault: yieldArtifacts.usdcMorphoVault,
            ausdMorphoVault: yieldArtifacts.ausdMorphoVault,
            aavePool: yieldArtifacts.aavePool,
            usdcAToken: yieldArtifacts.usdcAToken,
            ausdAToken: yieldArtifacts.ausdAToken,
            usdcVault: vaults.usdcVault,
            ausdVault: vaults.ausdVault,
            core: core
        });
    }

    /// @dev Resolves the Permit2 address for the current environment.
    /// @return permit2 The Permit2 address.
    function _resolvePermit2() internal view returns (address permit2) {
        permit2 = vm.envOr("RFQ_PERMIT2_ADDRESS", CANONICAL_PERMIT2);

        if (permit2.code.length == 0) {
            revert("Permit2 code missing");
        }
    }

    /// @dev Deploys the reusable protocol-owned core contracts.
    /// @param deployer The deployment owner.
    /// @return core The deployed core artifacts.
    function _deployCore(address deployer) internal returns (CoreArtifacts memory core) {
        _buildRewardsArtifacts();
        CoreBaseArtifacts memory base = _deployCoreBase(deployer);
        RewardsArtifacts memory rewardsArtifacts = _deployRewardsArtifacts(
            VaultFactory(base.vaultFactory),
            NetworkRegistry(base.networkRegistry),
            NetworkMiddlewareService(base.networkMiddlewareService),
            deployer
        );

        VaultFactory vaultFactory = VaultFactory(base.vaultFactory);
        DelegatorFactory delegatorFactory = DelegatorFactory(base.delegatorFactory);
        SlasherFactory slasherFactory = SlasherFactory(base.slasherFactory);

        Vault vaultImplV1 = new Vault(base.delegatorFactory, base.slasherFactory, base.vaultFactory);
        vaultFactory.whitelist(address(vaultImplV1));

        VaultTokenized vaultTokenizedImpl =
            new VaultTokenized(base.delegatorFactory, base.slasherFactory, base.vaultFactory);
        vaultFactory.whitelist(address(vaultTokenizedImpl));

        VaultV2 vaultImpl = new VaultV2(
            base.delegatorFactory,
            base.slasherFactory,
            base.vaultFactory,
            rewardsArtifacts.feeRegistry,
            rewardsArtifacts.rewards,
            base.adapterRegistry
        );
        vaultFactory.whitelist(address(vaultImpl));

        uint64 universalDelegatorIndex = _deployDelegatorImplementations(base);
        uint64 universalSlasherIndex = _deploySlasherImplementations(base);

        VaultConfigurator vaultConfigurator =
            new VaultConfigurator(base.vaultFactory, base.delegatorFactory, base.slasherFactory);

        core = CoreArtifacts({
            vaultFactory: base.vaultFactory,
            delegatorFactory: base.delegatorFactory,
            slasherFactory: base.slasherFactory,
            operatorRegistry: base.operatorRegistry,
            networkRegistry: base.networkRegistry,
            networkMiddlewareService: base.networkMiddlewareService,
            operatorVaultOptInService: base.operatorVaultOptInService,
            operatorNetworkOptInService: base.operatorNetworkOptInService,
            adapterRegistry: base.adapterRegistry,
            curatorRegistry: rewardsArtifacts.curatorRegistry,
            feeRegistry: rewardsArtifacts.feeRegistry,
            rewards: rewardsArtifacts.rewards,
            vaultConfigurator: address(vaultConfigurator),
            universalDelegatorIndex: universalDelegatorIndex,
            universalSlasherIndex: universalSlasherIndex
        });
    }

    /// @dev Builds only the rewards artifacts, so the main RFQ deploy script does not need to import those
    ///      implementations directly and pull core contracts into the rewards profile.
    function _buildRewardsArtifacts() internal {
        string memory subproject = string.concat(_protocolRoot(), "/lib/rewards-v2-mirror.git");
        string[] memory command = new string[](3);
        command[0] = "zsh";
        command[1] = "-lc";
        command[2] = string.concat(
            "cd ",
            subproject,
            " && forge build --force src/contracts/CuratorRegistry.sol src/contracts/FeeRegistry.sol src/contracts/Rewards.sol --skip test script"
        );
        vm.ffi(command);
    }

    function _buildBurnersArtifacts() internal {
        string memory subproject = string.concat(_protocolRoot(), "/lib/burners");
        string[] memory command = new string[](3);
        command[0] = "zsh";
        command[1] = "-lc";
        command[2] = string.concat(
            "cd ",
            subproject,
            " && forge build --force src/contracts/router/BurnerRouter.sol src/contracts/router/BurnerRouterFactory.sol --skip test script"
        );
        vm.ffi(command);
    }

    /// @dev Deploys the local input/output assets and their mocked Chainlink-backed oracles.
    function _deployLocalAssets(address deployer) internal returns (LocalAssetArtifacts memory localAssets) {
        LocalMintableERC20 acredit = new LocalMintableERC20("Apollo Diversified Credit", "ACRED", 18, deployer);
        LocalMintableERC20 mfone = new LocalMintableERC20("Midas Fasanara ONE", "mF-ONE", 18, deployer);
        LocalMintableERC20 usdc = new LocalMintableERC20("USD Coin", "USDC", 18, deployer);
        LocalMintableERC20 ausd = new LocalMintableERC20("Anchored USD", "aUSD", 18, deployer);
        LocalAggregatorV3 acreditFeed = new LocalAggregatorV3(8, "ACRED / USD", ACRED_CHAINLINK_ANSWER, deployer);
        LocalAggregatorV3 mfoneFeed = new LocalAggregatorV3(8, "mF-ONE / USD", MFONE_CHAINLINK_ANSWER, deployer);
        LocalAggregatorV3 usdcFeed = new LocalAggregatorV3(8, "USDC / USD", COLLATERAL_CHAINLINK_ANSWER, deployer);
        LocalAggregatorV3 ausdFeed = new LocalAggregatorV3(8, "aUSD / USD", COLLATERAL_CHAINLINK_ANSWER, deployer);
        ChainlinkOracle acreditOracle =
            new ChainlinkOracle([address(acreditFeed), address(0)], [ORACLE_STALENESS_DURATION, 0]);
        ChainlinkOracle mfoneOracle =
            new ChainlinkOracle([address(mfoneFeed), address(0)], [ORACLE_STALENESS_DURATION, 0]);
        ChainlinkOracle usdcOracle =
            new ChainlinkOracle([address(usdcFeed), address(0)], [ORACLE_STALENESS_DURATION, 0]);
        ChainlinkOracle ausdOracle =
            new ChainlinkOracle([address(ausdFeed), address(0)], [ORACLE_STALENESS_DURATION, 0]);

        localAssets = LocalAssetArtifacts({
            acredit: address(acredit),
            mfone: address(mfone),
            usdc: address(usdc),
            ausd: address(ausd),
            acreditOracle: address(acreditOracle),
            mfoneOracle: address(mfoneOracle),
            usdcOracle: address(usdcOracle),
            ausdOracle: address(ausdOracle)
        });
    }

    /// @dev Deploys the rewards-side contracts from isolated artifacts so the main script does not import
    ///      their implementations directly.
    function _deployRewardsArtifacts(
        VaultFactory vaultFactory,
        NetworkRegistry networkRegistry,
        NetworkMiddlewareService networkMiddlewareService,
        address deployer
    ) internal returns (RewardsArtifacts memory rewardsArtifacts) {
        address curatorRegistryImpl =
            deployCode(_protocolArtifactPath(CURATOR_REGISTRY_ARTIFACT), abi.encode(address(vaultFactory)));
        address curatorRegistry = address(
            new TransparentUpgradeableProxy(
                curatorRegistryImpl, deployer, abi.encodeCall(ICuratorRegistryInitializer.initialize, ())
            )
        );

        address feeRegistryImpl = deployCode(_protocolArtifactPath(FEE_REGISTRY_ARTIFACT), abi.encode(curatorRegistry));
        address feeRegistry = address(
            new TransparentUpgradeableProxy(
                feeRegistryImpl, deployer, abi.encodeCall(IFeeRegistryInitializer.initialize, (deployer))
            )
        );

        address rewardsImpl = deployCode(
            _protocolArtifactPath(REWARDS_ARTIFACT),
            abi.encode(
                address(vaultFactory),
                address(networkRegistry),
                address(networkMiddlewareService),
                curatorRegistry,
                feeRegistry
            )
        );
        address rewards = address(
            new TransparentUpgradeableProxy(
                rewardsImpl, deployer, abi.encodeCall(IRewardsInitializer.initialize, (deployer))
            )
        );

        rewardsArtifacts =
            RewardsArtifacts({curatorRegistry: curatorRegistry, feeRegistry: feeRegistry, rewards: rewards});
    }

    /// @dev Deploys the base core contracts that do not depend on the rewards stack.
    function _deployCoreBase(address deployer) internal returns (CoreBaseArtifacts memory base) {
        VaultFactory vaultFactory = new VaultFactory(deployer);
        DelegatorFactory delegatorFactory = new DelegatorFactory(deployer);
        SlasherFactory slasherFactory = new SlasherFactory(deployer);
        NetworkRegistry networkRegistry = new NetworkRegistry();
        OperatorRegistry operatorRegistry = new OperatorRegistry();
        NetworkMiddlewareService networkMiddlewareService = new NetworkMiddlewareService(address(networkRegistry));
        OptInService operatorVaultOptInService =
            new OptInService(address(operatorRegistry), address(vaultFactory), "OperatorVaultOptInService");
        OptInService operatorNetworkOptInService =
            new OptInService(address(operatorRegistry), address(networkRegistry), "OperatorNetworkOptInService");
        AdapterRegistry adapterRegistry = new AdapterRegistry(deployer);

        base = CoreBaseArtifacts({
            vaultFactory: address(vaultFactory),
            delegatorFactory: address(delegatorFactory),
            slasherFactory: address(slasherFactory),
            operatorRegistry: address(operatorRegistry),
            networkRegistry: address(networkRegistry),
            networkMiddlewareService: address(networkMiddlewareService),
            operatorVaultOptInService: address(operatorVaultOptInService),
            operatorNetworkOptInService: address(operatorNetworkOptInService),
            adapterRegistry: address(adapterRegistry)
        });
    }

    /// @dev Deploys and whitelists all delegator implementations required by the RFQ local stack.
    function _deployDelegatorImplementations(CoreBaseArtifacts memory base)
        internal
        returns (uint64 universalDelegatorIndex)
    {
        DelegatorFactory delegatorFactory = DelegatorFactory(base.delegatorFactory);

        NetworkRestakeDelegator networkRestakeDelegatorImpl = new NetworkRestakeDelegator(
            base.networkRegistry,
            base.vaultFactory,
            base.operatorVaultOptInService,
            base.operatorNetworkOptInService,
            base.delegatorFactory,
            delegatorFactory.totalTypes()
        );
        delegatorFactory.whitelist(address(networkRestakeDelegatorImpl));

        FullRestakeDelegator fullRestakeDelegatorImpl = new FullRestakeDelegator(
            base.networkRegistry,
            base.vaultFactory,
            base.operatorVaultOptInService,
            base.operatorNetworkOptInService,
            base.delegatorFactory,
            delegatorFactory.totalTypes()
        );
        delegatorFactory.whitelist(address(fullRestakeDelegatorImpl));

        OperatorSpecificDelegator operatorSpecificDelegatorImpl = new OperatorSpecificDelegator(
            base.operatorRegistry,
            base.networkRegistry,
            base.vaultFactory,
            base.operatorVaultOptInService,
            base.operatorNetworkOptInService,
            base.delegatorFactory,
            delegatorFactory.totalTypes()
        );
        delegatorFactory.whitelist(address(operatorSpecificDelegatorImpl));

        OperatorNetworkSpecificDelegator operatorNetworkSpecificDelegatorImpl = new OperatorNetworkSpecificDelegator(
            base.operatorRegistry,
            base.networkRegistry,
            base.vaultFactory,
            base.operatorVaultOptInService,
            base.operatorNetworkOptInService,
            base.delegatorFactory,
            delegatorFactory.totalTypes()
        );
        delegatorFactory.whitelist(address(operatorNetworkSpecificDelegatorImpl));

        universalDelegatorIndex = delegatorFactory.totalTypes();
        UniversalDelegator universalDelegatorImpl = new UniversalDelegator(
            base.networkRegistry,
            base.vaultFactory,
            base.delegatorFactory,
            UNIVERSAL_DELEGATOR_TYPE,
            base.networkMiddlewareService
        );
        delegatorFactory.whitelist(address(universalDelegatorImpl));
    }

    function _deployProtocolOwnedArtifacts(
        CoreArtifacts memory core,
        address deployer,
        address fillerCaller,
        address permit2
    ) internal returns (ProtocolOwnedArtifacts memory protocol) {
        InstantRedemptionAdapter adapter = InstantRedemptionAdapter(
            address(
                new TransparentUpgradeableProxy(
                    address(new InstantRedemptionAdapter(core.curatorRegistry, core.rewards, core.vaultFactory)),
                    deployer,
                    abi.encodeCall(InstantRedemptionAdapter.initialize, (deployer))
                )
            )
        );
        Reactor reactor = new Reactor(address(adapter), permit2);
        Executor executor = new Executor(address(reactor), address(adapter), deployer);
        LocalSwapRouter router = new LocalSwapRouter(deployer);
        address burnerRouterFactory;

        if (block.chainid == 31_337) {
            _buildBurnersArtifacts();
            address burnerRouterImplementation = deployCode(_protocolArtifactPath(BURNER_ROUTER_ARTIFACT));
            burnerRouterFactory =
                deployCode(_protocolArtifactPath(BURNER_ROUTER_FACTORY_ARTIFACT), abi.encode(burnerRouterImplementation));
        }

        AdapterRegistry(core.adapterRegistry).whitelistAdapter(address(adapter));
        executor.grantRole(CALLER_ROLE, fillerCaller);

        protocol = ProtocolOwnedArtifacts({
            adapter: address(adapter),
            reactor: address(reactor),
            executor: address(executor),
            router: address(router),
            burnerRouterFactory: burnerRouterFactory
        });
    }

    function _configureLocalAdapter(address adapter, LocalAssetArtifacts memory localAssets) internal {
        InstantRedemptionAdapter instantRedemptionAdapter = InstantRedemptionAdapter(adapter);

        instantRedemptionAdapter.setOracle(localAssets.acredit, localAssets.acreditOracle);
        instantRedemptionAdapter.setOracle(localAssets.mfone, localAssets.mfoneOracle);
        instantRedemptionAdapter.setOracle(localAssets.usdc, localAssets.usdcOracle);
        instantRedemptionAdapter.setOracle(localAssets.ausd, localAssets.ausdOracle);
        instantRedemptionAdapter.setAccountImplementation(
            localAssets.acredit, address(new ImmediateSettlementAccount(adapter, localAssets.acredit))
        );
        instantRedemptionAdapter.setAccountImplementation(
            localAssets.mfone, address(new ImmediateSettlementAccount(adapter, localAssets.mfone))
        );
    }

    function _deployCollateralVaults(
        CoreArtifacts memory core,
        address deployer,
        LocalAssetArtifacts memory localAssets
    ) internal returns (VaultPairArtifacts memory vaults) {
        vaults = VaultPairArtifacts({
            usdcVault: _createVault(core, deployer, localAssets.usdc, "USDC Vault", "USDCV"),
            ausdVault: _createVault(core, deployer, localAssets.ausd, "aUSD Vault", "AUSDV")
        });
    }

    /// @dev Deploys and whitelists the slasher implementations required by the RFQ local stack.
    function _deploySlasherImplementations(CoreBaseArtifacts memory base)
        internal
        returns (uint64 universalSlasherIndex)
    {
        SlasherFactory slasherFactory = SlasherFactory(base.slasherFactory);

        Slasher slasherImpl = new Slasher(
            base.vaultFactory, base.networkMiddlewareService, base.slasherFactory, slasherFactory.totalTypes()
        );
        slasherFactory.whitelist(address(slasherImpl));

        VetoSlasher vetoSlasherImpl = new VetoSlasher(
            base.vaultFactory,
            base.networkMiddlewareService,
            base.networkRegistry,
            base.slasherFactory,
            slasherFactory.totalTypes()
        );
        slasherFactory.whitelist(address(vetoSlasherImpl));

        universalSlasherIndex = slasherFactory.totalTypes();
        UniversalSlasher universalSlasherImpl = new UniversalSlasher(
            base.vaultFactory,
            base.networkMiddlewareService,
            base.networkRegistry,
            base.slasherFactory,
            UNIVERSAL_SLASHER_TYPE
        );
        slasherFactory.whitelist(address(universalSlasherImpl));
    }

    /// @dev Deploys the local mocked Morpho and Aave yield adapters and backing pools.
    function _deployYieldArtifacts(CoreArtifacts memory core, address deployer, address usdc, address ausd)
        internal
        returns (YieldArtifacts memory yieldArtifacts)
    {
        MorphoYieldArtifacts memory morphoArtifacts = _deployMorphoYieldArtifacts(core, deployer, usdc, ausd);
        AaveYieldArtifacts memory aaveArtifacts = _deployAaveYieldArtifacts(core, deployer, usdc, ausd);

        yieldArtifacts = YieldArtifacts({
            morphoVaultFactory: morphoArtifacts.morphoVaultFactory,
            usdcMorphoVault: morphoArtifacts.usdcMorphoVault,
            ausdMorphoVault: morphoArtifacts.ausdMorphoVault,
            morphoAdapter: morphoArtifacts.morphoAdapter,
            aavePool: aaveArtifacts.aavePool,
            usdcAToken: aaveArtifacts.usdcAToken,
            ausdAToken: aaveArtifacts.ausdAToken,
            aaveAdapter: aaveArtifacts.aaveAdapter
        });
    }

    function _deployMorphoYieldArtifacts(CoreArtifacts memory core, address deployer, address usdc, address ausd)
        internal
        returns (MorphoYieldArtifacts memory morphoArtifacts)
    {
        MockMorphoVaultFactory morphoVaultFactory = new MockMorphoVaultFactory(deployer);
        MockMorphoVaultV2 usdcMorphoVault = new MockMorphoVaultV2(usdc, core.adapterRegistry, deployer);
        MockMorphoVaultV2 ausdMorphoVault = new MockMorphoVaultV2(ausd, core.adapterRegistry, deployer);
        morphoVaultFactory.setVault(address(usdcMorphoVault), true);
        morphoVaultFactory.setVault(address(ausdMorphoVault), true);

        MorphoVaultV2Adapter morphoAdapter = new MorphoVaultV2Adapter(
            address(morphoVaultFactory), core.adapterRegistry, core.curatorRegistry, core.rewards, core.vaultFactory
        );
        morphoAdapter.initialize();

        morphoArtifacts = MorphoYieldArtifacts({
            morphoVaultFactory: address(morphoVaultFactory),
            usdcMorphoVault: address(usdcMorphoVault),
            ausdMorphoVault: address(ausdMorphoVault),
            morphoAdapter: address(morphoAdapter)
        });
    }

    function _deployAaveYieldArtifacts(CoreArtifacts memory core, address deployer, address usdc, address ausd)
        internal
        returns (AaveYieldArtifacts memory aaveArtifacts)
    {
        MockAavePool aavePool = new MockAavePool(deployer);
        MockAaveAToken usdcAToken = new MockAaveAToken(usdc, "Mock Aave USDC", "maUSDC", deployer);
        MockAaveAToken ausdAToken = new MockAaveAToken(ausd, "Mock Aave aUSD", "maaUSD", deployer);
        usdcAToken.setPool(address(aavePool));
        ausdAToken.setPool(address(aavePool));
        aavePool.setReserve(usdc, address(usdcAToken));
        aavePool.setReserve(ausd, address(ausdAToken));

        AaveV3Adapter aaveAdapter = new AaveV3Adapter(address(aavePool), core.rewards, core.vaultFactory);
        aaveAdapter.initialize();

        aaveArtifacts = AaveYieldArtifacts({
            aavePool: address(aavePool),
            usdcAToken: address(usdcAToken),
            ausdAToken: address(ausdAToken),
            aaveAdapter: address(aaveAdapter)
        });
    }

    /// @dev Creates and initializes a real VaultV2 instance.
    /// @param core The deployed core artifacts.
    /// @param deployer The deployment owner.
    /// @param collateral The vault collateral token.
    /// @param name The vault name.
    /// @param symbol The vault symbol.
    /// @return vault The deployed vault address.
    function _createVault(
        CoreArtifacts memory core,
        address deployer,
        address collateral,
        string memory name,
        string memory symbol
    ) internal returns (address vault) {
        (vault,,) = IVaultConfigurator(core.vaultConfigurator)
            .create(
                IVaultConfigurator.InitParams({
                    version: VaultFactory(core.vaultFactory).lastVersion(),
                    owner: deployer,
                    vaultParams: abi.encode(
                        IVaultV2.InitParams({
                            name: name,
                            symbol: symbol,
                            collateral: collateral,
                            burner: address(0xdEaD),
                            epochDuration: DEFAULT_EPOCH_DURATION,
                            depositWhitelist: false,
                            depositorToWhitelist: deployer,
                            isDepositLimit: false,
                            depositLimit: 0,
                            defaultAdminRoleHolder: deployer,
                            depositWhitelistSetRoleHolder: deployer,
                            depositorWhitelistRoleHolder: deployer,
                            isDepositLimitSetRoleHolder: deployer,
                            depositLimitSetRoleHolder: deployer,
                            setAdapterLimitRoleHolder: deployer,
                            allocateAdapterRoleHolder: deployer
                        })
                    ),
                    delegatorIndex: core.universalDelegatorIndex,
                    delegatorParams: abi.encode(
                        IUniversalDelegator.InitParams({
                            defaultAdminRoleHolder: deployer,
                            hook: address(0),
                            hookSetRoleHolder: deployer,
                            createSlotRoleHolder: deployer,
                            setSizeRoleHolder: deployer,
                            swapSlotsRoleHolder: deployer,
                            withdrawalBufferSize: type(uint128).max
                        })
                    ),
                    withSlasher: true,
                    slasherIndex: core.universalSlasherIndex,
                    slasherParams: abi.encode(
                        IUniversalSlasher.InitParams({
                            isBurnerHook: false, vetoDuration: 1 days, resolverSetDelay: DEFAULT_EPOCH_DURATION * 3
                        })
                    )
                })
            );
    }

    /// @dev Configures the live RFQ contracts and vault inventory.
    /// @param artifacts The deployed artifacts.
    /// @param marketMaker The local market maker / curator.
    function _configureArtifacts(DeploymentArtifacts memory artifacts, address marketMaker) internal {
        LocalMintableERC20 usdc = LocalMintableERC20(artifacts.usdc);
        LocalMintableERC20 ausd = LocalMintableERC20(artifacts.ausd);
        bool enableYieldAdapters = artifacts.morphoAdapter != address(0) && artifacts.aaveAdapter != address(0);
        uint256 morphoAllocationBps = vm.envOr("RFQ_MORPHO_ALLOCATION_BPS", DEFAULT_MORPHO_ALLOCATION_BPS);
        uint256 aaveAllocationBps = vm.envOr("RFQ_AAVE_ALLOCATION_BPS", DEFAULT_AAVE_ALLOCATION_BPS);

        usdc.mint(marketMaker, USDC_VAULT_CAPACITY);
        ausd.mint(marketMaker, AUSD_VAULT_CAPACITY);

        IERC20(artifacts.usdc).approve(artifacts.usdcVault, USDC_VAULT_CAPACITY);
        IVaultV2(artifacts.usdcVault).deposit(marketMaker, USDC_VAULT_CAPACITY);
        IERC20(artifacts.ausd).approve(artifacts.ausdVault, AUSD_VAULT_CAPACITY);
        IVaultV2(artifacts.ausdVault).deposit(marketMaker, AUSD_VAULT_CAPACITY);

        ICuratorRegistry(artifacts.core.curatorRegistry).setCurator(artifacts.usdcVault, marketMaker);
        ICuratorRegistry(artifacts.core.curatorRegistry).setCurator(artifacts.ausdVault, marketMaker);

        IVaultV2(artifacts.usdcVault).setAdapterLimit(artifacts.adapter, type(uint208).max);
        IVaultV2(artifacts.ausdVault).setAdapterLimit(artifacts.adapter, type(uint208).max);

        InstantRedemptionAdapter adapter = InstantRedemptionAdapter(artifacts.adapter);
        adapter.setMakerMaker(artifacts.usdcVault, marketMaker, true);
        adapter.setMakerMaker(artifacts.ausdVault, marketMaker, true);
        adapter.setFiller(artifacts.usdcVault, artifacts.executor, true);
        adapter.setFiller(artifacts.ausdVault, artifacts.executor, true);
        if (enableYieldAdapters) {
            if (morphoAllocationBps + aaveAllocationBps > 10_000) {
                revert("Invalid yield allocation");
            }

            IVaultV2(artifacts.usdcVault).setAdapterLimit(artifacts.morphoAdapter, type(uint208).max);
            IVaultV2(artifacts.usdcVault).setAdapterLimit(artifacts.aaveAdapter, type(uint208).max);
            IVaultV2(artifacts.ausdVault).setAdapterLimit(artifacts.morphoAdapter, type(uint208).max);
            IVaultV2(artifacts.ausdVault).setAdapterLimit(artifacts.aaveAdapter, type(uint208).max);

            MorphoVaultV2Adapter(artifacts.morphoAdapter).setMorphoVault(artifacts.usdcVault, artifacts.usdcMorphoVault);
            MorphoVaultV2Adapter(artifacts.morphoAdapter).setMorphoVault(artifacts.ausdVault, artifacts.ausdMorphoVault);

            address[] memory deallocAdapters =
                _yieldAwareDeallocAdapters(artifacts.morphoAdapter, artifacts.aaveAdapter, artifacts.adapter);
            adapter.setDeallocAdapters(artifacts.usdcVault, deallocAdapters);
            adapter.setDeallocAdapters(artifacts.ausdVault, deallocAdapters);
        } else {
            adapter.setDeallocAdapters(artifacts.usdcVault, _singleton(artifacts.adapter));
            adapter.setDeallocAdapters(artifacts.ausdVault, _singleton(artifacts.adapter));
        }

        adapter.setLimit(artifacts.usdcVault, artifacts.acredit, type(uint256).max);
        adapter.setLimit(artifacts.usdcVault, artifacts.mfone, type(uint256).max);
        adapter.setLimit(artifacts.ausdVault, artifacts.acredit, type(uint256).max);
        adapter.setLimit(artifacts.ausdVault, artifacts.mfone, type(uint256).max);
        adapter.setMinDiscount(artifacts.usdcVault, artifacts.acredit, 0);
        adapter.setMinDiscount(artifacts.usdcVault, artifacts.mfone, 0);
        adapter.setMinDiscount(artifacts.ausdVault, artifacts.acredit, AUSD_VAULT_DISCOUNT);
        adapter.setMinDiscount(artifacts.ausdVault, artifacts.mfone, AUSD_VAULT_DISCOUNT);

        _configureLocalMintAuthorizations(artifacts, usdc, ausd);

        LocalSwapRouter(payable(artifacts.router)).setRate(artifacts.usdc, address(0), 5e14);
        LocalSwapRouter(payable(artifacts.router)).setRate(artifacts.ausd, address(0), 5e14);
        LocalSwapRouter(payable(artifacts.router)).setRate(artifacts.usdc, artifacts.acredit, 8e17);
        LocalSwapRouter(payable(artifacts.router)).setRate(artifacts.usdc, artifacts.mfone, 8e17);
        LocalSwapRouter(payable(artifacts.router)).setRate(artifacts.ausd, artifacts.acredit, 8e17);
        LocalSwapRouter(payable(artifacts.router)).setRate(artifacts.ausd, artifacts.mfone, 8e17);

        if (enableYieldAdapters) {
            _allocateYieldAdapters(
                artifacts.usdcVault,
                artifacts.morphoAdapter,
                artifacts.aaveAdapter,
                morphoAllocationBps,
                aaveAllocationBps
            );
            _allocateYieldAdapters(
                artifacts.ausdVault,
                artifacts.morphoAdapter,
                artifacts.aaveAdapter,
                morphoAllocationBps,
                aaveAllocationBps
            );
        }
    }

    /// @dev Ensures local mock collateral and input tokens are authorized for the IR adapter and swap router.
    /// @param artifacts The deployed artifacts.
    /// @param usdc The local USDC collateral token.
    /// @param ausd The local aUSD collateral token.
    function _configureLocalMintAuthorizations(
        DeploymentArtifacts memory artifacts,
        LocalMintableERC20 usdc,
        LocalMintableERC20 ausd
    ) internal {
        usdc.setAuthorizedAdapter(artifacts.adapter, true);
        ausd.setAuthorizedAdapter(artifacts.adapter, true);
        LocalMintableERC20(artifacts.acredit).setAuthorizedCaller(artifacts.router, true);
        LocalMintableERC20(artifacts.mfone).setAuthorizedCaller(artifacts.router, true);
        usdc.setAuthorizedCaller(artifacts.router, true);
        ausd.setAuthorizedCaller(artifacts.router, true);

        if (!usdc.authorizedAdapters(artifacts.adapter) || !ausd.authorizedAdapters(artifacts.adapter)) {
            revert(ERR_COLLATERAL_ADAPTER_AUTH);
        }
        if (!usdc.authorizedCallers(artifacts.router) || !ausd.authorizedCallers(artifacts.router)) {
            revert(ERR_COLLATERAL_ROUTER_AUTH);
        }
        if (
            !LocalMintableERC20(artifacts.acredit).authorizedCallers(artifacts.router)
                || !LocalMintableERC20(artifacts.mfone).authorizedCallers(artifacts.router)
        ) {
            revert(ERR_INPUT_ROUTER_AUTH);
        }
    }

    /// @dev Funds the local actors and deterministic router.
    /// @param artifacts The deployed artifacts.
    /// @param deployer The deployer address.
    /// @param fillerCaller The filler caller address.
    function _fundArtifacts(DeploymentArtifacts memory artifacts, address deployer, address fillerCaller) internal {
        uint256 routerNativeLiquidity =
            vm.envOr("RFQ_ROUTER_NATIVE_LIQUIDITY_WEI", _defaultRouterNativeLiquidity(block.chainid));
        uint256 fillerNativeFund = vm.envOr("RFQ_FILLER_NATIVE_FUND_WEI", _defaultFillerNativeFund(block.chainid));

        LocalMintableERC20(artifacts.acredit).mint(deployer, 1_000_000 ether);
        if (fillerCaller != deployer) {
            LocalMintableERC20(artifacts.acredit).mint(fillerCaller, 1_000_000 ether);
        }
        LocalMintableERC20(artifacts.acredit).mint(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 1_000_000 ether);
        LocalMintableERC20(artifacts.acredit).mint(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 1_000_000 ether);

        LocalMintableERC20(artifacts.mfone).mint(deployer, 1_000_000 ether);
        if (fillerCaller != deployer) {
            LocalMintableERC20(artifacts.mfone).mint(fillerCaller, 1_000_000 ether);
        }
        LocalMintableERC20(artifacts.mfone).mint(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 1_000_000 ether);
        LocalMintableERC20(artifacts.mfone).mint(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 1_000_000 ether);

        if (fillerNativeFund > 0 && fillerCaller != deployer) {
            payable(fillerCaller).transfer(fillerNativeFund);
        }
        if (routerNativeLiquidity > 0) {
            payable(artifacts.router).transfer(routerNativeLiquidity);
        }
    }

    /// @dev Returns a single-element deallocation adapter list.
    /// @param adapter The adapter address.
    /// @return list The single-element list.
    function _singleton(address adapter) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = adapter;
    }

    /// @dev Returns the deallocation adapters the instant-redemption adapter should consider.
    /// @param morphoAdapter The Morpho adapter.
    /// @param aaveAdapter The Aave adapter.
    /// @param instantRedemptionAdapter The instant-redemption adapter itself.
    /// @return list The ordered deallocation adapter list.
    function _yieldAwareDeallocAdapters(address morphoAdapter, address aaveAdapter, address instantRedemptionAdapter)
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](3);
        list[0] = morphoAdapter;
        list[1] = aaveAdapter;
        list[2] = instantRedemptionAdapter;
    }

    /// @dev Allocates a share of idle collateral into the mocked yield adapters.
    /// @param vault The vault to allocate from.
    /// @param morphoAdapter The Morpho adapter.
    /// @param aaveAdapter The Aave adapter.
    /// @param morphoAllocationBps The Morpho allocation in basis points.
    /// @param aaveAllocationBps The Aave allocation in basis points.
    function _allocateYieldAdapters(
        address vault,
        address morphoAdapter,
        address aaveAdapter,
        uint256 morphoAllocationBps,
        uint256 aaveAllocationBps
    ) internal {
        uint256 totalAllocatable = IVaultV2(vault).allocatable();
        uint256 morphoAmount = totalAllocatable * morphoAllocationBps / 10_000;
        uint256 aaveAmount = totalAllocatable * aaveAllocationBps / 10_000;

        if (morphoAmount > 0) {
            IVaultV2(vault).allocateAdapter(morphoAdapter, morphoAmount);
        }
        if (aaveAmount > 0) {
            IVaultV2(vault).allocateAdapter(aaveAdapter, aaveAmount);
        }
    }

    /// @dev Writes the deployment manifest for the selected environment.
    /// @param context The deployment context.
    /// @param protocolSigner The protocol signer.
    /// @param fillerCaller The filler caller.
    /// @param marketMaker The market maker.
    /// @param artifacts The deployed artifacts.
    function _writeManifest(
        DeploymentContext memory context,
        address protocolSigner,
        address fillerCaller,
        address marketMaker,
        DeploymentArtifacts memory artifacts
    ) internal {
        string memory directory = string.concat(_deploymentsRoot(), "/", context.environment);
        string memory path = string.concat(directory, "/addresses.json");
        string memory json = string.concat(
            "{",
            '"version":1,',
            '"environment":"',
            context.environment,
            '",',
            '"deployed":true,',
            _chainJson(context),
            ",",
            _contractsJson(artifacts),
            ",",
            _participantsJson(protocolSigner, fillerCaller, marketMaker),
            ",",
            _tokensJson(artifacts),
            ",",
            _vaultsJson(artifacts),
            "}"
        );

        vm.createDir(directory, true);
        vm.writeFile(path, json);
    }

    /// @dev Encodes a manifest token object.
    /// @param token The token address.
    /// @param symbol The token symbol.
    /// @param name The token name.
    /// @return json The encoded token json.
    function _tokenJson(address token, string memory symbol, string memory name)
        internal
        view
        returns (string memory json)
    {
        json = string.concat(
            "{",
            '"address":"',
            vm.toString(token),
            '",',
            '"symbol":"',
            symbol,
            '",',
            '"name":"',
            name,
            '",',
            '"decimals":18',
            "}"
        );
    }

    /// @dev Encodes a manifest vault object.
    /// @param vault The vault address.
    /// @param collateral The collateral token.
    /// @param name The display name.
    /// @return json The encoded vault json.
    function _vaultJson(address vault, address collateral, string memory name)
        internal
        view
        returns (string memory json)
    {
        json = string.concat(
            "{",
            '"address":"',
            vm.toString(vault),
            '",',
            '"collateral":"',
            vm.toString(collateral),
            '",',
            '"name":"',
            name,
            '"',
            "}"
        );
    }

    /// @dev Encodes the manifest chain object.
    /// @param context The deployment context.
    /// @return json The encoded chain json.
    function _chainJson(DeploymentContext memory context) internal view returns (string memory json) {
        string memory explorerUrl = vm.envOr("RFQ_EXPLORER_URL", _defaultExplorerUrl(context.chainId));
        json = string.concat(
            '"chain":{',
            '"id":',
            vm.toString(context.chainId),
            ",",
            '"name":"',
            context.chainName,
            '",',
            '"rpcUrl":"',
            context.rpcUrl,
            '",',
            '"testnet":',
            context.testnet ? "true" : "false",
            ",",
            '"startBlock":',
            vm.toString(block.number),
            ",",
            '"explorerUrl":"',
            explorerUrl,
            '"',
            "}"
        );
    }

    function _defaultExplorerUrl(uint256 chainId) internal pure returns (string memory explorerUrl) {
        if (chainId == 1) {
            return "https://etherscan.io";
        }

        if (chainId == 560_048) {
            return "https://eth-hoodi.blockscout.com/";
        }

        return "";
    }

    function _defaultRouterNativeLiquidity(uint256 chainId) internal pure returns (uint256 routerNativeLiquidity) {
        if (chainId == 31_337) {
            return 1000 ether;
        }

        return 0;
    }

    function _defaultFillerNativeFund(uint256 chainId) internal pure returns (uint256 fillerNativeFund) {
        if (chainId == 31_337) {
            return 10 ether;
        }

        return 0;
    }

    /// @dev Encodes the manifest contracts object.
    /// @param artifacts The deployed artifacts.
    /// @return json The encoded contracts json.
    function _contractsJson(DeploymentArtifacts memory artifacts) internal view returns (string memory json) {
        string memory protocolContracts = string.concat(
            '"permit2":"',
            vm.toString(artifacts.permit2),
            '",',
            '"vaultFactory":"',
            vm.toString(artifacts.core.vaultFactory),
            '",',
            '"delegatorFactory":"',
            vm.toString(artifacts.core.delegatorFactory),
            '",',
            '"slasherFactory":"',
            vm.toString(artifacts.core.slasherFactory),
            '",',
            '"networkRegistry":"',
            vm.toString(artifacts.core.networkRegistry),
            '",',
            '"networkMiddlewareService":"',
            vm.toString(artifacts.core.networkMiddlewareService),
            '",',
            '"operatorRegistry":"',
            vm.toString(artifacts.core.operatorRegistry),
            '",',
            '"operatorVaultOptInService":"',
            vm.toString(artifacts.core.operatorVaultOptInService),
            '",',
            '"operatorNetworkOptInService":"',
            vm.toString(artifacts.core.operatorNetworkOptInService),
            '",',
            '"adapterRegistry":"',
            vm.toString(artifacts.core.adapterRegistry),
            '"'
        );
        string memory protocolContracts2 = string.concat(
            '"curatorRegistry":"',
            vm.toString(artifacts.core.curatorRegistry),
            '",',
            '"feeRegistry":"',
            vm.toString(artifacts.core.feeRegistry),
            '",',
            '"rewards":"',
            vm.toString(artifacts.core.rewards),
            '",',
            '"vaultConfigurator":"',
            vm.toString(artifacts.core.vaultConfigurator),
            '",',
            '"instantRedemptionAdapter":"',
            vm.toString(artifacts.adapter),
            '",',
            '"morphoVaultV2Adapter":"',
            vm.toString(artifacts.morphoAdapter),
            '",',
            '"aaveV3Adapter":"',
            vm.toString(artifacts.aaveAdapter),
            '",',
            '"reactor":"',
            vm.toString(artifacts.reactor),
            '",',
            '"executor":"',
            vm.toString(artifacts.executor),
            '",',
            '"burnerRouterFactory":"',
            vm.toString(artifacts.burnerRouterFactory),
            '"'
        );
        string memory morphoContracts = string.concat(
            '"mockMorphoVaultFactory":"',
            vm.toString(artifacts.morphoVaultFactory),
            '",',
            '"mockMorphoVaultUsdc":"',
            vm.toString(artifacts.usdcMorphoVault),
            '",',
            '"mockMorphoVaultAusd":"',
            vm.toString(artifacts.ausdMorphoVault),
            '"'
        );
        string memory aaveContracts = string.concat(
            '"mockAavePool":"',
            vm.toString(artifacts.aavePool),
            '",',
            '"mockAaveUsdcAToken":"',
            vm.toString(artifacts.usdcAToken),
            '",',
            '"mockAaveAusdAToken":"',
            vm.toString(artifacts.ausdAToken),
            '",',
            '"mockSwapRouter":"',
            vm.toString(artifacts.router),
            '"'
        );

        json = string.concat(
            '"contracts":{', protocolContracts, ",", protocolContracts2, ",", morphoContracts, ",", aaveContracts, "}"
        );
    }

    /// @dev Encodes the manifest participants object.
    /// @param protocolSigner The protocol signer.
    /// @param fillerCaller The filler caller.
    /// @param marketMaker The market maker.
    /// @return json The encoded participants json.
    function _participantsJson(address protocolSigner, address fillerCaller, address marketMaker)
        internal
        view
        returns (string memory json)
    {
        json = string.concat(
            '"participants":{',
            '"protocolSigner":"',
            vm.toString(protocolSigner),
            '",',
            '"executorCaller":"',
            vm.toString(fillerCaller),
            '",',
            '"marketMaker":"',
            vm.toString(marketMaker),
            '"',
            "}"
        );
    }

    /// @dev Encodes the manifest tokens object.
    /// @param artifacts The deployed artifacts.
    /// @return json The encoded tokens json.
    function _tokensJson(DeploymentArtifacts memory artifacts) internal view returns (string memory json) {
        json = string.concat(
            '"tokens":{',
            '"input":[',
            _tokenJson(artifacts.acredit, "ACRED", "Apollo Diversified Credit"),
            ",",
            _tokenJson(artifacts.mfone, "mF-ONE", "Midas Fasanara ONE"),
            "],",
            '"output":[',
            _tokenJson(artifacts.usdc, "USDC", "USD Coin"),
            ",",
            _tokenJson(artifacts.ausd, "aUSD", "Anchored USD"),
            ",",
            _tokenJson(address(0), "ETH", "Ether"),
            "],",
            '"defaultInput":"',
            vm.toString(artifacts.acredit),
            '",',
            '"defaultOutput":"',
            vm.toString(artifacts.usdc),
            '"',
            "}"
        );
    }

    /// @dev Encodes the manifest vault list.
    /// @param artifacts The deployed artifacts.
    /// @return json The encoded vaults json.
    function _vaultsJson(DeploymentArtifacts memory artifacts) internal view returns (string memory json) {
        json = string.concat(
            '"vaults":[',
            _vaultJson(artifacts.usdcVault, artifacts.usdc, "USDC Vault"),
            ",",
            _vaultJson(artifacts.ausdVault, artifacts.ausd, "aUSD Vault"),
            "]"
        );
    }
}
