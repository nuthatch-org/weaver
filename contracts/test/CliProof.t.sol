// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ForkBase} from "./ForkBase.sol";
import {IRecurringCollector} from "./IRecurringCollector.sol";

/// Proves the Rust `weaver authorize-proof` encoding is the one the deployed contract accepts.
///
/// The proof below was produced by the CLI and pasted in verbatim. If the Rust changes shape, the
/// bytes stop verifying and this fails. That is the whole point: a proof that is subtly wrong is
/// indistinguishable from a proof that is right, right up until the transaction reverts.
contract CliProofTest is ForkBase {
    IRecurringCollector constant COLLECTOR = IRecurringCollector(0x0B18beFc60455121Ad66Ae6E4A647955FCde3900);

    // anvil key #0, a published test key and nothing else.
    address constant ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 constant DEADLINE = 2_000_000_000;

    // $ weaver authorize-proof --key anvil0.key --authorizer 0xf39F… --deadline 2000000000
    bytes constant PROOF =
        hex"d260384b7e93cf68ca04a339a5c4161c2ee00fcfa02e0bfff51ed1e57f1a825857a6415d7672416ce0778fc6cafab68e401b7678019d7007ff9437061a89842f1b";

    function setUp() public {
        forkOrSkip();
        vm.warp(1_900_000_000); // before the deadline the CLI was given
    }

    function test_theCliProofIsAcceptedByTheDeployedContract() public {
        assertFalse(COLLECTOR.isAuthorized(ACCOUNT, ACCOUNT), "authorized before we asked");
        vm.prank(ACCOUNT);
        COLLECTOR.authorizeSigner(ACCOUNT, DEADLINE, PROOF);
        assertTrue(COLLECTOR.isAuthorized(ACCOUNT, ACCOUNT), "the CLI proof did not take");
    }

    /// The proof is bound to the sender. Someone else replaying it gets nothing.
    function test_theProofCannotBeReplayedByAnotherAccount() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        COLLECTOR.authorizeSigner(ACCOUNT, DEADLINE, PROOF);
    }
}
