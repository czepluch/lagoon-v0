// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiloBalanceConsistencyAssertion} from "../src/SiloBalanceConsistencyAssertion.a.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Simple mock ERC20 for testing
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

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title MockVaultSiloBalance
/// @notice Mock vault with configurable Silo balance violations
contract MockVaultSiloBalance {
    address public asset;
    address public pendingSilo;
    address public safe;

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
        pendingSilo = _silo;
        safe = _safe;
    }

    function requestDeposit(uint256 assets, address controller, address) external returns (uint256) {
        // Transfer from user to this contract
        IERC20(asset).transferFrom(msg.sender, address(this), assets);

        // Violation: Skip transfer to Silo
        if (skipSiloTransferOnRequest) {
            // Assets stay in vault instead of going to Silo
        } else if (doubleSiloTransferOnRequest) {
            // Violation: Transfer 2x to Silo
            IERC20(asset).transfer(pendingSilo, assets);
            IERC20(asset).transfer(pendingSilo, assets);
        } else {
            // Normal: Transfer to Silo
            IERC20(asset).transfer(pendingSilo, assets);
        }

        uint256 requestId = 1;
        emit DepositRequest(controller, msg.sender, requestId, msg.sender, assets);
        return requestId;
    }

    function syncDeposit(uint256 assets, address receiver, address) external payable returns (uint256 shares) {
        // Transfer from user
        IERC20(asset).transferFrom(msg.sender, address(this), assets);

        if (syncDepositAffectsSilo) {
            // Violation: syncDeposit affects Silo (should go to Safe only)
            IERC20(asset).transfer(pendingSilo, assets);
        } else {
            // Normal: Assets go to Safe
            IERC20(asset).transfer(safe, assets);
        }

        shares = assets;
        _mint(receiver, shares);
        emit DepositSync(msg.sender, receiver, assets, shares);
    }

    function balanceOf(address account) public view returns (uint256) {
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
contract TestSiloBalanceConsistencyMock is CredibleTest, Test {
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

        // Should revert because syncDeposit affects Silo
        vm.prank(user);
        vm.expectRevert("Silo isolation violation: syncDeposit incorrectly affected Silo balance");
        vault.syncDeposit(10_000e6, user, address(0));
    }
}
