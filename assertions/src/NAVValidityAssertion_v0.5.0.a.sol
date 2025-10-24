// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "./IVault.sol";
import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";

/// @title NAVValidityAssertion_v0.5.0
/// @notice Validates NAV validity and expiration lifecycle for Lagoon v0.5.0
///
/// @dev INVARIANT #5: NAV VALIDITY AND EXPIRATION LIFECYCLE
///
/// v0.5.0 introduces a time-based NAV expiration system that controls mode switching.
/// The totalAssetsExpiration timestamp determines whether sync or async deposits are allowed.
///
/// This assertion protects five critical sub-invariants:
///
/// 5.A NAV VALIDITY CONSISTENCY
///     isTotalAssetsValid() must return: block.timestamp < totalAssetsExpiration
///     - When totalAssetsExpiration == 0: always returns false (async mode)
///     - When totalAssetsExpiration > 0 and block.timestamp >= totalAssetsExpiration: returns false (expired)
///     - When totalAssetsExpiration > block.timestamp: returns true (sync mode active)
///
///     WHY: isTotalAssetsValid() is the source of truth for mode enforcement. If it returns
///     incorrect values, users could deposit in wrong mode or be blocked from valid operations.
///
/// 5.B NAV UPDATE ACCESS CONTROL
///     When isTotalAssetsValid() == true: updateNewTotalAssets() must NOT be called
///     When isTotalAssetsValid() == false: updateNewTotalAssets() allowed
///
///     WHY: Prevents NAV updates during sync deposit window. If NAV changes mid-window,
///     users who deposited early get different pricing than advertised, enabling arbitrage.
///
/// 5.C EXPIRATION TIMESTAMP AFTER SETTLEMENT
///     After settleDeposit() or settleRedeem():
///     totalAssetsExpiration = block.timestamp + totalAssetsLifespan
///     (or 0 if totalAssetsLifespan == 0)
///
///     WHY: Settlements refresh NAV, enabling sync mode if lifespan > 0. Incorrect
///     expiration timing breaks mode switching logic and sync deposit window.
///
/// 5.D LIFESPAN UPDATE VERIFICATION
///     When Safe calls updateTotalAssetsLifespan():
///     - TotalAssetsLifespanUpdated event must be emitted
///     - totalAssetsLifespan must match new value
///
///     WHY: Lifespan controls whether sync mode is enabled. Safe must be able to
///     configure this correctly and changes must be transparent via events.
///
/// 5.E MANUAL EXPIRATION VERIFICATION
///     When Safe calls expireTotalAssets():
///     - totalAssetsExpiration must be set to 0
///     - isTotalAssetsValid() must return false
///
///     WHY: Safe needs emergency control to force async mode during market volatility
///     or operational issues. This immediately disables sync deposits.
///
/// @dev This assertion is high priority for v0.5.0 - checked on every NAV lifecycle operation
contract NAVValidityAssertion_v0_5_0 is Assertion {
    /// @notice ERC7540 storage location
    /// @dev keccak256(abi.encode(uint256(keccak256("hopper.storage.erc7540")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    /// @notice Offset of totalAssetsExpiration and totalAssetsLifespan in ERC7540Storage
    /// @dev Both uint128 values are in slot 10: expiration (lower 128 bits), lifespan (upper 128 bits)
    uint256 private constant TOTAL_ASSETS_EXPIRATION_LIFESPAN_OFFSET = 10;

    /// @notice Event signatures for parsing logs
    bytes32 private constant LIFESPAN_UPDATED_SIG = keccak256("TotalAssetsLifespanUpdated(uint128,uint128)");

    /// @notice Registers assertion triggers on relevant vault functions
    function triggers() external view override {
        // 5.A NAV Validity Consistency
        registerCallTrigger(this.assertionIsTotalAssetsValidConsistency.selector, IVault.updateNewTotalAssets.selector);
        registerCallTrigger(this.assertionIsTotalAssetsValidConsistency.selector, IVault.settleDeposit.selector);
        registerCallTrigger(this.assertionIsTotalAssetsValidConsistency.selector, IVault.settleRedeem.selector);
        registerCallTrigger(this.assertionIsTotalAssetsValidConsistency.selector, IVault.expireTotalAssets.selector);

        // 5.B NAV Update Access Control
        registerCallTrigger(this.assertionNAVUpdateAccessControl.selector, IVault.updateNewTotalAssets.selector);

        // 5.C Expiration Timestamp After Settlement
        registerCallTrigger(this.assertionExpirationSetAfterSettlement.selector, IVault.settleDeposit.selector);
        registerCallTrigger(this.assertionExpirationSetAfterSettlement.selector, IVault.settleRedeem.selector);

        // 5.D Lifespan Update Verification
        registerCallTrigger(this.assertionLifespanUpdate.selector, IVault.updateTotalAssetsLifespan.selector);

        // 5.E Manual Expiration Verification
        registerCallTrigger(this.assertionManualExpiration.selector, IVault.expireTotalAssets.selector);
    }

    /// @notice Invariant 5.A: NAV Validity Consistency
    /// @dev Verifies isTotalAssetsValid() returns consistent result based on totalAssetsExpiration
    function assertionIsTotalAssetsValidConsistency() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        ph.forkPostTx();
        uint256 expiration = _getTotalAssetsExpiration(address(vault));
        bool actual = vault.isTotalAssetsValid();

        // Calculate expected result: valid only if expiration > 0 AND block.timestamp < expiration
        bool expected = (expiration > 0) && (block.timestamp < expiration);

        require(
            actual == expected,
            "NAV validity violation: isTotalAssetsValid() result inconsistent with totalAssetsExpiration"
        );
    }

    /// @notice Invariant 5.B: NAV Update Access Control
    /// @dev Verifies updateNewTotalAssets() is only called when NAV is expired
    /// @dev This prevents NAV updates during sync deposit window
    function assertionNAVUpdateAccessControl() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // Check NAV validity BEFORE the transaction
        ph.forkPreTx();
        bool navValidBefore = vault.isTotalAssetsValid();

        require(!navValidBefore, "Access control violation: updateNewTotalAssets() called while NAV is still valid");
    }

    /// @notice Invariant 5.C: Expiration Timestamp After Settlement
    /// @dev Verifies totalAssetsExpiration is set correctly after settlement
    function assertionExpirationSetAfterSettlement() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        ph.forkPostTx();
        uint256 expiration = _getTotalAssetsExpiration(address(vault));
        uint256 lifespan = _getTotalAssetsLifespan(address(vault));

        if (lifespan > 0) {
            // If lifespan is set, expiration should be block.timestamp + lifespan
            uint256 expected = block.timestamp + lifespan;
            require(
                expiration == expected, "Expiration violation: totalAssetsExpiration not set correctly after settlement"
            );
        } else {
            // If lifespan is 0, expiration should be block.timestamp or 0 (both mean expired)
            // Vault implementation sets it to block.timestamp + 0 = block.timestamp
            require(
                expiration <= block.timestamp,
                "Expiration violation: totalAssetsExpiration should be expired when lifespan is 0"
            );
        }
    }

    /// @notice Invariant 5.D: Lifespan Update Verification
    /// @dev Verifies TotalAssetsLifespanUpdated event is emitted and state is updated correctly
    function assertionLifespanUpdate() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // Parse TotalAssetsLifespanUpdated event
        PhEvm.Log[] memory logs = ph.getLogs();
        bool eventFound = false;
        uint128 newLifespan = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault)) {
                if (logs[i].topics[0] == LIFESPAN_UPDATED_SIG) {
                    (, uint128 newLifespanFromEvent) = abi.decode(logs[i].data, (uint128, uint128));
                    newLifespan = newLifespanFromEvent;
                    eventFound = true;
                    break;
                }
            }
        }

        require(eventFound, "Lifespan violation: TotalAssetsLifespanUpdated event not emitted");

        // Verify vault state matches event
        ph.forkPostTx();
        uint256 actualLifespan = _getTotalAssetsLifespan(address(vault));
        require(
            actualLifespan == uint256(newLifespan),
            "Lifespan violation: totalAssetsLifespan doesn't match emitted event"
        );
    }

    /// @notice Invariant 5.E: Manual Expiration Verification
    /// @dev Verifies expireTotalAssets() sets expiration to 0 and invalidates NAV
    function assertionManualExpiration() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        ph.forkPostTx();
        uint256 expiration = _getTotalAssetsExpiration(address(vault));
        bool navValid = vault.isTotalAssetsValid();

        require(expiration == 0, "Manual expiration violation: totalAssetsExpiration not set to 0");
        require(!navValid, "Manual expiration violation: isTotalAssetsValid() should return false");
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
}
