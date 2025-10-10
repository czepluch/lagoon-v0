// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TotalAssetsAccountingAssertion_v0_5_0} from "../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";
import {EpochInvariantsAssertion} from "../src/EpochInvariantsAssertion.a.sol";
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

/// @title TestTotalAssetsAccountingAssertion
/// @notice Tests Invariant #1: Total Assets Accounting Integrity for v0.5.0
/// @dev Tests cover:
///      - 1.A: Accounting Conservation (settleDeposit, settleRedeem)
///      - 1.B: Solvency (vault balance covers claimable redemptions)
contract TestTotalAssetsAccountingAssertion is CredibleTest, Test {
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

    VmSafe.Wallet public owner = vm.createWallet("owner");
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

        // Label contracts for better trace output
        vm.label(address(vault), vaultName);
        vm.label(vault.pendingSilo(), "vault.pendingSilo");
        vm.label(address(mockAsset), "MockUSDC");
        vm.label(address(mockWETH), "MockWETH");
    }

    // ============ Helper Functions ============

    function dealAndApproveAndWhitelist(address user) internal {
        mockAsset.mint(user, 100_000e6); // 100k USDC
        vm.prank(user);
        IERC20(address(mockAsset)).approve(address(vault), type(uint256).max);
        deal(user, 100 ether); // Gas

        address[] memory usersArray = new address[](1);
        usersArray[0] = user;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(usersArray);
    }

    // ==================== Invariant 1.A: Accounting Conservation Tests ====================

    /// @notice Test: totalAssets increases correctly after single settleDeposit
    function testSettleDepositAccountingSingle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User requests deposit (assets go to Silo)
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Valuation manager updates NAV and increments epochs
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Setup: Safe approves vault (must be BEFORE cl.assertion)
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Safe settles deposit - assertion should pass
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: totalAssets increases correctly after multiple sequential settlements
    function testSettleDepositAccountingMultiple() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // First deposit cycle
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Second deposit cycle
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(70_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(70_000e6);
    }

    /// @notice Test: totalAssets decreases correctly after single settleRedeem
    function testSettleRedeemAccountingSingle() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Claim shares (deposit for v0.5.0)
        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // Request redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        // Trigger epoch increment
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Setup: Safe gets assets and approves vault (must be BEFORE cl.assertion)
        uint256 safeBalance = mockAsset.balanceOf(safe.addr);
        uint256 needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle redeem - assertion should pass
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    /// @notice Test: totalAssets decreases correctly after multiple sequential redeem settlements
    function testSettleRedeemAccountingMultiple() public {
        // Setup: deposit and mint shares for two users
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 claimableShares1 = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares1, user1.addr, user1.addr);

        uint256 claimableShares2 = vault.claimableDepositRequest(0, user2.addr);
        vm.prank(user2.addr);
        vault.deposit(claimableShares2, user2.addr, user2.addr);

        // First redeem cycle (user1)
        uint256 user1Shares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(user1Shares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        uint256 safeBalance = mockAsset.balanceOf(safe.addr);
        uint256 needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);

        // Second redeem cycle (user2)
        uint256 user2Shares = vault.balanceOf(user2.addr);
        vm.prank(user2.addr);
        vault.requestRedeem(user2Shares, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(40_000e6);

        safeBalance = mockAsset.balanceOf(safe.addr);
        needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(40_000e6);
    }

    /// @notice Test: Handles zero pending deposits gracefully (no event, no state change)
    function testSettleDepositWithZeroPending() public {
        // No pending deposits

        // Trigger epoch increment
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle with zero pending - assertion should pass (no event, no state change)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: Handles zero pending redeems gracefully (no event, no state change)
    function testSettleRedeemWithZeroPending() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // No pending redeems

        // Trigger epoch increment
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        uint256 safeBalance = mockAsset.balanceOf(safe.addr);
        uint256 needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle with zero pending - assertion should pass (no event, no state change)
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    // ==================== Invariant 1.B: Solvency Tests ====================

    /// @notice Test: Vault balance increases correctly after settleRedeem (solvency)
    function testVaultSolvencyAfterRedeem() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // Request redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        uint256 safeBalance = mockAsset.balanceOf(safe.addr);
        uint256 needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register solvency assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        // Settle redeem - vault should receive assets from Safe
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    /// @notice Test: Vault solvency maintained across multiple redemptions
    function testVaultSolvencyMultipleRedemptions() public {
        // Setup: deposit and mint shares for two users
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 claimableShares1 = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares1, user1.addr, user1.addr);

        uint256 claimableShares2 = vault.claimableDepositRequest(0, user2.addr);
        vm.prank(user2.addr);
        vault.deposit(claimableShares2, user2.addr, user2.addr);

        // First redeem
        uint256 user1Shares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(user1Shares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        uint256 safeBalance = mockAsset.balanceOf(safe.addr);
        uint256 needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);

        // Second redeem
        uint256 user2Shares = vault.balanceOf(user2.addr);
        vm.prank(user2.addr);
        vault.requestRedeem(user2Shares, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(40_000e6);

        safeBalance = mockAsset.balanceOf(safe.addr);
        needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(40_000e6);
    }

    /// @notice Test: Solvency assertion handles zero pending redeems
    function testVaultSolvencyWithZeroPending() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // No pending redeems

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        uint256 safeBalance = mockAsset.balanceOf(safe.addr);
        uint256 needed = vault.totalAssets();
        if (safeBalance < needed) {
            mockAsset.mint(safe.addr, needed - safeBalance);
        }
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register solvency assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        // Settle with zero pending - vault balance shouldn't change
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    // ==================== Invariant 1.A: Sync Deposit Accounting Tests ====================

    /// @notice Test: totalAssets increases correctly after single syncDeposit
    function testSyncDepositAccountingSingle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Set NAV and enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6); // This sets expiration = block.timestamp + 1000

        // Verify NAV is valid (sync mode active)
        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // User does sync deposit - assertion should pass
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));
    }

    /// @notice Test: Verifies assets go to Safe, not Silo
    function testSyncDepositRoutingToSafe() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Set NAV and enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Check balances before
        uint256 preSafeBalance = mockAsset.balanceOf(safe.addr);
        uint256 preSiloBalance = mockAsset.balanceOf(vault.pendingSilo());

        // Register assertion (checks Safe balance increase)
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Sync deposit
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify routing: Safe increased, Silo unchanged
        assertEq(mockAsset.balanceOf(safe.addr), preSafeBalance + 10_000e6, "Safe should receive assets");
        assertEq(mockAsset.balanceOf(vault.pendingSilo()), preSiloBalance, "Silo should be unchanged");
    }

    // ==================== Invariant 2.4: Sync Deposit Epoch Isolation Tests ====================

    /// @notice Test: syncDeposit does NOT change depositEpochId (from EpochInvariantsAssertion)
    function testSyncDepositEpochIsolationSingle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Set NAV and enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        uint40 preDepositEpochId = vault.depositEpochId();
        uint40 preRedeemEpochId = vault.redeemEpochId();

        // Register EpochInvariantsAssertion
        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSyncDepositIsolation.selector
        });

        // Sync deposit - assertion should pass (epochs unchanged)
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify epochs didn't change
        assertEq(vault.depositEpochId(), preDepositEpochId, "depositEpochId should not change");
        assertEq(vault.redeemEpochId(), preRedeemEpochId, "redeemEpochId should not change");
    }

}
