// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultHelper} from "@test/v0.4.0/VaultHelper.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {Rates} from "@src/v0.4.0/primitives/Struct.sol";

import {IERC20Metadata, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

using SafeERC20 for IERC20;
using Math for uint256;

/// @title MockERC20
/// @notice Simple mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockWETH
/// @notice Simple mock WETH for testing
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

/// @title AssertionBaseTest
/// @notice Reusable base test contract for all assertion tests
/// @dev Provides common setup, helpers, and user wallets for testing assertions
///      against the v0.4.0 Lagoon Vault protocol
abstract contract AssertionBaseTest is CredibleTest, Test {
    // ============ Constants ============

    int256 immutable bipsDividerSigned = 10_000;

    // ============ Mock Tokens ============

    MockERC20 public mockAsset;
    MockWETH public mockWETH;

    // ============ Protocol Contracts ============

    VaultHelper public vault;
    FeeRegistry public feeRegistry;
    BeaconProxyFactory public factory;

    // ============ Configuration ============

    bool proxy = false; // Use direct deployment for simplicity in assertions
    uint8 decimalsOffset = 0;

    string vaultName = "Test Vault";
    string vaultSymbol = "TVAULT";
    uint256 rateUpdateCooldown = 1 days;

    address[] whitelistInit = new address[](0);
    bool enableWhitelist = true;

    // ============ Test Users ============

    VmSafe.Wallet public user1 = vm.createWallet("user1");
    VmSafe.Wallet public user2 = vm.createWallet("user2");
    VmSafe.Wallet public user3 = vm.createWallet("user3");
    VmSafe.Wallet public user4 = vm.createWallet("user4");
    VmSafe.Wallet public user5 = vm.createWallet("user5");
    VmSafe.Wallet public user6 = vm.createWallet("user6");
    VmSafe.Wallet public user7 = vm.createWallet("user7");
    VmSafe.Wallet public user8 = vm.createWallet("user8");
    VmSafe.Wallet public user9 = vm.createWallet("user9");
    VmSafe.Wallet public user10 = vm.createWallet("user10");

    VmSafe.Wallet public owner = vm.createWallet("owner");
    VmSafe.Wallet public safe = vm.createWallet("safe");
    VmSafe.Wallet public valuationManager = vm.createWallet("valuationManager");
    VmSafe.Wallet public admin = vm.createWallet("admin");
    VmSafe.Wallet public feeReceiver = vm.createWallet("feeReceiver");
    VmSafe.Wallet public dao = vm.createWallet("dao");
    VmSafe.Wallet public whitelistManager = vm.createWallet("whitelistManager");

    VmSafe.Wallet[] public users;

    // Wallet for address(0) - useful for certain tests
    VmSafe.Wallet public address0 = VmSafe.Wallet({addr: address(0), publicKeyX: 0, publicKeyY: 0, privateKey: 0});

    // ============ Constructor ============

    constructor() {
        users.push(user1);
        users.push(user2);
        users.push(user3);
        users.push(user4);
        users.push(user5);
        users.push(user6);
        users.push(user7);
        users.push(user8);
        users.push(user9);
        users.push(user10);
    }

    // ============ Setup Helpers ============

    /// @notice Setup vault with specified fee rates
    /// @param _protocolRate Protocol fee rate in BPS (basis points)
    /// @param _managementRate Management fee rate in BPS
    /// @param _performanceRate Performance fee rate in BPS
    function setUpVault(uint16 _protocolRate, uint16 _managementRate, uint16 _performanceRate) internal {
        // Deploy mock tokens
        mockAsset = new MockERC20("Mock USDC", "USDC", 6);
        mockWETH = new MockWETH();

        // Initialize fee registry
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        vm.prank(dao.addr);
        feeRegistry.updateDefaultRate(_protocolRate);

        // Deploy vault implementation
        bool disableImplementationInit = proxy;
        address implementation = address(new VaultHelper(disableImplementationInit));

        // Deploy factory
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));

        // Prepare initialization struct
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: vaultName,
            symbol: vaultSymbol,
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: _managementRate,
            performanceRate: _performanceRate,
            rateUpdateCooldown: rateUpdateCooldown,
            enableWhitelist: enableWhitelist
        });

        // Deploy vault (direct deployment, not proxy for simplicity)
        vault = VaultHelper(implementation);
        vault.initialize(abi.encode(initStruct), address(feeRegistry), address(mockWETH));

        // Whitelist essential addresses
        if (enableWhitelist) {
            whitelistInit.push(feeReceiver.addr);
            whitelistInit.push(dao.addr);
            whitelistInit.push(safe.addr);
            whitelistInit.push(vault.pendingSilo());
            whitelistInit.push(address(feeRegistry));
            vm.prank(whitelistManager.addr);
            vault.addToWhitelist(whitelistInit);
        }

        // Label contracts for better trace output
        vm.label(address(vault), vaultName);
        vm.label(vault.pendingSilo(), "vault.pendingSilo");
        vm.label(address(mockAsset), "MockUSDC");
        vm.label(address(mockWETH), "MockWETH");
    }

    // ============ Asset Management Helpers ============

    /// @notice Deal assets and approve vault spending for a user
    /// @param user Address to receive assets and approve
    function dealAndApproveAndWhitelist(address user) internal {
        dealAmountAndApprove(user, 100_000 * 10 ** 6); // 100k USDC (6 decimals)
        whitelist(user);
    }

    /// @notice Deal specific amount of assets and approve vault spending
    /// @param user Address to receive assets and approve
    /// @param amount Amount of assets to deal
    function dealAmountAndApproveAndWhitelist(address user, uint256 amount) internal {
        dealAmountAndApprove(user, amount);
        whitelist(user);
    }

    /// @notice Deal assets and approve vault spending
    /// @param user Address to receive assets and approve
    function dealAndApprove(address user) internal {
        dealAmountAndApprove(user, 100_000 * 10 ** 6);
    }

    /// @notice Deal specific amount and approve vault spending
    /// @param user Address to receive assets and approve
    /// @param amount Amount of assets to deal
    function dealAmountAndApprove(address user, uint256 amount) internal {
        // Mint mock tokens to user
        mockAsset.mint(user, amount);

        // Approve vault
        vm.prank(user);
        IERC20(address(mockAsset)).approve(address(vault), type(uint256).max);

        // Give user some ETH for gas
        deal(user, 100 ether);
    }

    /// @notice Get asset balance for a user
    /// @param user Address to query balance for
    /// @return Asset balance of the user
    function assetBalance(address user) internal view returns (uint256) {
        return mockAsset.balanceOf(user);
    }

    // ============ Whitelist Helpers ============

    /// @notice Add user to whitelist
    /// @param user User to whitelist
    function whitelist(address user) internal {
        address[] memory usersArray = new address[](1);
        usersArray[0] = user;
        vm.prank(vault.whitelistManager());
        vault.addToWhitelist(usersArray);
    }

    /// @notice Add multiple users to whitelist
    /// @param usersArray Array of users to whitelist
    function whitelist(address[] memory usersArray) internal {
        vm.prank(vault.whitelistManager());
        vault.addToWhitelist(usersArray);
    }

    /// @notice Remove user from whitelist
    /// @param user User to remove from whitelist
    function unwhitelist(address user) internal {
        address[] memory usersArray = new address[](1);
        usersArray[0] = user;
        vm.prank(vault.whitelistManager());
        vault.revokeFromWhitelist(usersArray);
    }

    /// @notice Remove multiple users from whitelist
    /// @param usersArray Array of users to remove
    function unwhitelist(address[] memory usersArray) internal {
        vm.prank(vault.whitelistManager());
        vault.revokeFromWhitelist(usersArray);
    }
}
