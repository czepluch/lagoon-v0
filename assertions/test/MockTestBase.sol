// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";

/// @title MockERC20
/// @notice Simple mock ERC20 token for testing with configurable decimals
/// @dev Used by mock test contracts to test assertion violations
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

/// @title MockTestBase
/// @notice Base contract for mock assertion tests
/// @dev Provides common test infrastructure for testing assertion violations
///      Mock tests use standalone mock vaults with configurable buggy behavior
///      to verify assertions correctly detect violations
abstract contract MockTestBase is CredibleTest, Test {
// Inherits:
// - CredibleTest: Provides cl.assertion() for testing assertions
// - Test: Provides vm cheatcodes and assertions

// Note: Each mock test contract defines its own standalone mock vault
// implementation with specific flags to enable different violation scenarios
}
