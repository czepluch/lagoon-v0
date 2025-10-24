// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "../../../src/IVault.sol";
import {TotalAssetsAccountingAssertion_v0_5_0} from "../../../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";
import {MockERC20, MockTestBase} from "../../MockTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Standalone Mock Vault for Total Assets Accounting Testing
/// @notice Minimal vault implementation with configurable buggy settlement behavior
/// @dev Uses flags to enable different violations of Invariant #1
contract StandaloneMockVaultTotalAssetsAccounting is ERC20 {
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    struct ERC7540Storage {
        uint256 totalAssets;
        uint40 depositEpochId;
        uint40 redeemEpochId;
        uint40 depositSettleId;
        uint40 redeemSettleId;
        mapping(uint40 => SettleData) settles;
    }

    struct SettleData {
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 pendingAssets;
        uint256 pendingShares;
    }

    address public immutable asset;
    address public immutable safe;
    address public immutable pendingSilo;

    // Flags to control buggy behavior
    bool public shouldSkipTotalAssetsIncrease; // Violates 1.A (deposit)
    bool public shouldDoublePendingAssets; // Violates 1.A (deposit)
    bool public shouldSkipTotalAssetsDecrease; // Violates 1.A (redeem)
    bool public shouldDoubleAssetsWithdrawn; // Violates 1.A (redeem)
    bool public shouldSkipVaultTransfer; // Violates 1.B (solvency)
    bool public shouldTransferWrongAmount; // Violates 1.B (solvency)
    bool public shouldSkipSyncTotalAssetsIncrease; // Violates 1.A (syncDeposit)
    bool public shouldRouteSyncToSilo; // Violates 1.A (syncDeposit routing)

    // Events matching v0.5.0
    event SettleDeposit(
        uint40 indexed lastDepositEpochIdSettled,
        uint40 indexed depositSettleId,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 pendingAssets,
        uint256 shares
    );

    event SettleRedeem(
        uint40 indexed lastRedeemEpochIdSettled,
        uint40 indexed redeemSettleId,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 assetsWithdrawn,
        uint256 pendingShares
    );

    event TotalAssetsUpdated(uint256 newTotalAssets);

    event DepositSync(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);

    constructor(address _asset, address _safe, address _pendingSilo) ERC20("Mock Vault Accounting", "mVaultAcct") {
        asset = _asset;
        safe = _safe;
        pendingSilo = _pendingSilo;

        ERC7540Storage storage $ = _getERC7540Storage();
        $.depositEpochId = 1;
        $.redeemEpochId = 2;
        $.depositSettleId = 0;
        $.redeemSettleId = 0;
    }

    function _getERC7540Storage() private pure returns (ERC7540Storage storage $) {
        assembly {
            $.slot := ERC7540_STORAGE_LOCATION
        }
    }

    // ============ Flag Configuration Functions ============

    function enableSkipTotalAssetsIncrease() external {
        shouldSkipTotalAssetsIncrease = true;
    }

    function enableDoublePendingAssets() external {
        shouldDoublePendingAssets = true;
    }

    function enableSkipTotalAssetsDecrease() external {
        shouldSkipTotalAssetsDecrease = true;
    }

    function enableDoubleAssetsWithdrawn() external {
        shouldDoubleAssetsWithdrawn = true;
    }

    function enableSkipVaultTransfer() external {
        shouldSkipVaultTransfer = true;
    }

    function enableTransferWrongAmount() external {
        shouldTransferWrongAmount = true;
    }

    function enableSkipSyncTotalAssetsIncrease() external {
        shouldSkipSyncTotalAssetsIncrease = true;
    }

    function enableRouteSyncToSilo() external {
        shouldRouteSyncToSilo = true;
    }

    // ============ View Functions ============

    function totalAssets() external view returns (uint256) {
        return _getERC7540Storage().totalAssets;
    }

    function depositEpochId() external view returns (uint40) {
        return _getERC7540Storage().depositEpochId;
    }

    function redeemEpochId() external view returns (uint40) {
        return _getERC7540Storage().redeemEpochId;
    }

    function decimals() public pure override returns (uint8) {
        return 6; // USDC
    }

    // ============ Settlement Functions with Violations ============

    /// @notice Mock settleDeposit with configurable violations
    /// @dev Simulates _updateTotalAssetsAndTakeFees + _settleDeposit behavior
    function settleDeposit(
        uint256 newTotalAssets
    ) external {
        ERC7540Storage storage $ = _getERC7540Storage();

        // 1. NAV Update (emits TotalAssetsUpdated)
        $.totalAssets = newTotalAssets;
        emit TotalAssetsUpdated(newTotalAssets);

        // 2. Deposit Settlement
        uint256 pendingAssets = IERC20(asset).balanceOf(pendingSilo);
        if (pendingAssets == 0) return;

        uint256 shares = (pendingAssets * 1e6) / 1e6; // Simple 1:1 conversion
        _mint(address(this), shares);

        // VIOLATION: Skip totalAssets increase (Invariant 1.A)
        if (!shouldSkipTotalAssetsIncrease) {
            if (shouldDoublePendingAssets) {
                $.totalAssets += pendingAssets * 2; // VIOLATION: Double count
            } else {
                $.totalAssets += pendingAssets; // CORRECT
            }
        }
        // else: VIOLATION - totalAssets doesn't increase

        uint256 _totalSupply = totalSupply();
        $.depositSettleId++;

        emit SettleDeposit($.depositEpochId, $.depositSettleId, $.totalAssets, _totalSupply, pendingAssets, shares);
    }

    /// @notice Mock settleRedeem with configurable violations
    /// @dev Simulates _updateTotalAssetsAndTakeFees + _settleRedeem behavior
    function settleRedeem(
        uint256 newTotalAssets
    ) external {
        ERC7540Storage storage $ = _getERC7540Storage();

        // 1. NAV Update (emits TotalAssetsUpdated)
        $.totalAssets = newTotalAssets;
        emit TotalAssetsUpdated(newTotalAssets);

        // 2. Redeem Settlement
        uint256 pendingShares = balanceOf(pendingSilo);
        if (pendingShares == 0) return;

        uint256 assetsWithdrawn = (pendingShares * 1e6) / 1e6; // Simple 1:1 conversion

        // Burn shares from Silo
        _burn(pendingSilo, pendingShares);

        // Transfer assets from Safe to Vault
        if (!shouldSkipVaultTransfer) {
            uint256 transferAmount = assetsWithdrawn;
            if (shouldTransferWrongAmount) {
                transferAmount = assetsWithdrawn / 2; // VIOLATION: Transfer half
            }
            IERC20(asset).transferFrom(safe, address(this), transferAmount);
        }
        // else: VIOLATION - No transfer (solvency issue)

        // VIOLATION: Skip totalAssets decrease (Invariant 1.A)
        if (!shouldSkipTotalAssetsDecrease) {
            if (shouldDoubleAssetsWithdrawn) {
                $.totalAssets -= assetsWithdrawn * 2; // VIOLATION: Double count
            } else {
                $.totalAssets -= assetsWithdrawn; // CORRECT
            }
        }
        // else: VIOLATION - totalAssets doesn't decrease

        uint256 _totalSupply = totalSupply();
        $.redeemSettleId++;

        emit SettleRedeem(
            $.redeemEpochId, $.redeemSettleId, $.totalAssets, _totalSupply, assetsWithdrawn, pendingShares
        );
    }

    /// @notice Mock syncDeposit with configurable violations
    /// @dev Simulates instant deposit bypassing epoch system
    function syncDeposit(uint256 assets, address receiver, address) external payable returns (uint256 shares) {
        ERC7540Storage storage $ = _getERC7540Storage();

        // Transfer assets from sender
        address sender = msg.sender;
        IERC20(asset).transferFrom(sender, shouldRouteSyncToSilo ? pendingSilo : safe, assets);

        // Calculate shares (simple 1:1 for testing)
        shares = assets;

        // Mint shares to receiver
        _mint(receiver, shares);

        // Update totalAssets (with optional violation)
        if (!shouldSkipSyncTotalAssetsIncrease) {
            $.totalAssets += assets; // CORRECT
        }
        // else: VIOLATION - totalAssets doesn't increase

        emit DepositSync(sender, receiver, assets, shares);
    }

    // ============ Test Helpers ============

    function setupDeposit(
        uint256 amount
    ) external {
        MockERC20(asset).mint(pendingSilo, amount);
    }

    function setupRedeem(
        uint256 shares
    ) external {
        _mint(pendingSilo, shares);
    }

    function setTotalAssets(
        uint256 amount
    ) external {
        _getERC7540Storage().totalAssets = amount;
    }
}

/// @title Mock Tests for Total Assets Accounting Assertion
/// @notice Tests violation scenarios using StandaloneMockVaultTotalAssetsAccounting
contract TestTotalAssetsAccountingAssertionMock is MockTestBase {
    StandaloneMockVaultTotalAssetsAccounting public vault;
    MockERC20 public mockAsset;
    address public safe;
    address public silo;

    function setUp() public {
        safe = makeAddr("safe");
        silo = makeAddr("silo");
        mockAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        vault = new StandaloneMockVaultTotalAssetsAccounting(address(mockAsset), safe, silo);
    }

    // ==================== Invariant 1.A: Accounting Conservation Violations ====================

    /// @notice Test: Assertion catches when totalAssets doesn't increase after settleDeposit
    function testSettleDepositSkipsTotalAssetsIncrease() public {
        // Setup: Silo has pending assets
        vault.setupDeposit(10_000e6);
        vault.setTotalAssets(50_000e6);

        // Enable violation: Skip totalAssets increase
        vault.enableSkipTotalAssetsIncrease();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle should trigger assertion failure
        vm.expectRevert("Accounting violation: totalAssets after settleDeposit incorrect");
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: Assertion catches when totalAssets increases by wrong amount (double)
    function testSettleDepositDoublesPendingAssets() public {
        vault.setupDeposit(10_000e6);
        vault.setTotalAssets(50_000e6);

        vault.enableDoublePendingAssets();

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.expectRevert("Accounting violation: totalAssets after settleDeposit incorrect");
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: Assertion catches when totalAssets doesn't decrease after settleRedeem
    function testSettleRedeemSkipsTotalAssetsDecrease() public {
        // Setup: Silo has pending shares, Safe has assets
        vault.setupRedeem(10_000e6); // 10k shares in Silo
        vault.setTotalAssets(60_000e6);
        mockAsset.mint(safe, 20_000e6);

        // Enable violation before approval
        vault.enableSkipTotalAssetsDecrease();

        // Setup approval BEFORE cl.assertion
        vm.prank(safe);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        vm.expectRevert("Accounting violation: totalAssets after settleRedeem incorrect");
        vault.settleRedeem(60_000e6);
    }

    /// @notice Test: Assertion catches when totalAssets decreases by wrong amount (double)
    function testSettleRedeemDoublesAssetsWithdrawn() public {
        vault.setupRedeem(10_000e6);
        vault.setTotalAssets(60_000e6);
        mockAsset.mint(safe, 20_000e6);

        vault.enableDoubleAssetsWithdrawn();

        vm.prank(safe);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        vm.expectRevert("Accounting violation: totalAssets after settleRedeem incorrect");
        vault.settleRedeem(60_000e6);
    }

    // ==================== Invariant 1.B: Solvency Violations ====================

    /// @notice Test: Assertion catches when vault doesn't receive assets from Safe
    function testSettleRedeemSkipsVaultTransfer() public {
        vault.setupRedeem(10_000e6);
        vault.setTotalAssets(60_000e6);
        mockAsset.mint(safe, 20_000e6);

        vault.enableSkipVaultTransfer();

        vm.prank(safe);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        vm.expectRevert("Solvency violation: vault balance did not increase correctly");
        vault.settleRedeem(60_000e6);
    }

    /// @notice Test: Assertion catches when vault receives wrong amount from Safe
    function testSettleRedeemTransfersWrongAmount() public {
        vault.setupRedeem(10_000e6);
        vault.setTotalAssets(60_000e6);
        mockAsset.mint(safe, 20_000e6);

        vault.enableTransferWrongAmount();

        vm.prank(safe);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        vm.expectRevert("Solvency violation: vault balance did not increase correctly");
        vault.settleRedeem(60_000e6);
    }

    // ==================== Invariant 1.A: Sync Deposit Accounting Violations ====================

    /// @notice Test: Assertion catches when syncDeposit doesn't update totalAssets
    function testSyncDepositSkipsTotalAssetsIncrease() public {
        // Setup mock vault for syncDeposit
        vault.setTotalAssets(50_000e6);
        mockAsset.mint(silo, 100_000e6); // Give silo tokens for user

        vault.enableSkipSyncTotalAssetsIncrease();

        // Approve BEFORE cl.assertion to avoid consuming trigger
        vm.prank(silo);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(silo);
        vm.expectRevert("Accounting violation: totalAssets after syncDeposit incorrect");
        vault.syncDeposit(10_000e6, silo, address(0));
    }

    /// @notice Test: Assertion catches when syncDeposit routes to Silo instead of Safe
    function testSyncDepositRoutesToSilo() public {
        vault.setTotalAssets(50_000e6);
        mockAsset.mint(silo, 100_000e6);

        vault.enableRouteSyncToSilo();

        // Approve BEFORE cl.assertion
        vm.prank(silo);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(silo);
        vm.expectRevert("Routing violation: syncDeposit assets did not go to Safe");
        vault.syncDeposit(10_000e6, silo, address(0));
    }
}
