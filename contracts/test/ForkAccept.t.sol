// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {IRecurringCollector} from "@graphprotocol/interfaces/contracts/horizon/IRecurringCollector.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Exercises the real DIPS agreement path against the **deployed** `RecurringCollector` on
///         Arbitrum Sepolia, via a fork.
///
/// A fork rather than a broadcast for two reasons, and only one of them is that faucets need a
/// human. The other is better: this is deterministic, repeatable and runnable in CI, and it is the
/// same pattern SDSCE used to rehearse its own settlement path. Nothing here is mocked — the
/// contract under test is the one at `0x0b18befc…`, with its real storage and its real code.
///
/// Run with:
///   ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --match-path test/ForkAccept.t.sol
contract ForkAcceptTest is ForkBase {
    IRecurringCollector constant COLLECTOR =
        IRecurringCollector(0x0B18beFc60455121Ad66Ae6E4A647955FCde3900);

    uint256 payerKey;
    address payer;
    address dataService = makeAddr("dataService");
    address serviceProvider = makeAddr("indexer");

    function setUp() public {
        forkOrSkip();
        (payer, payerKey) = makeAddrAndKey("payer");
    }

    /// **The step nobody expects.**
    ///
    /// `_isAuthorized(payer, signer)` requires `authorizations[signer].authorizer == payer`. It
    /// does **not** special-case the signer being the payer, so a payer signing their own
    /// agreement is rejected with `RecurringCollectorInvalidSigner()` until they have authorized
    /// their own key. The error says "invalid signer" about a signature that is cryptographically
    /// perfect, which is a memorable afternoon.
    ///
    /// The proof is a plain `eth_sign` over
    /// `keccak256(chainid, collector, "authorizeSignerProof", deadline, msg.sender)`, signed by
    /// the key being authorized.
    function _authorizeSelf() internal {
        uint256 proofDeadline = block.timestamp + 1 hours;
        bytes32 messageHash = keccak256(
            abi.encodePacked(block.chainid, address(COLLECTOR), "authorizeSignerProof", proofDeadline, payer)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, MessageHashUtils.toEthSignedMessageHash(messageHash));
        vm.prank(payer);
        COLLECTOR.authorizeSigner(payer, proofDeadline, abi.encodePacked(r, s, v));
    }

    function _rca(uint256 nonce) internal view returns (IRecurringCollector.RecurringCollectionAgreement memory rca) {
        rca.deadline = uint64(block.timestamp + 1 days);
        rca.endsAt = uint64(block.timestamp + 365 days);
        rca.payer = payer;
        rca.dataService = dataService;
        rca.serviceProvider = serviceProvider;
        rca.maxInitialTokens = 100e18;
        rca.maxOngoingTokensPerSecond = 1e15;
        rca.minSecondsPerCollection = 1 hours;
        rca.maxSecondsPerCollection = 30 days;
        rca.conditions = 0;
        rca.nonce = nonce;
        rca.metadata = bytes("weaver fork rehearsal");
    }

    function _sign(IRecurringCollector.RecurringCollectionAgreement memory rca)
        internal
        view
        returns (bytes memory)
    {
        // The digest comes from the contract itself, which is the same guarantee weaver's Rust
        // test relies on: we are not asserting our own arithmetic against our own arithmetic.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, COLLECTOR.hashRCA(rca));
        return abi.encodePacked(r, s, v);
    }

    /// The whole point: a payer signs off-chain, the data service accepts on-chain, no gateway
    /// appears anywhere in it.
    function test_theDataServiceCanAcceptAPayerSignedAgreement() public {
        _authorizeSelf();
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(1);
        bytes memory sig = _sign(rca);

        vm.prank(dataService);
        bytes16 id = COLLECTOR.accept(rca, sig);

        assertTrue(id != bytes16(0), "an agreement id should come back");
        console2.log("accepted agreement id:");
        console2.logBytes16(id);
    }

    /// `require(msg.sender == rca.dataService)`. Anyone else holding the same valid signature must
    /// not be able to bind the payer.
    function test_someoneElseCannotAcceptEvenWithAValidSignature() public {
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(2);
        bytes memory sig = _sign(rca);

        _authorizeSelf();
        vm.prank(makeAddr("interloper"));
        vm.expectRevert(); // reverts inside _validateAndStoreAgreement on the msg.sender check
        COLLECTOR.accept(rca, sig);
    }

    /// A signature from the wrong key must not authorise, or `payer` would be decorative.
    function test_aSignatureFromSomeoneOtherThanThePayerIsRejected() public {
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(3);
        (, uint256 otherKey) = makeAddrAndKey("someone else");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, COLLECTOR.hashRCA(rca));

        _authorizeSelf();
        vm.prank(dataService);
        vm.expectRevert(IRecurringCollector.RecurringCollectorInvalidSigner.selector);
        COLLECTOR.accept(rca, abi.encodePacked(r, s, v));
    }

    /// Raising the rate after signing must not verify, or a data service could bind a payer to
    /// terms they never agreed to.
    function test_termsAlteredAfterSigningAreRejected() public {
        _authorizeSelf();
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(4);
        bytes memory sig = _sign(rca);

        rca.maxOngoingTokensPerSecond = 1e21; // a thousand times greedier
        vm.prank(dataService);
        vm.expectRevert(IRecurringCollector.RecurringCollectorInvalidSigner.selector);
        COLLECTOR.accept(rca, sig);
    }

    /// Documented behaviour worth pinning: re-accepting the same agreement is a no-op, not an
    /// error. Somebody will otherwise rediscover it as "my second accept silently did nothing".
    function test_reacceptingTheSameAgreementIsANoOpNotAnError() public {
        _authorizeSelf();
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(5);
        bytes memory sig = _sign(rca);

        vm.startPrank(dataService);
        bytes16 first = COLLECTOR.accept(rca, sig);
        bytes16 again = COLLECTOR.accept(rca, sig);
        vm.stopPrank();

        assertEq(first, again, "the same id comes back, and nothing reverts");
    }

    /// An agreement whose deadline has passed cannot be accepted, however valid the signature.
    function test_anExpiredAgreementCannotBeAccepted() public {
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(6);
        bytes memory sig = _sign(rca);

        vm.warp(rca.deadline + 1);
        vm.prank(dataService);
        vm.expectRevert();
        COLLECTOR.accept(rca, sig);
    }

    /// The finding, pinned so it cannot quietly stop being true: an unauthorized payer signing
    /// their own agreement is rejected, and the error blames the *signer* rather than the missing
    /// authorization. Note the specific error — a bare `expectRevert()` here would pass for any
    /// reason at all, including the ones this test exists to distinguish from.
    function test_aPayerMustAuthorizeTheirOwnKeyBeforeSigningAnything() public {
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(7);
        bytes memory sig = _sign(rca);

        vm.prank(dataService);
        vm.expectRevert(IRecurringCollector.RecurringCollectorInvalidSigner.selector);
        COLLECTOR.accept(rca, sig);

        // Same agreement, same signature, after one authorizeSigner call.
        _authorizeSelf();
        vm.prank(dataService);
        assertTrue(COLLECTOR.accept(rca, sig) != bytes16(0), "identical signature now authorises");
    }

    /// weaver's Rust digest must equal the deployed contract's, on the fork too. This is the same
    /// assertion as the Rust test, made from the other side.
    function test_theDigestFixtureMatchesTheDeployedContract() public view {
        IRecurringCollector.RecurringCollectionAgreement memory rca;
        rca.deadline = 1893456000;
        rca.endsAt = 1924992000;
        rca.payer = 0x1111111111111111111111111111111111111111;
        rca.dataService = 0x2222222222222222222222222222222222222222;
        rca.serviceProvider = 0x3333333333333333333333333333333333333333;
        rca.maxInitialTokens = 1000000000000000000;
        rca.maxOngoingTokensPerSecond = 2000000000;
        rca.minSecondsPerCollection = 3600;
        rca.maxSecondsPerCollection = 86400;
        rca.conditions = 0;
        rca.nonce = 42;
        rca.metadata = hex"deadbeef";

        assertEq(
            COLLECTOR.hashRCA(rca),
            0x0aa74aad34109dd3b276e6258b02bec0ed0a20e4d1f5e5d414ead514dd3428b1,
            "the fixture weaver's Rust test pins must still be what the contract computes"
        );
    }
}
