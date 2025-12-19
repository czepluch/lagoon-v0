// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiloBalanceConsistencyAssertion} from "../../src/SiloBalanceConsistencyAssertion.a.sol";

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";

/// @title RequestRedeemBacktest
/// @notice Backtesting for requestRedeem function with Silo balance consistency assertion
/// @dev Tests that all historical requestRedeem transactions correctly transfer shares to Silo
contract RequestRedeemBacktest is CredibleTestWithBacktesting {
    // Vault configuration
    address constant VAULT_ADDRESS = 0xDCD0f5ab30856F28385F641580Bbd85f88349124;
    uint256 constant END_BLOCK = 24_046_293;
    uint256 constant BLOCK_RANGE = 10;

    /// @notice Test requestRedeem historical transactions for Silo consistency
    /// @dev This backtests the assertion that ensures shares are correctly transferred to Silo
    ///      when users request redemptions
    function testRequestRedeemHistoricalTransactions() public {
        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");

        // Configure backtest
        BacktestingTypes.BacktestingConfig memory config = BacktestingTypes.BacktestingConfig({
            targetContract: VAULT_ADDRESS,
            endBlock: END_BLOCK,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(SiloBalanceConsistencyAssertion).creationCode,
            assertionSelector: SiloBalanceConsistencyAssertion.assertionRequestRedeemSiloBalance.selector,
            rpcUrl: rpcUrl,
            detailedBlocks: false,
            useTraceFilter: false,
            forkByTxHash: true
        });

        // Execute backtest
        BacktestingTypes.BacktestingResults memory results = executeBacktest(config);

        // Verify no false positives
        assertEq(results.assertionFailures, 0, "Found protocol violations in requestRedeem!");
        assertEq(results.unknownErrors, 0, "Unexpected errors occurred during backtesting!");
    }
}
