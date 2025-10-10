// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVault
/// @notice Minimal interface for Vault functions used by assertion contracts
/// @dev Used by assertions to register triggers and query vault state
///      Covers both v0.4.0 and v0.5.0 vault functionality
interface IVault {
    // ============ v0.4.0 & v0.5.0 Common Functions ============

    /// @notice Updates the new total assets value
    /// @param newTotalAssets The new total assets value
    function updateNewTotalAssets(uint256 newTotalAssets) external;

    /// @notice Settles deposit requests and mints shares
    /// @param newTotalAssets The new total assets value for settlement
    function settleDeposit(uint256 newTotalAssets) external;

    /// @notice Settles redeem requests and burns shares
    /// @param newTotalAssets The new total assets value for settlement
    function settleRedeem(uint256 newTotalAssets) external;

    /// @notice Request an asynchronous deposit
    /// @param assets Amount of assets to deposit
    /// @param controller Address that will control the deposit
    /// @param owner Address that owns the assets
    /// @return requestId The ID of the deposit request
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Request an asynchronous redemption
    /// @param shares Amount of shares to redeem
    /// @param controller Address that will control the redemption
    /// @param owner Address that owns the shares
    /// @return requestId The ID of the redeem request
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Cancel a pending deposit request
    /// @return assets Amount of assets refunded
    function cancelRequestDeposit() external returns (uint256 assets);

    // ============ v0.5.0 Specific Functions ============

    /// @notice Perform a synchronous deposit (v0.5.0 only)
    /// @param assets Amount of assets to deposit
    /// @param receiver Address that will receive the shares
    /// @param referral Referral address for tracking
    /// @return shares Amount of shares minted
    function syncDeposit(uint256 assets, address receiver, address referral) external payable returns (uint256 shares);

    /// @notice Check if total assets value is still valid (not expired)
    /// @return valid True if NAV is valid, false if expired
    function isTotalAssetsValid() external view returns (bool valid);

    /// @notice Get the expiration timestamp for total assets
    /// @return expiration Timestamp when total assets expires
    function totalAssetsExpiration() external view returns (uint256 expiration);

    /// @notice Get the lifespan duration for total assets validity
    /// @return lifespan Duration in seconds that total assets remains valid
    function totalAssetsLifespan() external view returns (uint256 lifespan);

    /// @notice Update the lifespan for NAV validity (v0.5.0 only)
    /// @param newLifespan New lifespan duration in seconds
    function updateTotalAssetsLifespan(uint128 newLifespan) external;

    /// @notice Manually expire the NAV (v0.5.0 only)
    function expireTotalAssets() external;

    // ============ State Query Functions ============

    /// @notice Get the current deposit epoch ID
    /// @return epochId Current deposit epoch
    function depositEpochId() external view returns (uint40 epochId);

    /// @notice Get the current redeem epoch ID
    /// @return epochId Current redeem epoch
    function redeemEpochId() external view returns (uint40 epochId);

    /// @notice Get the last settled deposit epoch ID
    /// @return epochId Last settled deposit epoch
    function lastDepositEpochIdSettled() external view returns (uint40 epochId);

    /// @notice Get the last settled redeem epoch ID
    /// @return epochId Last settled redeem epoch
    function lastRedeemEpochIdSettled() external view returns (uint40 epochId);

    /// @notice Get the current total assets value
    /// @return totalAssets Current total assets
    function totalAssets() external view returns (uint256 totalAssets);

    /// @notice Get the new total assets value (before settlement)
    /// @return newTotalAssets The new total assets value
    function newTotalAssets() external view returns (uint256 newTotalAssets);

    /// @notice Get the total supply of shares
    /// @return supply Total supply of vault shares
    function totalSupply() external view returns (uint256 supply);

    /// @notice Get the share balance of an account
    /// @param account Address to query
    /// @return balance Share balance of the account
    function balanceOf(address account) external view returns (uint256 balance);

    /// @notice Get the address of the Safe contract
    /// @return safe Address of the Safe
    function safe() external view returns (address safe);

    /// @notice Get the address of the pending Silo contract
    /// @return silo Address of the pending Silo
    function pendingSilo() external view returns (address silo);

    /// @notice Get the underlying asset address
    /// @return asset Address of the underlying asset token
    function asset() external view returns (address asset);

}
