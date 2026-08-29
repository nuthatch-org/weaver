// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

/// Shared fork setup, so both suites agree on the variable name.
///
/// They did not, once: one read `ARBITRUM_SEPOLIA_RPC_URL` and the other `ARBITRUM_SEPOLIA_RPC`,
/// and a run with the wrong one printed `Suite result: ok` having executed nothing at all.
abstract contract ForkBase is Test {
    string constant RPC_VAR = "ARBITRUM_SEPOLIA_RPC_URL";

    /// Skips rather than fails when no RPC is configured: a test that cannot reach the network has
    /// not discovered anything, and reporting that as a failure trains people to ignore it.
    function forkOrSkip() internal {
        try vm.envString(RPC_VAR) returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
        }
    }
}
