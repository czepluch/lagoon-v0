// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

using SafeERC20 for IERC20;

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
/// @notice Mock WETH (18 decimals)
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

/// @title FuzzTestBase
/// @notice Base contract for fuzz tests with common setup and utilities
/// @dev Reduces duplication across fuzz test contracts
abstract contract FuzzTestBase is CredibleTest, Test {
    // ============ Mock Tokens ============
    MockERC20 public mockAsset;
    MockWETH public mockWETH;

    // ============ Protocol Contracts ============
    VaultHelper public vault;
    FeeRegistry public feeRegistry;
    BeaconProxyFactory public factory;

    // ============ Test Users ============
    VmSafe.Wallet public user1 = vm.createWallet("user1");
    VmSafe.Wallet public user2 = vm.createWallet("user2");
    VmSafe.Wallet public safe = vm.createWallet("safe");
    VmSafe.Wallet public valuationManager = vm.createWallet("valuationManager");
    VmSafe.Wallet public admin = vm.createWallet("admin");
    VmSafe.Wallet public feeReceiver = vm.createWallet("feeReceiver");
    VmSafe.Wallet public dao = vm.createWallet("dao");
    VmSafe.Wallet public whitelistManager = vm.createWallet("whitelistManager");

    /// @notice Setup vault with specific token decimals
    /// @param tokenDecimals The number of decimals for the underlying token
    function setupVaultWithDecimals(
        uint8 tokenDecimals
    ) internal {
        // Deploy mock tokens
        mockAsset = new MockERC20("Mock Token", "MTK", tokenDecimals);
        mockWETH = new MockWETH();

        // Initialize fee registry
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        // Deploy vault implementation
        address implementation = address(new VaultHelper(false));

        // Deploy factory
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));

        // Prepare initialization struct
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: "Test Vault",
            symbol: "TVAULT",
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            rateUpdateCooldown: 1 days,
            enableWhitelist: true
        });

        // Deploy vault
        vault = VaultHelper(implementation);
        vault.initialize(abi.encode(initStruct), address(feeRegistry), address(mockWETH));

        // Whitelist essential addresses and users
        address[] memory whitelist = new address[](7);
        whitelist[0] = feeReceiver.addr;
        whitelist[1] = dao.addr;
        whitelist[2] = safe.addr;
        whitelist[3] = vault.pendingSilo();
        whitelist[4] = address(feeRegistry);
        whitelist[5] = user1.addr;
        whitelist[6] = user2.addr;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(whitelist);
    }

    /// @notice Setup vault using factory pattern (for NAV tests)
    /// @param tokenDecimals The number of decimals for the underlying token
    function setupVaultWithFactory(
        uint8 tokenDecimals
    ) internal {
        // Deploy mock tokens
        mockAsset = new MockERC20("Mock Token", "MTK", tokenDecimals);
        mockWETH = new MockWETH();

        // Initialize fee registry
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        // Deploy vault implementation
        address implementation = address(new VaultHelper(false));

        // Deploy factory
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));

        // Prepare initialization struct
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: "Test Vault",
            symbol: "TVAULT",
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            rateUpdateCooldown: 1 days,
            enableWhitelist: true
        });

        // Create vault via factory
        vm.prank(dao.addr);
        address vaultAddr = factory.createVaultProxy(initStruct, bytes32(0));
        vault = VaultHelper(vaultAddr);

        // Whitelist essential addresses and users
        address[] memory whitelist = new address[](6);
        whitelist[0] = feeReceiver.addr;
        whitelist[1] = dao.addr;
        whitelist[2] = safe.addr;
        whitelist[3] = vault.pendingSilo();
        whitelist[4] = address(feeRegistry);
        whitelist[5] = user1.addr;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(whitelist);
    }

    /// @notice Helper to scale amount based on token decimals
    /// @param baseAmount The base amount (assuming 6 decimals)
    /// @param decimals The target token decimals
    /// @return The scaled amount
    function scaleAmount(uint256 baseAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 6) {
            return baseAmount * (10 ** (decimals - 6));
        } else {
            return baseAmount / (10 ** (6 - decimals));
        }
    }

    /// @notice Helper to bound decimals to realistic values (6, 18)
    /// @param decimals The input decimals value
    /// @return The bounded decimals (6 or 18)
    function boundDecimals(
        uint8 decimals
    ) internal pure returns (uint8) {
        decimals = uint8(bound(decimals, 6, 18));
        if (decimals > 6 && decimals < 18) decimals = 18;
        return decimals;
    }
}
