// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NAVValidityAssertion_v0_5_0} from "../src/NAVValidityAssertion_v0.5.0.a.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestNAVValidityAssertion
/// @notice Tests Invariant #5: NAV Validity and Expiration Lifecycle for v0.5.0
/// @dev Tests cover all sub-invariants:
///      - 5.A: NAV Validity Consistency (isTotalAssetsValid matches totalAssetsExpiration)
///      - 5.B: NAV Update Access Control (updateNewTotalAssets blocked when valid)
///      - 5.C: Expiration Timestamp After Settlement (expiration set correctly)
///      - 5.D: Lifespan Update Verification (event emitted, state updated)
///      - 5.E: Manual Expiration Verification (expireTotalAssets works correctly)
contract TestNAVValidityAssertion is CredibleTest, Test {
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
        // Deploy mock tokens
        mockAsset = new MockERC20("Mock USDC", "USDC", 6);
        mockWETH = new MockWETH();

        // Initialize fee registry
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        // Deploy vault implementation
        bool disableImplementationInit = false;
        address implementation = address(new VaultHelper(disableImplementationInit));

        // Deploy factory
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));

        // Prepare initialization struct with zero fees for simplicity
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: "Test Vault v0.5.0",
            symbol: "TVAULT5",
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            enableWhitelist: true,
            rateUpdateCooldown: 0
        });

        // Create vault via factory
        vm.prank(dao.addr);
        address vaultAddr = factory.createVaultProxy(initStruct, bytes32(0));
        vault = VaultHelper(vaultAddr);

        // Label addresses
        vm.label(address(vault), "Test Vault v0.5.0");
        vm.label(vault.pendingSilo(), "vault.pendingSilo");
        vm.label(address(mockAsset), "MockUSDC");
        vm.label(address(mockWETH), "MockWETH");

        // Whitelist test users and protocol addresses
        address[] memory toWhitelist = new address[](5);
        toWhitelist[0] = feeReceiver.addr;
        toWhitelist[1] = dao.addr;
        toWhitelist[2] = safe.addr;
        toWhitelist[3] = vault.pendingSilo();
        toWhitelist[4] = address(feeRegistry);
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(toWhitelist);
    }

    /// @notice Helper to deal tokens, approve vault, and whitelist user
    function dealAndApproveAndWhitelist(address user) internal {
        mockAsset.mint(user, 100_000e6);
        vm.prank(user);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.deal(user, 100 ether);
        address[] memory toWhitelist = new address[](1);
        toWhitelist[0] = user;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(toWhitelist);
    }

    // ============================================================================
    // GROUP A: VALIDITY CONSISTENCY (3 tests)
    // ============================================================================

    /// @notice Test: isTotalAssetsValid() consistent when NAV is expired (lifespan = 0)
    function testValidityConsistentWhenExpired() public {
        // Setup: Default state has lifespan = 0 (async-only mode)
        // No settlement needed, NAV should be expired by default

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Update NAV (allowed when expired)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Assertion verifies: isTotalAssetsValid() == false and totalAssetsExpiration == 0
    }

    /// @notice Test: isTotalAssetsValid() consistent when NAV is valid
    function testValidityConsistentWhenValid() public {
        // Setup: Set lifespan and settle to make NAV valid
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Settle deposit (sets expiration = block.timestamp + 1000)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Assertion verifies: isTotalAssetsValid() == true and expiration > block.timestamp
    }

    /// @notice Test: isTotalAssetsValid() consistent after expiration time passes
    function testValidityConsistentAfterExpiration() public {
        // Setup: Set short lifespan and settle
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Warp past expiration
        vm.warp(block.timestamp + 2);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Update NAV after expiration
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Assertion verifies: isTotalAssetsValid() == false even though expiration > 0
    }

    // ============================================================================
    // GROUP B: ACCESS CONTROL (2 tests)
    // ============================================================================

    /// @notice Test: updateNewTotalAssets() blocked when NAV is valid
    function testNAVUpdateBlockedWhenValid() public {
        // Setup: Set lifespan and settle to make NAV valid
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // NAV is now valid for 1000 seconds
        // Safe must expire NAV first before valuation manager can update

        vm.prank(safe.addr);
        vault.expireTotalAssets();

        // Register assertion (checks NAV was expired before update)
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionNAVUpdateAccessControl.selector
        });

        // Now valuation manager can update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Assertion verifies: NAV was expired before updateNewTotalAssets was called
    }

    /// @notice Test: updateNewTotalAssets() allowed when NAV is expired
    function testNAVUpdateAllowedWhenExpired() public {
        // Setup: Default state has lifespan = 0 (NAV always expired)

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionNAVUpdateAccessControl.selector
        });

        // Action: Update NAV (allowed when expired)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Assertion verifies: NAV was expired before update
    }

    // ============================================================================
    // GROUP C: EXPIRATION AFTER SETTLEMENT (3 tests)
    // ============================================================================

    /// @notice Test: totalAssetsExpiration set correctly after settleDeposit
    function testExpirationSetAfterSettleDeposit() public {
        // Setup: Set lifespan = 1000
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle deposit
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Assertion verifies: totalAssetsExpiration == block.timestamp + 1000
    }

    /// @notice Test: totalAssetsExpiration set correctly after settleRedeem
    function testExpirationSetAfterSettleRedeem() public {
        // Setup: Deposit, get shares, then request redeem
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // User claims shares
        uint256 claimable = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimable, user1.addr, user1.addr);

        // User requests redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.approve(address(vault), userShares);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        // Expire NAV so we can update it
        vm.prank(safe.addr);
        vault.expireTotalAssets();

        // Update NAV for redeem settlement
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Safe funds vault
        mockAsset.mint(safe.addr, 20_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle redeem
        vm.prank(safe.addr);
        vault.settleRedeem(50_000e6);

        // Assertion verifies: totalAssetsExpiration == block.timestamp + 1000
    }

    /// @notice Test: totalAssetsExpiration remains 0 when lifespan is 0
    function testExpirationZeroWhenLifespanZero() public {
        // Setup: Lifespan = 0 (default async-only mode)
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle deposit with lifespan = 0
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Assertion verifies: totalAssetsExpiration == 0 (not block.timestamp + 0)
    }

    // ============================================================================
    // GROUP D: LIFESPAN UPDATES (2 tests)
    // ============================================================================

    /// @notice Test: Lifespan update from 0 to non-zero
    function testLifespanUpdateFromZeroToNonZero() public {
        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionLifespanUpdate.selector
        });

        // Action: Safe sets lifespan to 1000
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        // Assertion verifies:
        // - TotalAssetsLifespanUpdated(0, 1000) event emitted
        // - totalAssetsLifespan == 1000
    }

    /// @notice Test: Lifespan update from non-zero to zero (disable sync mode)
    function testLifespanUpdateFromNonZeroToZero() public {
        // Setup: Set lifespan to 1000 first
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionLifespanUpdate.selector
        });

        // Action: Safe disables sync mode by setting lifespan to 0
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(0);

        // Assertion verifies:
        // - TotalAssetsLifespanUpdated(1000, 0) event emitted
        // - totalAssetsLifespan == 0
    }

    // ============================================================================
    // GROUP E: MANUAL EXPIRATION (2 tests)
    // ============================================================================

    /// @notice Test: Manual expiration forces async mode
    function testManualExpirationForcesAsyncMode() public {
        // Setup: Set lifespan and settle to make NAV valid
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // NAV is now valid for 1000 seconds

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionManualExpiration.selector
        });

        // Action: Safe manually expires NAV
        vm.prank(safe.addr);
        vault.expireTotalAssets();

        // Assertion verifies:
        // - totalAssetsExpiration == 0
        // - isTotalAssetsValid() == false
    }

    /// @notice Test: Manual expiration enables NAV update
    function testManualExpirationEnablesNAVUpdate() public {
        // Setup: Set lifespan and settle to make NAV valid
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // NAV is now valid - updateNewTotalAssets would fail

        // Safe manually expires NAV
        vm.prank(safe.addr);
        vault.expireTotalAssets();

        // Register assertion (verifies NAV was expired before update)
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionNAVUpdateAccessControl.selector
        });

        // Action: Valuation manager can now update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Assertion verifies: NAV was expired before update (access control enforced)
    }
}

// ============================================================================
// MOCKS AND HELPERS
// ============================================================================

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
