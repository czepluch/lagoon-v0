// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {NAVValidityAssertion_v0_5_0} from "../src/NAVValidityAssertion_v0.5.0.a.sol";
import {IVault} from "../src/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Asset", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Standalone Mock Vault for NAV Validity Testing
/// @notice Minimal vault implementation with configurable buggy NAV lifecycle behavior
/// @dev Uses flags to enable different violations of Invariant #5
contract StandaloneMockVaultNAV is ERC20 {
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
    address private immutable _pendingSilo;

    // Flags to control buggy behavior
    bool public shouldReturnInconsistentValidity;      // Violates 5.A (returns wrong isTotalAssetsValid)
    bool public validityInconsistentValue;             // Value to return when inconsistent
    bool public shouldSkipExpirationUpdate;            // Violates 5.C (doesn't set expiration after settlement)
    bool public shouldSkipLifespanEvent;               // Violates 5.D (doesn't emit event)
    bool public shouldSetWrongExpiration;              // Violates 5.E (doesn't set to 0)

    event TotalAssetsLifespanUpdated(uint128 oldLifespan, uint128 newLifespan);
    event TotalAssetsUpdated(uint256 totalAssets);
    event SettleDeposit(
        uint40 indexed epochId,
        uint40 indexed settledId,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 assetsDeposited,
        uint256 sharesMinted
    );

    constructor(address _asset, address _safe, address pendingSiloAddr) ERC20("Mock Vault NAV", "mVaultNAV") {
        asset = _asset;
        safe = _safe;
        _pendingSilo = pendingSiloAddr;

        ERC7540Storage storage $ = _getERC7540Storage();
        $.depositEpochId = 1;
        $.redeemEpochId = 2;
        $.totalAssetsLifespan = 0; // Default async-only mode
        $.totalAssetsExpiration = 0;
    }

    function _getERC7540Storage() private pure returns (ERC7540Storage storage $) {
        assembly {
            $.slot := ERC7540_STORAGE_LOCATION
        }
    }

    // ============ Flag Configuration Functions ============

    function enableInconsistentValidity(bool returnValue) external {
        shouldReturnInconsistentValidity = true;
        validityInconsistentValue = returnValue;
    }

    function enableSkipExpirationUpdate() external {
        shouldSkipExpirationUpdate = true;
    }

    function enableSkipLifespanEvent() external {
        shouldSkipLifespanEvent = true;
    }

    function enableSetWrongExpiration() external {
        shouldSetWrongExpiration = true;
    }

    // ============ Core Vault Functions ============

    /// @notice Check if total assets is valid
    function isTotalAssetsValid() public view returns (bool) {
        if (shouldReturnInconsistentValidity) {
            return validityInconsistentValue; // Buggy: return wrong value
        }

        ERC7540Storage storage $ = _getERC7540Storage();
        return ($.totalAssetsExpiration > 0) && (block.timestamp < $.totalAssetsExpiration);
    }

    /// @notice Update NAV (simplified for testing)
    function updateNewTotalAssets(uint256 newValue) external {
        ERC7540Storage storage $ = _getERC7540Storage();
        $.newTotalAssets = newValue;
        $.totalAssets = newValue;
        emit TotalAssetsUpdated(newValue);
    }

    /// @notice Settle deposit (simplified)
    function settleDeposit(uint256 newTotalAssets) external {
        ERC7540Storage storage $ = _getERC7540Storage();
        $.totalAssets = newTotalAssets;

        // Update expiration (buggy or correct)
        if (!shouldSkipExpirationUpdate) {
            if ($.totalAssetsLifespan > 0) {
                $.totalAssetsExpiration = uint128(block.timestamp + $.totalAssetsLifespan);
            } else {
                $.totalAssetsExpiration = 0;
            }
        }
        // If shouldSkipExpirationUpdate is true, expiration is not updated (violation)

        emit TotalAssetsUpdated(newTotalAssets);
        emit SettleDeposit(1, 1, newTotalAssets, totalSupply(), 0, 0);
    }

    /// @notice Settle redeem (simplified)
    function settleRedeem(uint256 newTotalAssets) external {
        ERC7540Storage storage $ = _getERC7540Storage();
        $.totalAssets = newTotalAssets;

        // Update expiration (buggy or correct)
        if (!shouldSkipExpirationUpdate) {
            if ($.totalAssetsLifespan > 0) {
                $.totalAssetsExpiration = uint128(block.timestamp + $.totalAssetsLifespan);
            } else {
                $.totalAssetsExpiration = 0;
            }
        }

        emit TotalAssetsUpdated(newTotalAssets);
    }

    /// @notice Update lifespan
    function updateTotalAssetsLifespan(uint128 newLifespan) external {
        ERC7540Storage storage $ = _getERC7540Storage();
        uint128 oldLifespan = $.totalAssetsLifespan;
        $.totalAssetsLifespan = newLifespan;

        // Emit event (unless buggy flag is set)
        if (!shouldSkipLifespanEvent) {
            emit TotalAssetsLifespanUpdated(oldLifespan, newLifespan);
        }
    }

    /// @notice Manually expire NAV
    function expireTotalAssets() external {
        ERC7540Storage storage $ = _getERC7540Storage();

        if (shouldSetWrongExpiration) {
            $.totalAssetsExpiration = 1; // Buggy: set to 1 instead of 0
        } else {
            $.totalAssetsExpiration = 0; // Correct
        }
    }

    // ============ View Functions ============

    function totalAssets() public view returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.totalAssets;
    }

    function totalAssetsExpiration() public view returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.totalAssetsExpiration;
    }

    function totalAssetsLifespan() public view returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.totalAssetsLifespan;
    }

    function depositEpochId() public view returns (uint40) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.depositEpochId;
    }

    function pendingSilo() public view returns (address) {
        return _pendingSilo;
    }
}

/// @title TestNAVValidityAssertionMock
/// @notice Tests that NAV validity assertions catch violations
/// @dev Each test enables a specific violation flag and verifies the assertion reverts
contract TestNAVValidityAssertionMock is CredibleTest, Test {
    MockERC20 public mockAsset;
    StandaloneMockVaultNAV public vault;
    address public mockSafe = address(0x1234);
    address public mockSilo = address(0x5678);

    function setUp() public {
        mockAsset = new MockERC20();
        vault = new StandaloneMockVaultNAV(address(mockAsset), mockSafe, mockSilo);

        mockAsset.mint(address(this), 1_000_000e18);
        mockAsset.approve(address(vault), type(uint256).max);
    }

    // ============================================================================
    // VIOLATION TESTS
    // ============================================================================

    /// @notice Test: Assertion catches isTotalAssetsValid() returning true when expiration is 0
    function testValidityInconsistentReturnsTrue() public {
        // Setup: Enable buggy validity check that returns true when should be false
        vault.enableInconsistentValidity(true); // Force return true
        // totalAssetsExpiration is 0, so should return false but returns true

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Update NAV (triggers consistency check)
        vm.expectRevert("NAV validity violation: isTotalAssetsValid() result inconsistent with totalAssetsExpiration");
        vault.updateNewTotalAssets(50_000e18);
    }

    /// @notice Test: Assertion catches isTotalAssetsValid() returning false when should be true
    function testValidityInconsistentReturnsFalse() public {
        // Setup: Set lifespan and settle to create valid NAV
        vault.updateTotalAssetsLifespan(1000);
        vault.settleDeposit(50_000e18);

        // Enable buggy validity check that returns false when should be true
        vault.enableInconsistentValidity(false); // Force return false
        // totalAssetsExpiration > block.timestamp, so should return true but returns false

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Settle deposit again (triggers consistency check)
        vm.expectRevert("NAV validity violation: isTotalAssetsValid() result inconsistent with totalAssetsExpiration");
        vault.settleDeposit(60_000e18);
    }

    /// @notice Test: Assertion catches missing expiration update after settlement
    function testExpirationNotSetAfterSettlement() public {
        // Setup: Set lifespan to enable sync mode
        vault.updateTotalAssetsLifespan(1000);

        // Enable bug: skip expiration update
        vault.enableSkipExpirationUpdate();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle deposit (should set expiration but doesn't due to bug)
        vm.expectRevert("Expiration violation: totalAssetsExpiration not set correctly after settlement");
        vault.settleDeposit(50_000e18);
    }

    /// @notice Test: Assertion catches missing TotalAssetsLifespanUpdated event
    function testLifespanEventNotEmitted() public {
        // Enable bug: skip event emission
        vault.enableSkipLifespanEvent();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionLifespanUpdate.selector
        });

        // Action: Update lifespan (should emit event but doesn't due to bug)
        vm.expectRevert("Lifespan violation: TotalAssetsLifespanUpdated event not emitted");
        vault.updateTotalAssetsLifespan(1000);
    }

    /// @notice Test: Assertion catches expireTotalAssets() not setting expiration to 0
    function testManualExpirationDoesntSetZero() public {
        // Setup: Set lifespan and settle to create valid NAV
        vault.updateTotalAssetsLifespan(1000);
        vault.settleDeposit(50_000e18);

        // Verify NAV is valid
        assertTrue(vault.isTotalAssetsValid(), "NAV should be valid");

        // Enable bug: set wrong expiration value
        vault.enableSetWrongExpiration();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionManualExpiration.selector
        });

        // Action: Expire NAV (should set to 0 but sets to 1 due to bug)
        vm.expectRevert("Manual expiration violation: totalAssetsExpiration not set to 0");
        vault.expireTotalAssets();
    }
}
