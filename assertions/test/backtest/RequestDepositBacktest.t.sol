// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiloBalanceConsistencyAssertion} from "../../src/SiloBalanceConsistencyAssertion.a.sol";

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";

/// @title RequestDepositBacktest
/// @notice Backtesting for requestDeposit function with Silo balance consistency assertion
/// @dev Tests that all historical requestDeposit transactions correctly transfer assets to Silo
contract RequestDepositBacktest is CredibleTestWithBacktesting {
    // Vault configuration
    address constant VAULT_ADDRESS = 0xDCD0f5ab30856F28385F641580Bbd85f88349124;
    uint256 constant END_BLOCK = 23_640_730;
    uint256 constant BLOCK_RANGE = 10;

    /// @notice Test requestDeposit historical transactions for Silo consistency
    /// @dev This backtests the assertion that ensures assets are correctly transferred to Silo
    ///      when users request deposits
    function testRequestDepositHistoricalTransactions() public {
        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");

        // Configure backtest
        BacktestingTypes.BacktestingConfig memory config = BacktestingTypes.BacktestingConfig({
            targetContract: VAULT_ADDRESS,
            endBlock: END_BLOCK,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(SiloBalanceConsistencyAssertion).creationCode,
            assertionSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector,
            rpcUrl: rpcUrl,
            detailedBlocks: false,
            useTraceFilter: false,
            forkByTxHash: true
        });

        // Execute backtest
        BacktestingTypes.BacktestingResults memory results = executeBacktest(config);

        // Verify no false positives
        assertEq(results.assertionFailures, 0, "Found protocol violations in requestDeposit!");
        assertEq(results.unknownErrors, 0, "Unexpected errors occurred during backtesting!");
    }
}
