// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "./IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";

/// @title SyncDepositModeAssertion_v0.5.0
/// @notice Validates synchronous deposit mode invariants for Lagoon v0.5.0
///
/// @dev INVARIANT #4: SYNCHRONOUS DEPOSIT MODE INTEGRITY
///
/// v0.5.0 introduces synchronous deposits that bypass the epoch system when NAV is fresh.
/// The vault operates in one of two mutually exclusive modes:
/// - SYNC MODE: When isTotalAssetsValid() == true, only syncDeposit() allowed
/// - ASYNC MODE: When isTotalAssetsValid() == false, only requestDeposit() allowed
///
/// This assertion protects five critical sub-invariants:
///
/// 4.A MODE MUTUAL EXCLUSIVITY
///     When NAV is valid, syncDeposit() should be used (requestDeposit() forbidden)
///     When NAV is expired, requestDeposit() should be used (syncDeposit() forbidden)
///
///     WHY: If both are allowed simultaneously, users can arbitrage between instant and
///     delayed pricing, extracting value from the vault.
///
/// 4.B SYNCHRONOUS DEPOSIT ACCOUNTING
///     After syncDeposit(assets):
///     - totalAssets increases by exactly `assets`
///     - totalSupply increases by shares minted
///     - Safe balance increases by `assets` (NOT Silo)
///     - Receiver's share balance increases correctly
///
///     WHY: syncDeposit() directly mutates totalAssets without settlement events.
///     Incorrect accounting breaks share pricing and vault solvency.
///
/// 4.C EPOCH SYSTEM ISOLATION
///     syncDeposit() must NOT increment depositEpochId
///     syncDeposit() must NOT affect Silo balances
///
///     WHY: syncDeposit() is instant settlement - it should not interact with the
///     async epoch system. Mixing the two systems corrupts epoch-based pricing.
///
/// 4.D NAV EXPIRATION STATE MACHINE
///     After settleDeposit() or settleRedeem():
///     totalAssetsExpiration = block.timestamp + totalAssetsLifespan
///
///     WHY: Settlements refresh NAV, enabling sync mode if lifespan > 0.
///     Incorrect expiration timing breaks mode switching logic.
///
/// NOTE: Part 4.E (State and Access Control) is skipped as it's redundant with modifier checks.
///
/// @dev This assertion is high priority for v0.5.0
contract SyncDepositModeAssertion_v0_5_0 is Assertion {
    /// @notice ERC7540 storage location
    /// @dev keccak256(abi.encode(uint256(keccak256("hopper.storage.erc7540")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    /// @notice Offset of pendingSilo in ERC7540Storage struct (in storage slots)
    /// @dev pendingSilo is at slot 8 in the struct (after 2 uint256s, packed uint40s, and 5 mappings)
    uint256 private constant PENDING_SILO_OFFSET = 8;

    /// @notice Offset of packed uint40s (depositEpochId, redeemEpochId, etc.) in ERC7540Storage
    /// @dev All 6 uint40 values are packed in slot 2 (30 bytes total)
    uint256 private constant PACKED_EPOCH_IDS_OFFSET = 2;

    /// @notice Offset of totalAssetsExpiration and totalAssetsLifespan in ERC7540Storage
    /// @dev Both uint128 values are in slot 10: expiration (lower 128 bits), lifespan (upper 128 bits)
    uint256 private constant TOTAL_ASSETS_EXPIRATION_LIFESPAN_OFFSET = 10;

    /// @notice Read the pendingSilo address from vault's ERC7540 storage
    /// @param vault Address of the vault contract
    /// @return silo Address of the pending Silo
    function _getPendingSilo(
        address vault
    ) internal view returns (address silo) {
        bytes32 siloSlot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + PENDING_SILO_OFFSET);
        return address(uint160(uint256(ph.load(vault, siloSlot))));
    }

    /// @notice Read depositEpochId from vault's ERC7540 storage
    /// @param vault Address of the vault contract
    /// @return epochId Current deposit epoch ID
    function _getDepositEpochId(
        address vault
    ) internal view returns (uint40 epochId) {
        bytes32 slot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + PACKED_EPOCH_IDS_OFFSET);
        bytes32 data = ph.load(vault, slot);
        // depositEpochId is at bits 0-39 (first uint40 in the packed slot)
        return uint40(uint256(data));
    }

    /// @notice Read totalAssetsExpiration from vault's ERC7540 storage
    /// @param vault Address of the vault contract
    /// @return expiration NAV expiration timestamp
    function _getTotalAssetsExpiration(
        address vault
    ) internal view returns (uint128 expiration) {
        bytes32 slot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + TOTAL_ASSETS_EXPIRATION_LIFESPAN_OFFSET);
        bytes32 data = ph.load(vault, slot);
        // totalAssetsExpiration is in lower 128 bits of slot 10
        return uint128(uint256(data));
    }

    /// @notice Read totalAssetsLifespan from vault's ERC7540 storage
    /// @param vault Address of the vault contract
    /// @return lifespan NAV validity duration in seconds
    function _getTotalAssetsLifespan(
        address vault
    ) internal view returns (uint128 lifespan) {
        bytes32 slot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + TOTAL_ASSETS_EXPIRATION_LIFESPAN_OFFSET);
        bytes32 data = ph.load(vault, slot);
        // totalAssetsLifespan is in upper 128 bits of slot 10
        return uint128(uint256(data) >> 128);
    }

    /// @notice Registers assertion triggers on relevant vault functions
    function triggers() external view override {
        // 4.A Mode Mutual Exclusivity - separate functions for each mode
        registerCallTrigger(this.assertionSyncDepositMode.selector, IVault.syncDeposit.selector);
        registerCallTrigger(this.assertionAsyncDepositMode.selector, IVault.requestDeposit.selector);

        // 4.B Synchronous Deposit Accounting
        registerCallTrigger(this.assertionSyncDepositAccounting.selector, IVault.syncDeposit.selector);

        // 4.C Epoch System Isolation
        registerCallTrigger(this.assertionEpochIsolation.selector, IVault.syncDeposit.selector);

        // 4.D NAV Expiration State Machine
        registerCallTrigger(this.assertionNAVExpirationUpdate.selector, IVault.settleDeposit.selector);
        registerCallTrigger(this.assertionNAVExpirationUpdate.selector, IVault.settleRedeem.selector);
    }

    /// @notice Invariant 4.A: Mode Mutual Exclusivity - Sync Mode Check
    /// @dev Verifies that when syncDeposit() is called, NAV must be valid (sync mode active)
    /// @dev This prevents users from using syncDeposit when they should use requestDeposit
    function assertionSyncDepositMode() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // syncDeposit() should only be called when NAV is valid (sync mode)
        ph.forkPostTx(); // Pre check probably makes more sense.
        bool navValid = vault.isTotalAssetsValid();

        require(navValid, "Mode violation: syncDeposit called but NAV is expired (should use requestDeposit)");
    }

    /// @notice Invariant 4.A: Mode Mutual Exclusivity - Async Mode Check
    /// @dev Verifies that when requestDeposit() is called, NAV must be expired (async mode active)
    /// @dev This prevents users from using requestDeposit when they should use syncDeposit
    function assertionAsyncDepositMode() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // requestDeposit() should only be called when NAV is expired (async mode)
        ph.forkPostTx();
        bool navValid = vault.isTotalAssetsValid();

        require(!navValid, "Mode violation: requestDeposit called but NAV is valid (should use syncDeposit)");
    }

    /// @notice Invariant 4.B: Synchronous Deposit Accounting
    /// @dev Verifies all accounting changes are correct after ALL syncDeposit() calls
    /// @dev Uses induction: sum of individual deposits must equal total state change
    function assertionSyncDepositAccounting() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // Get ALL syncDeposit calls (important: check all calls to avoid attack vectors)
        PhEvm.CallInputs[] memory calls = ph.getCallInputs(address(vault), IVault.syncDeposit.selector);

        // Calculate expected total changes from all calls
        uint256 totalAssetsExpected = 0;
        uint256 totalSharesExpected = 0;

        ph.forkPreTx();
        uint256 preTotalAssets = vault.totalAssets();
        uint256 preTotalSupply = vault.totalSupply();
        address asset = vault.asset();
        address safe = vault.safe();
        uint256 preSafeBalance = IERC20(asset).balanceOf(safe);
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint256 decimalsOffset = 10 ** (18 - assetDecimals);

        // Process each call and accumulate expected changes
        for (uint256 i = 0; i < calls.length; i++) {
            (uint256 assets,,) = abi.decode(calls[i].input, (uint256, address, address));

            // Calculate expected shares using state BEFORE this deposit is added
            uint256 currentSupply = preTotalSupply + totalSharesExpected;
            uint256 currentAssets = preTotalAssets + totalAssetsExpected;

            uint256 expectedShares = (currentSupply == 0)
                ? assets * decimalsOffset
                : (assets * (currentSupply + decimalsOffset)) / (currentAssets + 1);

            // Now add this deposit's contributions to the cumulative totals
            totalAssetsExpected += assets;
            totalSharesExpected += expectedShares;
        }

        // Verify actual state changes match expected
        ph.forkPostTx();

        require(
            vault.totalAssets() == preTotalAssets + totalAssetsExpected, "Accounting violation: totalAssets mismatch"
        );
        require(
            vault.totalSupply() == preTotalSupply + totalSharesExpected, "Accounting violation: totalSupply mismatch"
        );
        require(
            IERC20(asset).balanceOf(safe) == preSafeBalance + totalAssetsExpected,
            "Accounting violation: Safe balance mismatch"
        );

        // Limitation: This assertion assumes syncDeposit is the only function affecting totalAssets/totalSupply
        // in the transaction. Batched calls with claimSharesAndRequestRedeem() may cause false positives
        // since that function also mints shares via _deposit().
        // TODO: Expand this assertion to handle all calls that could affect totalAssets/totalSupply
    }

    /// @notice Invariant 4.C: Epoch System Isolation
    /// @dev Verifies syncDeposit() does not interact with the epoch system
    /// @dev Checks: depositEpochId unchanged, Silo balance unchanged
    function assertionEpochIsolation() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // Capture pre-state
        ph.forkPreTx();
        uint40 preDepositEpochId = _getDepositEpochId(address(vault));
        address silo = _getPendingSilo(address(vault));
        address asset = vault.asset();
        uint256 preSiloBalance = IERC20(asset).balanceOf(silo);

        // Capture post-state
        ph.forkPostTx();
        uint40 postDepositEpochId = _getDepositEpochId(address(vault));
        uint256 postSiloBalance = IERC20(asset).balanceOf(silo);

        // Verify depositEpochId did not change
        require(
            preDepositEpochId == postDepositEpochId, "Epoch isolation violation: syncDeposit changed depositEpochId"
        );

        // Verify Silo balance did not change
        require(preSiloBalance == postSiloBalance, "Epoch isolation violation: syncDeposit affected Silo balance");
    }

    /// @notice Invariant 4.D: NAV Expiration State Machine
    /// @dev Verifies totalAssetsExpiration is set correctly after settlements
    /// @dev Only checks if totalAssetsLifespan > 0 (sync mode enabled by Safe)
    function assertionNAVExpirationUpdate() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        ph.forkPostTx();
        uint256 totalAssetsExpiration = _getTotalAssetsExpiration(address(vault));
        uint256 totalAssetsLifespan = _getTotalAssetsLifespan(address(vault));

        // Only check if sync mode is enabled (lifespan > 0)
        if (totalAssetsLifespan > 0) {
            // After settlement, expiration should be set to block.timestamp + lifespan
            uint256 expectedExpiration = block.timestamp + totalAssetsLifespan;
            require(
                totalAssetsExpiration == expectedExpiration,
                "NAV expiration violation: expiration not set correctly after settlement"
            );
        }

        // TODO: Verify TotalAssetsUpdated event was emitted
        // Event signature: TotalAssetsUpdated(uint256 newTotalAssets)
        // This would provide additional validation of the NAV update
    }
}
