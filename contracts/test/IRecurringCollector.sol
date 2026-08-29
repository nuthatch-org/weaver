// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// The slice of `RecurringCollector` these tests need, declared locally.
///
/// Vendored rather than imported. Pulling `graphprotocol/contracts` and
/// `openzeppelin-contracts-upgradeable` in whole, plus a nested submodule, to reach one struct and
/// one three-line helper is a poor trade for anyone cloning this.
///
/// The usual objection to a hand-copied interface is that it silently drifts from upstream. It
/// cannot here: every test runs against the deployed bytecode, and a struct whose field order or
/// widths are wrong produces a different `hashRCA`, which fails `test_theDigestFixtureMatches…`
/// immediately. The deployed contract is a stricter oracle than the source file is.
///
/// Copied from the graphprotocol/contracts interfaces package at rev 2629e646.
interface IRecurringCollector {
    struct RecurringCollectionAgreement {
        uint64 deadline;
        uint64 endsAt;
        address payer;
        address dataService;
        address serviceProvider;
        uint256 maxInitialTokens;
        uint256 maxOngoingTokensPerSecond;
        uint32 minSecondsPerCollection;
        uint32 maxSecondsPerCollection;
        uint16 conditions;
        uint256 nonce;
        bytes metadata;
    }

    error RecurringCollectorInvalidSigner();
    error RecurringCollectorAgreementDeadlineElapsed(uint256 currentTimestamp, uint64 deadline);
    error RecurringCollectorUnauthorizedCaller(address unauthorizedCaller, address dataService);

    function accept(
        RecurringCollectionAgreement calldata rca,
        bytes calldata signature
    ) external returns (bytes16 agreementId);

    function hashRCA(RecurringCollectionAgreement calldata rca) external view returns (bytes32);

    function authorizeSigner(address signer, uint256 proofDeadline, bytes calldata proof) external;

    function isAuthorized(address authorizer, address signer) external view returns (bool);
}

/// `MessageHashUtils.toEthSignedMessageHash`, which is all we wanted OpenZeppelin for.
library EthSignedMessage {
    function hash(bytes32 messageHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }
}
