// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SyncDepositModeAssertion_v0_5_0} from "../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";

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

/// @title TestSyncDepositModeAssertion
/// @notice Tests Invariant #4: Synchronous Deposit Mode Integrity for v0.5.0
/// @dev Tests cover all sub-invariants:
///      - 4.A: Mode Mutual Exclusivity (sync vs async mode)
///      - 4.B: Synchronous Deposit Accounting (totalAssets, Safe balance, shares)
///      - 4.C: Epoch System Isolation (depositEpochId, Silo balance)
///      - 4.D: NAV Expiration State Machine (totalAssetsExpiration updates)
contract TestSyncDepositModeAssertion is CredibleTest, Test {
    // ============ Mock Tokens ============
    MockERC20 public mockAsset;
    MockWETH public mockWETH;

    // ============ Protocol Contracts ============
    VaultHelper public vault;
    FeeRegistry public feeRegistry;
    BeaconProxyFactory public factory;

    // ============ Configuration ============
    bool proxy = false;
    uint8 decimalsOffset = 0;
    string vaultName = "Test Vault v0.5.0";
    string vaultSymbol = "TVAULT5";
    uint256 rateUpdateCooldown = 1 days;
    address[] whitelistInit = new address[](0);
    bool enableWhitelist = true;

    // ============ Test Users ============
    VmSafe.Wallet public user1 = vm.createWallet("user1");
    VmSafe.Wallet public user2 = vm.createWallet("user2");
    VmSafe.Wallet public user3 = vm.createWallet("user3");

    VmSafe.Wallet public owner = vm.createWallet("owner");
    VmSafe.Wallet public safe = vm.createWallet("safe");
    VmSafe.Wallet public valuationManager = vm.createWallet("valuationManager");
    VmSafe.Wallet public admin = vm.createWallet("admin");
    VmSafe.Wallet public feeReceiver = vm.createWallet("feeReceiver");
    VmSafe.Wallet public dao = vm.createWallet("dao");
    VmSafe.Wallet public whitelistManager = vm.createWallet("whitelistManager");

    // ============ Assertion Contract ============
    SyncDepositModeAssertion_v0_5_0 public assertion;

    function setUp() public {
        // Deploy mock tokens
        mockAsset = new MockERC20("Mock USDC", "USDC", 6);
        mockWETH = new MockWETH();

        // Initialize fee registry
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        // Deploy vault implementation
        bool disableImplementationInit = proxy;
        address implementation = address(new VaultHelper(disableImplementationInit));

        // Deploy factory
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));

        // Prepare initialization struct with zero fees for simplicity
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: vaultName,
            symbol: vaultSymbol,
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            rateUpdateCooldown: rateUpdateCooldown,
            enableWhitelist: enableWhitelist
        });

        // Deploy vault (direct deployment for simplicity)
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

        // Enable sync deposit mode by setting totalAssetsLifespan (1000 seconds)
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        // Settle to set expiration timestamp
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // Deploy assertion contract
        assertion = new SyncDepositModeAssertion_v0_5_0();

        // Label contracts for better trace output
        vm.label(address(vault), vaultName);
        vm.label(vault.pendingSilo(), "vault.pendingSilo");
        vm.label(address(mockAsset), "MockUSDC");
        vm.label(address(mockWETH), "MockWETH");
    }

    // ============ Helper Functions ============

    /// @notice Deal assets and approve vault spending for a user
    function dealAndApproveAndWhitelist(address user) internal {
        mockAsset.mint(user, 100_000e6); // 100k USDC
        vm.prank(user);
        IERC20(address(mockAsset)).approve(address(vault), type(uint256).max);
        deal(user, 100 ether); // Gas

        address[] memory usersArray = new address[](1);
        usersArray[0] = user;
        vm.prank(vault.whitelistManager());
        vault.addToWhitelist(usersArray);
    }

    /// @notice Helper to settle deposits with assets from Safe
    function settleDepositWithAssets(uint256 totalAssets) internal {
        mockAsset.mint(safe.addr, totalAssets);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(totalAssets);
    }

    // ==================== Invariant 4.A: Mode Mutual Exclusivity Tests ====================

    /// @notice Test: syncDeposit works when NAV is valid (sync mode)
    /// @dev This tests the happy path for Invariant 4.A - sync mode should be allowed
    function testSyncDepositModeWhenNAVValid() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Verify NAV is valid (sync mode enabled)
        assertTrue(vault.isTotalAssetsValid(), "NAV should be valid for sync mode");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositMode.selector
        });

        // Execute syncDeposit - should pass
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(10_000e6, user1.addr, address(0));

        assertGt(shares, 0, "Shares should be minted");
    }

    /// @notice Test: syncDeposit fails when NAV is expired (async mode)
    /// @dev This tests that the vault correctly rejects syncDeposit in async mode
    function testSyncDepositModeFailsWhenNAVExpired() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Expire NAV by warping past expiration
        vm.warp(block.timestamp + 1001);
        assertFalse(vault.isTotalAssetsValid(), "NAV should be expired");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositMode.selector
        });

        // Attempt syncDeposit - should revert
        vm.prank(user1.addr);
        vm.expectRevert(); // Vault should revert with OnlyAsyncDepositAllowed
        vault.syncDeposit(10_000e6, user1.addr, address(0));
    }

    /// @notice Test: requestDeposit works when NAV is expired (async mode)
    /// @dev This tests the happy path for Invariant 4.A - async mode should be allowed
    function testAsyncDepositModeWhenNAVExpired() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Expire NAV
        vm.warp(block.timestamp + 1001);
        assertFalse(vault.isTotalAssetsValid(), "NAV should be expired");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionAsyncDepositMode.selector
        });

        // Execute requestDeposit - should pass
        vm.prank(user1.addr);
        uint256 requestId = vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        assertGt(requestId, 0, "Request ID should be assigned");
    }

    /// @notice Test: requestDeposit fails when NAV is valid (sync mode)
    /// @dev This tests that the vault correctly rejects requestDeposit in sync mode
    function testAsyncDepositModeFailsWhenNAVValid() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Verify NAV is valid
        assertTrue(vault.isTotalAssetsValid(), "NAV should be valid");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionAsyncDepositMode.selector
        });

        // Attempt requestDeposit - should revert
        vm.prank(user1.addr);
        vm.expectRevert(); // Vault should revert with OnlySyncDepositAllowed
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
    }

    // ==================== Invariant 4.B: Synchronous Deposit Accounting Tests ====================

    /// @notice Test: syncDeposit correctly updates totalAssets, Safe balance, and shares
    /// @dev Verifies all accounting changes are correct after syncDeposit
    function testSyncDepositAccounting() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(50_000e6, user1.addr, address(0));

        // Verify shares were minted
        assertEq(vault.balanceOf(user1.addr), shares, "User should receive shares");
        assertGt(shares, 0, "Shares should be minted");
    }

    /// @notice Test: syncDeposit accounting with multiple deposits
    /// @dev Verifies accounting remains correct across multiple syncDeposit calls
    function testSyncDepositAccountingMultipleDeposits() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // First deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user1.addr);
        uint256 shares1 = vault.syncDeposit(30_000e6, user1.addr, address(0));

        // Second deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user2.addr);
        uint256 shares2 = vault.syncDeposit(20_000e6, user2.addr, address(0));

        // Verify both users have correct shares
        assertEq(vault.balanceOf(user1.addr), shares1);
        assertEq(vault.balanceOf(user2.addr), shares2);
    }

    /// @notice Test: syncDeposit accounting with different receiver
    /// @dev Verifies shares go to receiver, not sender
    function testSyncDepositAccountingDifferentReceiver() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // user1 deposits, user2 receives shares
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(10_000e6, user2.addr, address(0));

        // Verify user2 received shares, not user1
        assertEq(vault.balanceOf(user2.addr), shares, "Receiver should get shares");
        assertEq(vault.balanceOf(user1.addr), 0, "Sender should not get shares");
    }

    // ==================== Invariant 4.C: Epoch System Isolation Tests ====================

    /// @notice Test: syncDeposit does not increment depositEpochId
    /// @dev Verifies epoch system remains unchanged by syncDeposit
    function testEpochIsolationDepositEpochUnchanged() public {
        dealAndApproveAndWhitelist(user1.addr);

        uint40 preDepositEpochId = vault.depositEpochId();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify depositEpochId unchanged
        assertEq(vault.depositEpochId(), preDepositEpochId, "depositEpochId should not change");
    }

    /// @notice Test: syncDeposit does not affect Silo balance
    /// @dev Verifies assets go to Safe, not Silo
    function testEpochIsolationSiloBalanceUnchanged() public {
        dealAndApproveAndWhitelist(user1.addr);

        address silo = vault.pendingSilo();
        uint256 preSiloBalance = mockAsset.balanceOf(silo);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify Silo balance unchanged
        assertEq(mockAsset.balanceOf(silo), preSiloBalance, "Silo balance should not change");
    }

    /// @notice Test: syncDeposit isolation with multiple deposits
    /// @dev Verifies epoch isolation holds across multiple syncDeposit calls
    function testEpochIsolationMultipleSyncDeposits() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        uint40 preDepositEpochId = vault.depositEpochId();
        address silo = vault.pendingSilo();
        uint256 preSiloBalance = mockAsset.balanceOf(silo);

        // First deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Second deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });
        vm.prank(user2.addr);
        vault.syncDeposit(15_000e6, user2.addr, address(0));

        // Verify epoch system still isolated
        assertEq(vault.depositEpochId(), preDepositEpochId);
        assertEq(mockAsset.balanceOf(silo), preSiloBalance);
    }

    // ==================== Invariant 4.D: NAV Expiration State Machine Tests ====================

    /// @notice Test: settleDeposit updates totalAssetsExpiration correctly
    /// @dev Verifies expiration = block.timestamp + lifespan after settlement
    function testNAVExpirationUpdateAfterSettleDeposit() public {
        // Setup: Create pending deposit
        dealAndApproveAndWhitelist(user1.addr);

        // Expire NAV first
        vm.warp(block.timestamp + 1001);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        // Update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Prepare assets for settlement
        mockAsset.mint(safe.addr, 50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion for settleDeposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Settle deposit
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Verify expiration is updated correctly
        uint256 expectedExpiration = block.timestamp + vault.totalAssetsLifespan();
        assertEq(vault.totalAssetsExpiration(), expectedExpiration, "Expiration should match formula");
    }

    /// @notice Test: settleRedeem updates totalAssetsExpiration correctly
    /// @dev Verifies expiration formula works for redeem settlements too
    function testNAVExpirationUpdateAfterSettleRedeem() public {
        // Setup: Complete deposit cycle first
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.syncDeposit(50_000e6, user1.addr, address(0));

        // Request redeem
        address pendingSilo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.approve(pendingSilo, type(uint256).max);

        // Expire NAV
        vm.warp(block.timestamp + 1001);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        // Update NAV - Note: During redemption, assets stay in Safe
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Ensure Safe has approved vault to handle transfers for claimRedeem
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion for settleRedeem
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Settle redeem
        vm.prank(safe.addr);
        vault.settleRedeem(50_000e6);

        // Verify expiration updated
        uint256 expectedExpiration = block.timestamp + vault.totalAssetsLifespan();
        assertEq(vault.totalAssetsExpiration(), expectedExpiration);
    }

    /// @notice Test: NAV expiration update with zero lifespan (sync mode disabled)
    /// @dev When lifespan = 0, assertion should not enforce expiration updates
    function testNAVExpirationWithZeroLifespan() public {
        // Disable sync mode by setting lifespan to 0
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(0);

        // Expire NAV manually since lifespan = 0 means NAV is always expired
        vm.prank(safe.addr);
        vault.expireTotalAssets();

        // Setup deposit
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Prepare assets for settlement
        mockAsset.mint(safe.addr, 50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Settle - should pass even without expiration update check (lifespan = 0)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: NAV expiration update across multiple settlements
    /// @dev Verifies expiration updates correctly after each settlement
    function testNAVExpirationMultipleSettlements() public {
        // First settlement
        dealAndApproveAndWhitelist(user1.addr);
        vm.warp(block.timestamp + 1001);
        vm.prank(user1.addr);
        vault.requestDeposit(30_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(30_000e6);

        // Prepare assets for settlement
        mockAsset.mint(safe.addr, 30_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(30_000e6);

        uint256 firstExpiration = vault.totalAssetsExpiration();
        uint256 expectedFirst = block.timestamp + vault.totalAssetsLifespan();
        assertEq(firstExpiration, expectedFirst, "First expiration should be correct");

        // Second settlement after warp
        vm.warp(block.timestamp + 500);
        dealAndApproveAndWhitelist(user2.addr);
        vm.warp(block.timestamp + 501); // Expire again
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Prepare assets for second settlement
        mockAsset.mint(safe.addr, 50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 secondExpiration = vault.totalAssetsExpiration();
        uint256 expectedSecond = block.timestamp + vault.totalAssetsLifespan();
        assertEq(secondExpiration, expectedSecond, "Second expiration should be updated");
        assertGt(secondExpiration, firstExpiration, "Expiration should increase over time");
    }
}
