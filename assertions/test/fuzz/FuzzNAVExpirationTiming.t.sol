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
}
