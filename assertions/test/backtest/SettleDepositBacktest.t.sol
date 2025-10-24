// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TotalAssetsAccountingAssertion_v0_5_0} from "../../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";

/// @title SettleDepositBacktest
/// @notice Backtesting for settleDeposit function with total assets accounting assertion
/// @dev Tests that all historical settleDeposit transactions maintain correct accounting
contract SettleDepositBacktest is CredibleTestWithBacktesting {
    // Vault configuration
    address constant VAULT_ADDRESS = 0xDCD0f5ab30856F28385F641580Bbd85f88349124;
    uint256 constant END_BLOCK = 23_640_730;
    uint256 constant BLOCK_RANGE = 10;

    /// @notice Test settleDeposit historical transactions for accounting correctness
    /// @dev This backtests the critical assertion: postTotalAssets == newTotalAssets + pendingAssets
    function testSettleDepositHistoricalTransactions() public {
        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");

        // Execute backtest
        BacktestingTypes.BacktestingResults memory results = executeBacktest({
            targetContract: VAULT_ADDRESS,
            endBlock: END_BLOCK,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            assertionSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector,
            rpcUrl: rpcUrl
        });

        // Log results
        emit log_named_uint("Total transactions found", results.totalTransactions);
        emit log_named_uint("Processed transactions", results.processedTransactions);
        emit log_named_uint("Successful validations", results.successfulValidations);
        emit log_named_uint("Failed validations", results.failedValidations);
        emit log_named_uint("Assertion failures (violations)", results.assertionFailures);
        emit log_named_uint("Unknown errors", results.unknownErrors);

        // Verify no false positives
        assertEq(results.assertionFailures, 0, "Found protocol violations in settleDeposit!");
        assertEq(results.unknownErrors, 0, "Unexpected errors occurred during backtesting!");

        // Ensure we actually tested some transactions
        if (results.processedTransactions > 0) {
            assertEq(
                results.successfulValidations, results.processedTransactions, "Not all transactions passed validation!"
            );
            emit log_string("All historical settleDeposit transactions passed assertion checks!");
        } else {
            emit log_string("No settleDeposit transactions found in block range");
            emit log_string("    Try increasing BLOCK_RANGE or adjusting END_BLOCK");
        }
    }
}
