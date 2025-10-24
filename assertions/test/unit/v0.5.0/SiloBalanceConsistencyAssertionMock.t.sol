// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiloBalanceConsistencyAssertion} from "../../../src/SiloBalanceConsistencyAssertion.a.sol";
import {MockERC20, MockTestBase} from "../../MockTestBase.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockVaultSiloBalance
/// @notice Mock vault with configurable Silo balance violations
contract MockVaultSiloBalance {
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    struct ERC7540Storage {
        uint256 totalAssets; // slot 0
        uint256 newTotalAssets; // slot 1
        uint40 depositEpochId; // slot 2 (packed)
        uint40 depositSettleId; // slot 2 (packed)
        uint40 lastDepositEpochIdSettled; // slot 2 (packed)
        uint40 redeemEpochId; // slot 3 (packed)
        uint40 redeemSettleId; // slot 3 (packed)
        uint40 lastRedeemEpochIdSettled; // slot 3 (packed)
        // Mappings take 1 slot marker each but data is elsewhere
        mapping(uint40 => bytes32) epochs; // slot 4 (simplified from EpochData)
        mapping(uint40 => bytes32) settles; // slot 5 (simplified from SettleData)
        mapping(address => uint40) lastDepositRequestId; // slot 6
        mapping(address => uint40) lastRedeemRequestId; // slot 7
        mapping(address => mapping(address => bool)) isOperator; // slot 8
        address pendingSilo; // slot 8 (mappings don't consume actual slots)
        address wrappedNativeToken; // next slot
        uint8 decimals;
        uint8 decimalsOffset;
        uint128 totalAssetsExpiration;
        uint128 totalAssetsLifespan;
    }

    address public immutable asset;
    address public immutable safe;

    // Violation flags
    bool public skipSiloTransferOnRequest;
    bool public doubleSiloTransferOnRequest;
    bool public syncDepositAffectsSilo;

    // Events
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event DepositSync(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);

    constructor(address _asset, address _silo, address _safe) {
        asset = _asset;
        safe = _safe;

        ERC7540Storage storage $ = _getERC7540Storage();
        $.pendingSilo = _silo;
    }

    function _getERC7540Storage() private pure returns (ERC7540Storage storage $) {
        assembly {
            $.slot := ERC7540_STORAGE_LOCATION
        }
    }

    function requestDeposit(uint256 assets, address controller, address) external returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();

        // Transfer from user to this contract
        IERC20(asset).transferFrom(msg.sender, address(this), assets);

        // Violation: Skip transfer to Silo
        if (skipSiloTransferOnRequest) {
            // Assets stay in vault instead of going to Silo
        } else if (doubleSiloTransferOnRequest) {
            // Violation: Transfer 2x to Silo
            IERC20(asset).transfer($.pendingSilo, assets);
            IERC20(asset).transfer($.pendingSilo, assets);
        } else {
            // Normal: Transfer to Silo
            IERC20(asset).transfer($.pendingSilo, assets);
        }

        uint256 requestId = 1;
        emit DepositRequest(controller, msg.sender, requestId, msg.sender, assets);
        return requestId;
    }

    function syncDeposit(uint256 assets, address receiver, address) external payable returns (uint256 shares) {
        ERC7540Storage storage $ = _getERC7540Storage();

        // Transfer from user
        IERC20(asset).transferFrom(msg.sender, address(this), assets);

        if (syncDepositAffectsSilo) {
            // Violation: syncDeposit affects Silo (should go to Safe only)
            IERC20(asset).transfer($.pendingSilo, assets);
        } else {
            // Normal: Assets go to Safe
            IERC20(asset).transfer(safe, assets);
        }

        shares = assets;
        _mint(receiver, shares);
        emit DepositSync(msg.sender, receiver, assets, shares);
    }

    function balanceOf(
        address account
    ) public view returns (uint256) {
        // Simplified for testing
        return 0;
    }

    function _mint(address, uint256) internal {
        // Simplified mint
    }

    // Violation setters
    function enableSkipSiloTransferOnRequest() external {
        skipSiloTransferOnRequest = true;
    }

    function enableDoubleSiloTransferOnRequest() external {
        doubleSiloTransferOnRequest = true;
    }

    function enableSyncDepositAffectsSilo() external {
        syncDepositAffectsSilo = true;
    }
}

/// @title TestSiloBalanceConsistencyMock
/// @notice Mock violation tests for Silo Balance Consistency
contract TestSiloBalanceConsistencyMock is MockTestBase {
    MockERC20 public mockAsset;
    MockVaultSiloBalance public vault;
    address public silo;
    address public safe;
    address public user;

    function setUp() public {
        mockAsset = new MockERC20("Mock USDC", "USDC", 6);
        user = address(0x1234);
        silo = address(0x5678);
        safe = address(0x9ABC);

        vault = new MockVaultSiloBalance(address(mockAsset), silo, safe);

        // Mint tokens to user
        mockAsset.mint(user, 100_000e6);

        // User approves vault
        vm.prank(user);
        mockAsset.approve(address(vault), type(uint256).max);
    }

    /// @notice Test: Catches when requestDeposit skips Silo transfer
    function testRequestDepositSkipsSiloTransfer() public {
        // Enable violation
        vault.enableSkipSiloTransferOnRequest();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector
        });

        // Should revert because assets don't go to Silo
        vm.prank(user);
        vm.expectRevert("Silo balance violation: assets not transferred to Silo correctly on requestDeposit");
        vault.requestDeposit(10_000e6, user, user);
    }

    /// @notice Test: Catches when requestDeposit transfers 2x to Silo
    function testRequestDepositDoublesSiloTransfer() public {
        // Enable violation
        vault.enableDoubleSiloTransferOnRequest();

        // Mint extra tokens to vault for the double transfer
        mockAsset.mint(address(vault), 10_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector
        });

        // Should revert because 2x assets go to Silo
        vm.prank(user);
        vm.expectRevert("Silo balance violation: assets not transferred to Silo correctly on requestDeposit");
        vault.requestDeposit(10_000e6, user, user);
    }

    /// @notice Test: Catches when syncDeposit incorrectly affects Silo (v0.5.0)
    function testSyncDepositIncorrectlyAffectsSilo() public {
        // Enable violation
        vault.enableSyncDepositAffectsSilo();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSyncDepositSiloIsolation.selector
        });

        // Should revert because syncDeposit affects Silo (assets don't go to Safe)
        vm.prank(user);
        vm.expectRevert("Silo isolation violation: syncDeposit incorrectly affected Silo balance");
        vault.syncDeposit(10_000e6, user, address(0));
    }
}
