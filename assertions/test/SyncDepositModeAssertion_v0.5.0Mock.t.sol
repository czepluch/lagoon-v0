// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {SyncDepositModeAssertion_v0_5_0} from "../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {IVault} from "../src/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 for testing
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

/// @title Standalone Mock Vault for Sync Deposit Mode Testing
/// @notice Minimal vault implementation with configurable buggy sync deposit behavior
/// @dev Uses flags to enable different violations of Invariant #4
contract StandaloneMockVaultSyncDeposit is ERC20 {
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    struct ERC7540Storage {
        uint256 totalAssets;
        uint256 newTotalAssets;
        uint40 depositEpochId;
        uint40 redeemEpochId;
        uint128 totalAssetsExpiration;
        uint128 totalAssetsLifespan;
    }

    address public immutable asset;
    address public immutable safe;
    address public immutable pendingSilo;

    // Flags to control buggy behavior
    bool public shouldAllowSyncWhenExpired;      // Violates 4.A
    bool public shouldAllowRequestWhenValid;     // Violates 4.A
    bool public shouldBreakTotalAssets;          // Violates 4.B
    bool public shouldBreakSafeBalance;          // Violates 4.B
    bool public shouldBreakSharesMinted;         // Violates 4.B
    bool public shouldIncrementDepositEpoch;     // Violates 4.C
    bool public shouldAffectSilo;                // Violates 4.C
    bool public shouldSkipExpirationUpdate;      // Violates 4.D

    constructor(address _asset, address _safe, address _pendingSilo) ERC20("Mock Vault Sync", "mVaultSync") {
        asset = _asset;
        safe = _safe;
        pendingSilo = _pendingSilo;

        ERC7540Storage storage $ = _getERC7540Storage();
        $.depositEpochId = 1;
        $.redeemEpochId = 2;
        $.totalAssetsLifespan = 1000; // Default 1000 seconds
        $.totalAssetsExpiration = uint128(block.timestamp + 1000);
    }

    function _getERC7540Storage() private pure returns (ERC7540Storage storage $) {
        assembly {
            $.slot := ERC7540_STORAGE_LOCATION
        }
    }

    // ============ Flag Configuration Functions ============

    function enableAllowSyncWhenExpired() external {
        shouldAllowSyncWhenExpired = true;
    }

    function enableAllowRequestWhenValid() external {
        shouldAllowRequestWhenValid = true;
    }

    function enableBreakTotalAssets() external {
        shouldBreakTotalAssets = true;
    }

    function enableBreakSafeBalance() external {
        shouldBreakSafeBalance = true;
    }

    function enableBreakSharesMinted() external {
        shouldBreakSharesMinted = true;
    }

    function enableIncrementDepositEpoch() external {
        shouldIncrementDepositEpoch = true;
    }

    function enableAffectSilo() external {
        shouldAffectSilo = true;
    }

    function enableSkipExpirationUpdate() external {
        shouldSkipExpirationUpdate = true;
    }

    // ============ Core Vault Functions ============

    /// @notice Synchronous deposit with configurable buggy behavior
    function syncDeposit(uint256 assets, address receiver, address /* referral */) external payable returns (uint256 shares) {
        // Check NAV validity (unless buggy flag is set)
        if (!shouldAllowSyncWhenExpired) {
            require(isTotalAssetsValid(), "NAV expired");
        }

        ERC7540Storage storage $ = _getERC7540Storage();

        // Transfer assets from sender
        IERC20(asset).transferFrom(msg.sender, safe, assets);

        // Update totalAssets (buggy or correct)
        if (shouldBreakTotalAssets) {
            $.totalAssets += assets / 2; // Wrong: only add half
        } else {
            $.totalAssets += assets;
        }

        // If shouldBreakSafeBalance, send some assets to pendingSilo instead
        if (shouldBreakSafeBalance) {
            IERC20(asset).transferFrom(safe, pendingSilo, assets / 4);
        }

        // Calculate shares using proper ERC4626 formula with decimals offset
        uint256 supply = totalSupply();
        uint256 decimalsOffset = 10 ** (18 - IERC20Metadata(asset).decimals());

        if (shouldBreakSharesMinted) {
            // Wrong: mint double the correct amount
            uint256 correctShares = (supply == 0)
                ? assets * decimalsOffset
                : (assets * (supply + decimalsOffset)) / ($.totalAssets + 1);
            shares = correctShares * 2;
        } else {
            // Correct: ERC4626 formula with decimals offset
            shares = (supply == 0)
                ? assets * decimalsOffset
                : (assets * (supply + decimalsOffset)) / ($.totalAssets + 1);
        }

        // Mint shares
        _mint(receiver, shares);

        // Violate epoch isolation if flag is set
        if (shouldIncrementDepositEpoch) {
            $.depositEpochId += 1;
        }

        // Affect Silo if flag is set
        if (shouldAffectSilo) {
            IERC20(asset).transferFrom(safe, pendingSilo, 1); // Send 1 wei to Silo
        }

        return shares;
    }

    /// @notice Request deposit with configurable buggy behavior
    function requestDeposit(uint256 assets, address /* controller */, address /* owner */) external returns (uint256) {
        // Check NAV validity (unless buggy flag is set)
        if (!shouldAllowRequestWhenValid) {
            require(!isTotalAssetsValid(), "NAV valid, use syncDeposit");
        }

        // Transfer assets to pending silo
        IERC20(asset).transferFrom(msg.sender, pendingSilo, assets);

        return 1; // Return dummy request ID
    }

    /// @notice Settle deposit with configurable expiration update
    function settleDeposit(uint256 /* totalAssets */) external {
        ERC7540Storage storage $ = _getERC7540Storage();

        // Update expiration (buggy or correct)
        if (!shouldSkipExpirationUpdate && $.totalAssetsLifespan > 0) {
            $.totalAssetsExpiration = uint128(block.timestamp) + $.totalAssetsLifespan;
        }
        // If shouldSkipExpirationUpdate, don't update expiration
    }

    /// @notice Settle redeem with configurable expiration update
    function settleRedeem(uint256 /* totalAssets */) external {
        ERC7540Storage storage $ = _getERC7540Storage();

        // Update expiration (buggy or correct)
        if (!shouldSkipExpirationUpdate && $.totalAssetsLifespan > 0) {
            $.totalAssetsExpiration = uint128(block.timestamp) + $.totalAssetsLifespan;
        }
    }

    // ============ View Functions ============

    function isTotalAssetsValid() public view returns (bool) {
        ERC7540Storage storage $ = _getERC7540Storage();
        if ($.totalAssetsLifespan == 0) return false;
        return block.timestamp <= $.totalAssetsExpiration;
    }

    function totalAssetsExpiration() public view returns (uint256) {
        return _getERC7540Storage().totalAssetsExpiration;
    }

    function totalAssetsLifespan() public view returns (uint256) {
        return _getERC7540Storage().totalAssetsLifespan;
    }

    function depositEpochId() public view returns (uint40) {
        return _getERC7540Storage().depositEpochId;
    }

    function redeemEpochId() public view returns (uint40) {
        return _getERC7540Storage().redeemEpochId;
    }

    function totalAssets() public view returns (uint256) {
        return _getERC7540Storage().totalAssets;
    }

    function newTotalAssets() public view returns (uint256) {
        return _getERC7540Storage().newTotalAssets;
    }

    function lastDepositEpochIdSettled() public view returns (uint40) {
        return 0; // Not used in sync deposit tests
    }

    function lastRedeemEpochIdSettled() public view returns (uint40) {
        return 0; // Not used in sync deposit tests
    }

    function updateNewTotalAssets(uint256) external {
        // Stub for interface compliance
    }

    /// @notice Manually expire NAV for testing
    function expireNAV() external {
        ERC7540Storage storage $ = _getERC7540Storage();
        $.totalAssetsExpiration = 0;
    }

    /// @notice Manually set lifespan for testing
    function setLifespan(uint128 lifespan) external {
        ERC7540Storage storage $ = _getERC7540Storage();
        $.totalAssetsLifespan = lifespan;
    }
}

/// @title SyncDepositModeAssertion Failure Tests
/// @notice Tests that sync deposit mode assertions correctly catch violations
/// @dev Tests Invariant #4 (Synchronous Deposit Mode Integrity)
contract TestSyncDepositModeAssertionMock is CredibleTest, Test {
    StandaloneMockVaultSyncDeposit public mockVault;
    MockERC20 public mockAsset;
    address public safe;
    address public pendingSilo;
    address public user;

    function setUp() public {
        safe = address(0x5AFE);
        pendingSilo = address(0x5110);
        user = address(0xBEEF);

        mockAsset = new MockERC20("Mock USDC", "USDC", 6);
        mockVault = new StandaloneMockVaultSyncDeposit(address(mockAsset), safe, pendingSilo);

        // Setup user with assets
        mockAsset.mint(user, 1_000_000e6);
        vm.prank(user);
        mockAsset.approve(address(mockVault), type(uint256).max);

        // Give safe some assets for transfers
        mockAsset.mint(safe, 1_000_000e6);
        vm.prank(safe);
        mockAsset.approve(address(mockVault), type(uint256).max);
    }

    // ==================== Invariant 4.A: Mode Mutual Exclusivity Failure Tests ====================

    /// @notice Test: Assertion fails when syncDeposit is called with expired NAV
    function testModeViolationSyncDepositWhenExpired() public {
        // Expire NAV
        mockVault.expireNAV();
        assertFalse(mockVault.isTotalAssetsValid(), "NAV should be expired");

        // Enable buggy behavior: allow syncDeposit when expired
        mockVault.enableAllowSyncWhenExpired();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositMode.selector
        });

        // Attempt syncDeposit - assertion should catch violation
        vm.expectRevert("Mode violation: syncDeposit called but NAV is expired (should use requestDeposit)");
        vm.prank(user);
        mockVault.syncDeposit(10_000e6, user, address(0));
    }

    /// @notice Test: Assertion fails when requestDeposit is called with valid NAV
    function testModeViolationRequestDepositWhenValid() public {
        // Verify NAV is valid
        assertTrue(mockVault.isTotalAssetsValid(), "NAV should be valid");

        // Enable buggy behavior: allow requestDeposit when valid
        mockVault.enableAllowRequestWhenValid();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionAsyncDepositMode.selector
        });

        // Attempt requestDeposit - assertion should catch violation
        vm.expectRevert("Mode violation: requestDeposit called but NAV is valid (should use syncDeposit)");
        vm.prank(user);
        mockVault.requestDeposit(10_000e6, user, user);
    }

    // ==================== Invariant 4.B: Accounting Violation Tests ====================

    /// @notice Test: Assertion fails when totalAssets is not updated correctly
    function testAccountingViolationTotalAssets() public {
        mockVault.enableBreakTotalAssets();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Attempt syncDeposit - assertion should catch accounting violation
        vm.expectRevert("Accounting violation: totalAssets mismatch");
        vm.prank(user);
        mockVault.syncDeposit(10_000e6, user, address(0));
    }

    /// @notice Test: Assertion fails when Safe balance is not updated correctly
    function testAccountingViolationSafeBalance() public {
        mockVault.enableBreakSafeBalance();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Attempt syncDeposit - assertion should catch balance violation
        vm.expectRevert("Accounting violation: Safe balance mismatch");
        vm.prank(user);
        mockVault.syncDeposit(10_000e6, user, address(0));
    }

    /// @notice Test: Assertion fails when shares minted are incorrect
    /// @dev ERC4626 share conversion formula verification
    function testAccountingViolationSharesMinted() public {
        mockVault.enableBreakSharesMinted();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Attempt syncDeposit - assertion should catch incorrect share calculation
        vm.expectRevert("Accounting violation: totalSupply mismatch");
        vm.prank(user);
        mockVault.syncDeposit(10_000e6, user, address(0));
    }

    // ==================== Invariant 4.C: Epoch Isolation Violation Tests ====================

    /// @notice Test: Assertion fails when syncDeposit changes depositEpochId
    function testEpochIsolationViolationDepositEpochChanged() public {
        mockVault.enableIncrementDepositEpoch();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });

        // Attempt syncDeposit - assertion should catch epoch violation
        vm.expectRevert("Epoch isolation violation: syncDeposit changed depositEpochId");
        vm.prank(user);
        mockVault.syncDeposit(10_000e6, user, address(0));
    }

    /// @notice Test: Assertion fails when syncDeposit affects Silo balance
    function testEpochIsolationViolationSiloAffected() public {
        mockVault.enableAffectSilo();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });

        // Attempt syncDeposit - assertion should catch Silo violation
        vm.expectRevert("Epoch isolation violation: syncDeposit affected Silo balance");
        vm.prank(user);
        mockVault.syncDeposit(10_000e6, user, address(0));
    }

    // ==================== Invariant 4.D: NAV Expiration Violation Tests ====================

    /// @notice Test: Assertion fails when settlement doesn't update totalAssetsExpiration
    function testNAVExpirationViolationNotUpdated() public {
        mockVault.enableSkipExpirationUpdate();

        // Warp time forward so expected expiration would be different
        vm.warp(block.timestamp + 100);

        // Register assertion for settleDeposit
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Attempt settle - assertion should catch expiration violation
        // Expected: block.timestamp (101) + lifespan (1000) = 1101
        // Actual: old expiration (1001) because skipExpirationUpdate is enabled
        vm.expectRevert("NAV expiration violation: expiration not set correctly after settlement");
        mockVault.settleDeposit(10_000e6);
    }

    /// @notice Test: NAV expiration assertion passes when lifespan is 0 (sync mode disabled)
    function testNAVExpirationWithZeroLifespan() public {
        mockVault.setLifespan(0);
        mockVault.enableSkipExpirationUpdate();

        // Register assertion
        cl.assertion({
            adopter: address(mockVault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Should pass because lifespan = 0 means assertion skips check
        mockVault.settleDeposit(10_000e6);
    }
}
