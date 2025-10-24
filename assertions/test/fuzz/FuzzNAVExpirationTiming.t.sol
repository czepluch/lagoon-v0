// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NAVValidityAssertion_v0_5_0} from "../../src/NAVValidityAssertion_v0.5.0.a.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";

import {IERC20Metadata, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

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

/// @title FuzzNAVExpirationTiming
/// @notice Fuzz tests for NAV expiration timestamp calculations and validity checks
/// @dev Focuses on Invariant 5.C - testing expiration formula:
///      totalAssetsExpiration = block.timestamp + totalAssetsLifespan
///
///      Critical scenarios:
///      - Different lifespan values (0, short, medium, long)
///      - Time warps before/after expiration
///      - Settlement triggering expiration refresh
///      - Validity checks (isTotalAssetsValid) consistency
contract FuzzNAVExpirationTiming is CredibleTest, Test {
    // ============ Mock Tokens ============
    MockERC20 public mockAsset;
    MockWETH public mockWETH;

    // ============ Protocol Contracts ============
    VaultHelper public vault;
    FeeRegistry public feeRegistry;
    BeaconProxyFactory public factory;

    // ============ Test Users ============
    VmSafe.Wallet public user1 = vm.createWallet("user1");
    VmSafe.Wallet public safe = vm.createWallet("safe");
    VmSafe.Wallet public valuationManager = vm.createWallet("valuationManager");
    VmSafe.Wallet public admin = vm.createWallet("admin");
    VmSafe.Wallet public feeReceiver = vm.createWallet("feeReceiver");
    VmSafe.Wallet public dao = vm.createWallet("dao");
    VmSafe.Wallet public whitelistManager = vm.createWallet("whitelistManager");

    function setUp() public {
        // Deploy mock tokens (using 6 decimals for simplicity)
        mockAsset = new MockERC20("Mock USDC", "USDC", 6);
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

        // Whitelist essential addresses and user
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

    // ==================== Fuzz Test 1: Expiration After settleDeposit ====================

    /// @notice Fuzz test: Expiration timestamp is set correctly after settleDeposit
    /// @dev Tests: totalAssetsExpiration = block.timestamp + lifespan
    function testFuzz_ExpirationAfterSettleDeposit(uint128 lifespan, uint256 depositAmount) public {
        // Bound lifespan: 0 to 30 days (0 = async mode, >0 = sync mode)
        lifespan = uint128(bound(lifespan, 0, 30 days));

        // Bound deposit amount
        depositAmount = bound(depositAmount, 1e6, 1e10); // 1 to 10,000 USDC

        // Set lifespan
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(lifespan);

        // Fund user and request deposit
        mockAsset.mint(user1.addr, depositAmount * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(user1.addr);
        vault.requestDeposit(depositAmount, user1.addr, user1.addr);

        // Update NAV and prepare for settlement
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Record timestamp before settlement
        uint256 settlementTime = block.timestamp;

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Settle deposit - triggers expiration update
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // Verify expiration was set correctly
        uint256 expiration = vault.totalAssetsExpiration();

        if (lifespan > 0) {
            // Should be settlementTime + lifespan
            uint256 expected = settlementTime + lifespan;
            assertEq(expiration, expected, "Expiration should equal settlement time + lifespan");

            // Verify isTotalAssetsValid returns true (not expired yet)
            assertTrue(vault.isTotalAssetsValid(), "NAV should be valid immediately after settlement");
        } else {
            // If lifespan == 0, expiration should be <= block.timestamp (expired)
            assertLe(expiration, block.timestamp, "Expiration should be expired when lifespan is 0");

            // Verify isTotalAssetsValid returns false (expired)
            assertFalse(vault.isTotalAssetsValid(), "NAV should be expired when lifespan is 0");
        }
    }

    // ==================== Fuzz Test 2: Expiration After settleRedeem ====================

    /// @notice Fuzz test: Expiration timestamp is set correctly after settleRedeem
    /// @dev Tests the same formula but via redeem path
    function testFuzz_ExpirationAfterSettleRedeem(
        uint128 lifespan
    ) public {
        // Bound lifespan
        lifespan = uint128(bound(lifespan, 0, 30 days));

        // Set lifespan
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(lifespan);

        // Setup: Deposit and mint shares first
        uint256 depositAmount = 10_000e6;
        mockAsset.mint(user1.addr, depositAmount * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(user1.addr);
        vault.requestDeposit(depositAmount, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // Claim shares
        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // Request redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        // Warp past NAV expiration so we can update NAV (access control requirement)
        uint256 currentExpiration = vault.totalAssetsExpiration();
        if (block.timestamp < currentExpiration) {
            vm.warp(currentExpiration + 1);
        }

        // Update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(depositAmount);

        // Fund safe and approve
        mockAsset.mint(safe.addr, depositAmount);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Record timestamp before settlement
        uint256 settlementTime = block.timestamp;

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Settle redeem - triggers expiration update
        vm.prank(safe.addr);
        vault.settleRedeem(depositAmount);

        // Verify expiration
        uint256 expiration = vault.totalAssetsExpiration();

        if (lifespan > 0) {
            uint256 expected = settlementTime + lifespan;
            assertEq(expiration, expected, "Expiration should equal settlement time + lifespan");
            assertTrue(vault.isTotalAssetsValid(), "NAV should be valid after redeem settlement");
        } else {
            assertLe(expiration, block.timestamp, "Expiration should be expired when lifespan is 0");
            assertFalse(vault.isTotalAssetsValid(), "NAV should be expired when lifespan is 0");
        }
    }

    // ==================== Fuzz Test 3: Validity After Time Warp ====================

    /// @notice Fuzz test: isTotalAssetsValid correctly reflects expiration after time passes
    /// @dev Tests boundary conditions around expiration time
    function testFuzz_ValidityAfterTimeWarp(uint128 lifespan, uint256 timeWarp) public {
        // Bound inputs
        lifespan = uint128(bound(lifespan, 1, 30 days)); // Skip 0 (always expired)
        timeWarp = bound(timeWarp, 0, 60 days);

        // Set lifespan and settle to create expiration
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(lifespan);

        // Settle deposit to set expiration
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        uint256 expiration = vault.totalAssetsExpiration();

        // Warp time forward
        vm.warp(block.timestamp + timeWarp);

        // Check validity
        bool isValid = vault.isTotalAssetsValid();

        // Expected: valid only if current time < expiration
        bool expectedValid = block.timestamp < expiration;

        assertEq(isValid, expectedValid, "isTotalAssetsValid should match timestamp < expiration");
    }

    // ==================== Fuzz Test 4: Boundary Conditions at Expiration ====================

    /// @notice Fuzz test: Validity check at exact expiration boundary
    /// @dev Tests the precise moment when NAV expires
    function testFuzz_ValidityAtExpirationBoundary(
        uint128 lifespan
    ) public {
        // Bound lifespan (exclude 0)
        lifespan = uint128(bound(lifespan, 1 hours, 30 days));

        // Set lifespan and settle
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(lifespan);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        uint256 expiration = vault.totalAssetsExpiration();

        // Test 1: One second before expiration - should be valid
        vm.warp(expiration - 1);
        assertTrue(vault.isTotalAssetsValid(), "Should be valid 1 second before expiration");

        // Test 2: At exact expiration - should be INVALID (not <)
        vm.warp(expiration);
        assertFalse(vault.isTotalAssetsValid(), "Should be invalid at exact expiration time");

        // Test 3: One second after expiration - should be invalid
        vm.warp(expiration + 1);
        assertFalse(vault.isTotalAssetsValid(), "Should be invalid 1 second after expiration");
    }

    // ==================== Fuzz Test 5: Lifespan Changes and Expiration Updates ====================

    /// @notice Fuzz test: Changing lifespan affects future expirations correctly
    /// @dev Tests that lifespan updates apply to subsequent settlements
    function testFuzz_LifespanChangeAffectsExpiration(uint128 lifespan1, uint128 lifespan2) public {
        // Bound lifespans
        lifespan1 = uint128(bound(lifespan1, 1 hours, 10 days));
        lifespan2 = uint128(bound(lifespan2, 1 hours, 10 days));

        // First settlement with lifespan1
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(lifespan1);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        uint256 expiration1 = vault.totalAssetsExpiration();

        // Warp past expiration
        vm.warp(expiration1 + 1);

        // Change lifespan to lifespan2
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(lifespan2);

        // Second settlement with new lifespan
        uint256 settlementTime2 = block.timestamp;

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        uint256 expiration2 = vault.totalAssetsExpiration();

        // Verify expiration uses NEW lifespan
        uint256 expectedExpiration2 = settlementTime2 + lifespan2;
        assertEq(expiration2, expectedExpiration2, "Second expiration should use updated lifespan");

        // Verify they're different if lifespans differ
        if (lifespan1 != lifespan2) {
            assertNotEq(
                expiration2 - settlementTime2,
                expiration1 - (settlementTime2 - expiration1 - 1),
                "Expirations should reflect different lifespans"
            );
        }
    }
}
