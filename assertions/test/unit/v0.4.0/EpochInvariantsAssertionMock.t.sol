// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EpochInvariantsAssertion} from "../../../src/EpochInvariantsAssertion.a.sol";
import {AssertionBaseTest} from "../../AssertionBaseTest.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {ERC7540} from "@src/v0.4.0/ERC7540.sol";

import "@src/v0.4.0/primitives/Events.sol";
import {VaultHelper} from "@test/v0.4.0/VaultHelper.sol";

/// @title Standalone Mock Vault for Epoch Invariant Testing
/// @notice Minimal vault implementation with configurable buggy epoch behavior
/// @dev Uses same ERC7540 storage layout as real vault to enable assertion testing
contract StandaloneMockVault is ERC20 {
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    struct ERC7540Storage {
        uint256 totalAssets;
        uint256 newTotalAssets;
        uint40 depositEpochId;
        uint40 depositSettleId;
        uint40 lastDepositEpochIdSettled;
        uint40 redeemEpochId;
        uint40 redeemSettleId;
        uint40 lastRedeemEpochIdSettled;
        mapping(uint40 => EpochData) epochs;
        mapping(uint40 => SettleData) settles;
        mapping(address => uint256) lastDepositRequestId;
        mapping(address => uint256) lastRedeemRequestId;
        mapping(uint256 => DepositRequest) depositRequests;
        mapping(uint256 => RedeemRequest) redeemRequests;
    }

    struct EpochData {
        uint40 settleId;
    }

    struct SettleData {
        uint256 pendingAssets;
        uint256 pendingShares;
        uint256 totalAssets;
        uint256 totalSupply;
    }

    struct DepositRequest {
        uint256 assets;
    }

    struct RedeemRequest {
        uint256 shares;
    }

    address public valuationManager;
    address public pendingSilo;
    address public asset;

    bool public shouldUseBuggyIncrementBy1;
    bool public shouldUseBuggyIncrementBy3;
    bool public shouldSkipSettlementOrderingUpdate;

    constructor(address _asset, address _valuationManager, address _pendingSilo) ERC20("Mock Vault", "mVault") {
        asset = _asset;
        valuationManager = _valuationManager;
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

    /// @notice Configures epochs to increment by 1 instead of 2
    function enableBuggyIncrementBy1() external {
        shouldUseBuggyIncrementBy1 = true;
        shouldUseBuggyIncrementBy3 = false;
    }

    /// @notice Configures epochs to increment by 3 instead of 2
    function enableBuggyIncrementBy3() external {
        shouldUseBuggyIncrementBy1 = false;
        shouldUseBuggyIncrementBy3 = true;
    }

    /// @notice Configures settlement to set lastSettled to future epoch
    function enableBuggySettlementOrdering() external {
        shouldSkipSettlementOrderingUpdate = true;
    }

    /// @notice Updates epochs with configurable increment values
    function updateNewTotalAssets(
        uint256 _newTotalAssets
    ) public {
        require(msg.sender == valuationManager, "Only valuation manager");

        ERC7540Storage storage $ = _getERC7540Storage();

        $.epochs[$.depositEpochId].settleId = $.depositSettleId;
        $.epochs[$.redeemEpochId].settleId = $.redeemSettleId;

        uint256 pendingAssets = IERC20(asset).balanceOf(pendingSilo);
        uint256 pendingShares = balanceOf(pendingSilo);

        if (pendingAssets != 0) {
            if (shouldUseBuggyIncrementBy1) {
                $.depositEpochId += 1;
            } else if (shouldUseBuggyIncrementBy3) {
                $.depositEpochId += 3;
            } else {
                $.depositEpochId += 2;
            }
            $.settles[$.depositSettleId].pendingAssets = pendingAssets;
        }

        if (pendingShares != 0) {
            if (shouldUseBuggyIncrementBy1) {
                $.redeemEpochId += 1;
            } else if (shouldUseBuggyIncrementBy3) {
                $.redeemEpochId += 3;
            } else {
                $.redeemEpochId += 2;
            }
            $.settles[$.redeemSettleId].pendingShares = pendingShares;
        }

        $.newTotalAssets = _newTotalAssets;
        emit NewTotalAssetsUpdated(_newTotalAssets);
    }

    function depositEpochId() public view returns (uint40) {
        return _getERC7540Storage().depositEpochId;
    }

    function redeemEpochId() public view returns (uint40) {
        return _getERC7540Storage().redeemEpochId;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    /// @notice Settles deposits with configurable lastSettled value
    function settleDeposit(
        uint256 totalAssets
    ) public {
        require(msg.sender == valuationManager, "Only valuation manager");

        ERC7540Storage storage $ = _getERC7540Storage();

        if (shouldSkipSettlementOrderingUpdate) {
            $.lastDepositEpochIdSettled = $.depositEpochId;
        } else {
            $.lastDepositEpochIdSettled = $.depositEpochId - 2;
        }

        $.depositSettleId++;
        $.settles[$.depositSettleId].totalAssets = totalAssets;
    }

    /// @notice Settles redeems with configurable lastSettled value
    function settleRedeem(
        uint256 totalAssets
    ) public {
        require(msg.sender == valuationManager, "Only valuation manager");

        ERC7540Storage storage $ = _getERC7540Storage();

        if (shouldSkipSettlementOrderingUpdate) {
            $.lastRedeemEpochIdSettled = $.redeemEpochId;
        } else {
            $.lastRedeemEpochIdSettled = $.redeemEpochId - 2;
        }

        $.redeemSettleId++;
        $.settles[$.redeemSettleId].totalAssets = totalAssets;
    }

    function lastDepositEpochIdSettled() public view returns (uint40) {
        return _getERC7540Storage().lastDepositEpochIdSettled;
    }

    function lastRedeemEpochIdSettled() public view returns (uint40) {
        return _getERC7540Storage().lastRedeemEpochIdSettled;
    }
}

/// @title Mock Vault with Epoch Invariant Violations (for parity tests)
/// @notice Test vault that can intentionally violate epoch parity invariants
/// @dev Extends VaultHelper and adds helper functions to corrupt storage for testing
contract MockVaultEpochViolation is VaultHelper {
    constructor(
        bool disable
    ) VaultHelper(disable) {}

    /// @notice Corrupt depositEpochId for testing parity violations
    function corruptDepositEpochId(
        uint40 value
    ) external {
        ERC7540.ERC7540Storage storage $ = _getERC7540Storage();
        $.depositEpochId = value;
    }

    /// @notice Corrupt redeemEpochId for testing parity violations
    function corruptRedeemEpochId(
        uint40 value
    ) external {
        ERC7540.ERC7540Storage storage $ = _getERC7540Storage();
        $.redeemEpochId = value;
    }
}

/// @title EpochInvariantsAssertion Failure Tests
/// @notice Tests that epoch invariants assertions correctly catch violations
/// @dev Tests Invariant #2.1 (Epoch Parity) and #2.3 (Epoch Increments)
contract TestEpochInvariantsAssertionMock is AssertionBaseTest {
    MockVaultEpochViolation public mockVault;
    StandaloneMockVault public standaloneMockVault;

    function setUp() public {
        // Set up base test environment with a normal vault for parity tests
        setUpVault(100, 200, 1000);

        // Deploy mock vault for parity violation tests
        mockVault = new MockVaultEpochViolation(false);
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: "Mock Vault",
            symbol: "MVAULT",
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 200,
            performanceRate: 1000,
            rateUpdateCooldown: 1 days,
            enableWhitelist: true
        });
        mockVault.initialize(abi.encode(initStruct), address(feeRegistry), address(mockWETH));

        // Whitelist essential addresses for mockVault
        address[] memory toWhitelist = new address[](4);
        toWhitelist[0] = feeReceiver.addr;
        toWhitelist[1] = safe.addr;
        toWhitelist[2] = mockVault.pendingSilo();
        toWhitelist[3] = address(feeRegistry);
        vm.prank(whitelistManager.addr);
        mockVault.addToWhitelist(toWhitelist);

        // Deploy standalone mock vault for increment violation tests
        standaloneMockVault = new StandaloneMockVault(address(mockAsset), valuationManager.addr, address(0x1234)); // Simple
            // pending silo address
    }

    // ==================== Invariant #2.1: Epoch Parity Failure Tests ====================

    /// @notice Test: Assertion fails when depositEpochId is even (should be odd)
    function testEpochParityFailsWhenDepositEpochEven() public {
        mockVault.corruptDepositEpochId(2);

        cl.assertion({
            adopter: address(mockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochParity.selector
        });

        vm.expectRevert("Epoch parity violation: deposit epoch must be odd");
        vm.prank(valuationManager.addr);
        mockVault.updateNewTotalAssets(100_000e6);
    }

    /// @notice Test: Assertion fails when redeemEpochId is odd (should be even)
    function testEpochParityFailsWhenRedeemEpochOdd() public {
        mockVault.corruptRedeemEpochId(3);

        cl.assertion({
            adopter: address(mockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochParity.selector
        });

        vm.expectRevert("Epoch parity violation: redeem epoch must be even");
        vm.prank(valuationManager.addr);
        mockVault.updateNewTotalAssets(100_000e6);
    }

    // ==================== Invariant #2.2: Settlement Ordering Failure Tests ====================

    /// @notice Test: Assertion fails when deposit settlement sets lastSettled to future epoch
    function testSettlementOrderingFailsWhenDepositLastSettledSetToFuture() public {
        mockAsset.mint(address(0x1234), 50_000e6);
        vm.prank(valuationManager.addr);
        standaloneMockVault.updateNewTotalAssets(50_000e6);

        assertEq(standaloneMockVault.depositEpochId(), 3);
        assertEq(standaloneMockVault.lastDepositEpochIdSettled(), 0);

        standaloneMockVault.enableBuggySettlementOrdering();

        cl.assertion({
            adopter: address(standaloneMockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSettlementOrdering.selector
        });

        vm.expectRevert("Settlement ordering violation: lastDepositEpochIdSettled > depositEpochId - 2");
        vm.prank(valuationManager.addr);
        standaloneMockVault.settleDeposit(50_000e6);
    }

    /// @notice Test: Assertion fails when redeem settlement sets lastSettled to future epoch
    function testSettlementOrderingFailsWhenRedeemLastSettledSetToFuture() public {
        standaloneMockVault.mint(address(0x1234), 50_000e18);
        vm.prank(valuationManager.addr);
        standaloneMockVault.updateNewTotalAssets(50_000e6);

        assertEq(standaloneMockVault.redeemEpochId(), 4);
        assertEq(standaloneMockVault.lastRedeemEpochIdSettled(), 0);

        standaloneMockVault.enableBuggySettlementOrdering();

        cl.assertion({
            adopter: address(standaloneMockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSettlementOrdering.selector
        });

        vm.expectRevert("Settlement ordering violation: lastRedeemEpochIdSettled > redeemEpochId - 2");
        vm.prank(valuationManager.addr);
        standaloneMockVault.settleRedeem(50_000e6);
    }

    // ==================== Invariant #2.3: Epoch Increments Failure Tests ====================

    /// @notice Test: Assertion fails when deposit epoch increments by 1
    function testEpochIncrementsFailsWhenDepositIncrementsBy1() public {
        mockAsset.mint(address(0x1234), 50_000e6);

        uint40 preEpochId = standaloneMockVault.depositEpochId();
        assertEq(preEpochId, 1);

        standaloneMockVault.enableBuggyIncrementBy1();

        cl.assertion({
            adopter: address(standaloneMockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.expectRevert("Epoch increment violation: deposit epoch must increment by 0 or 2");
        vm.prank(valuationManager.addr);
        standaloneMockVault.updateNewTotalAssets(50_000e6);
    }

    /// @notice Test: Assertion fails when redeem epoch increments by 1
    function testEpochIncrementsFailsWhenRedeemIncrementsBy1() public {
        standaloneMockVault.mint(address(0x1234), 50_000e18);
        standaloneMockVault.enableBuggyIncrementBy1();

        cl.assertion({
            adopter: address(standaloneMockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.expectRevert("Epoch increment violation: redeem epoch must increment by 0 or 2");
        vm.prank(valuationManager.addr);
        standaloneMockVault.updateNewTotalAssets(50_000e6);
    }

    /// @notice Test: Assertion fails when deposit epoch increments by 3
    function testEpochIncrementsFailsWhenDepositIncrementsBy3() public {
        mockAsset.mint(address(0x1234), 50_000e6);
        standaloneMockVault.enableBuggyIncrementBy3();

        cl.assertion({
            adopter: address(standaloneMockVault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.expectRevert("Epoch increment violation: deposit epoch must increment by 0 or 2");
        vm.prank(valuationManager.addr);
        standaloneMockVault.updateNewTotalAssets(50_000e6);
    }
}
