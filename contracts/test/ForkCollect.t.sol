// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {ForkBase} from "./ForkBase.sol";
import {IRecurringCollector, EthSignedMessage} from "./IRecurringCollector.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IStaking {
    function stakeTo(address serviceProvider, uint256 tokens) external;
    function provision(
        address serviceProvider,
        address verifier,
        uint256 tokens,
        uint32 maxVerifierCut,
        uint64 thawingPeriod
    ) external;
    function getProviderTokensAvailable(address serviceProvider, address verifier) external view returns (uint256);
}

interface IEscrow {
    function deposit(address collector, address receiver, uint256 tokens) external;
}

interface ICollect {
    struct CollectParams {
        bytes16 agreementId;
        bytes32 collectionId;
        uint256 tokens;
        uint256 dataServiceCut;
        address receiverDestination;
        uint256 maxSlippage;
    }

    function collect(uint8 paymentType, bytes calldata data) external returns (uint256);
}

/// @notice The other half of the DIPS path: money actually moving.
///
/// `ForkAccept.t.sol` proves an agreement can be accepted. This proves one can be **collected on**,
/// which the tracker listed for two days as blocked on funded escrow. That blocker is real for a
/// broadcast and not for a fork: `deal` mints GRT, and the provision and the escrow deposit are then
/// ordinary calls to the real contracts. Nothing here is mocked.
///
/// Addresses are resolved from the Controller rather than copied, because two of the ones in
/// circulation turned out to be implementations rather than proxies, and calling an implementation
/// does not revert - it returns zero from uninitialised storage, forever, silently.
///
/// Run with:
///   ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --match-path test/ForkCollect.t.sol
contract ForkCollectTest is ForkBase {
    IRecurringCollector constant COLLECTOR = IRecurringCollector(0x0B18beFc60455121Ad66Ae6E4A647955FCde3900);

    // Arbitrum Sepolia, resolved from the Controller on 2026-08-30 and asserted in setUp.
    IERC20 constant GRT = IERC20(0xf8c05dCF59E8B28BFD5eed176C562bEbcfc7Ac04);
    IStaking constant STAKING = IStaking(0x865365C425f3A593Ffe698D9c4E6707D14d51e08);
    IEscrow constant ESCROW = IEscrow(0x4b5D3Da463F7E076bb7CDF5030960bf123245681);

    /// `IGraphPayments.PaymentTypes.IndexingFee`.
    uint8 constant INDEXING_FEE = 2;

    uint256 payerKey;
    address payer;
    address dataService = makeAddr("dataService");
    address serviceProvider = makeAddr("indexer");

    uint256 constant STAKE = 100_000 ether;
    uint256 constant ESCROWED = 50_000 ether;

    function setUp() public {
        forkOrSkip();
        (payer, payerKey) = makeAddrAndKey("payer");

        // A proxy is a few kilobytes; an implementation is tens. Asserted rather than assumed,
        // because the failure mode of getting this wrong is a silent zero rather than a revert.
        assertLt(address(STAKING).code.length, 10_000, "staking address looks like an implementation");
        assertLt(address(ESCROW).code.length, 10_000, "escrow address looks like an implementation");

        _authorizeSelf();
    }

    function _authorizeSelf() internal {
        uint256 proofDeadline = block.timestamp + 1 hours;
        bytes32 messageHash = keccak256(
            abi.encodePacked(block.chainid, address(COLLECTOR), "authorizeSignerProof", proofDeadline, payer)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, EthSignedMessage.hash(messageHash));
        vm.prank(payer);
        COLLECTOR.authorizeSigner(payer, proofDeadline, abi.encodePacked(r, s, v));
    }

    /// The provision is what `_collect` checks before paying anyone: a data service with no
    /// provisioned stake behind it is refused, which is the guard stopping a rogue collector from
    /// draining somebody's escrow.
    function _provision() internal {
        deal(address(GRT), serviceProvider, STAKE);
        vm.startPrank(serviceProvider);
        GRT.approve(address(STAKING), STAKE);
        STAKING.stakeTo(serviceProvider, STAKE);
        // 30 days is refused: the protocol caps the thawing period at ~2,418,000 seconds, and the
        // revert carries both numbers rather than a name, so it reads as an opaque custom error
        // until you convert them. 14 days is comfortably inside.
        STAKING.provision(serviceProvider, dataService, STAKE, 500_000, 14 days);
        vm.stopPrank();
    }

    function _fundEscrow() internal {
        deal(address(GRT), payer, ESCROWED);
        vm.startPrank(payer);
        GRT.approve(address(ESCROW), ESCROWED);
        ESCROW.deposit(address(COLLECTOR), serviceProvider, ESCROWED);
        vm.stopPrank();
    }

    function _rca(uint256 nonce) internal view returns (IRecurringCollector.RecurringCollectionAgreement memory rca) {
        rca = IRecurringCollector.RecurringCollectionAgreement({
            deadline: uint64(block.timestamp + 1 days),
            endsAt: uint64(block.timestamp + 365 days),
            payer: payer,
            dataService: dataService,
            serviceProvider: serviceProvider,
            maxInitialTokens: 0,
            maxOngoingTokensPerSecond: 1 ether,
            minSecondsPerCollection: 60,
            maxSecondsPerCollection: 60 days,
            conditions: 0,
            nonce: nonce,
            metadata: bytes("weaver fork rehearsal")
        });
    }

    function _accept(uint256 nonce) internal returns (bytes16) {
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca(nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, COLLECTOR.hashRCA(rca));
        vm.prank(dataService);
        return COLLECTOR.accept(rca, abi.encodePacked(r, s, v));
    }

    /// **The whole DIPS path, end to end, against deployed contracts.**
    function test_anAcceptedAgreementCanActuallyBeCollectedOn() public {
        _provision();
        _fundEscrow();
        bytes16 id = _accept(1);

        assertGt(
            STAKING.getProviderTokensAvailable(serviceProvider, dataService),
            0,
            "the provision is what makes the data service payable at all"
        );

        // Collection is rate limited by `minSecondsPerCollection`, so time has to pass before there
        // is anything to collect.
        vm.warp(block.timestamp + 1 hours);

        uint256 before = GRT.balanceOf(serviceProvider);
        vm.prank(dataService);
        uint256 collected = ICollect(address(COLLECTOR))
            .collect(
                INDEXING_FEE,
                abi.encode(
                    ICollect.CollectParams({
                    agreementId: id,
                    collectionId: bytes32(0),
                    tokens: 100 ether,
                    dataServiceCut: 0,
                    receiverDestination: serviceProvider,
                    maxSlippage: 100 ether
                })
                )
            );

        assertGt(collected, 0, "nothing was collected");
        assertGt(GRT.balanceOf(serviceProvider), before, "the service provider was not paid");
    }

    /// Without a provision the collector refuses, however well-formed everything else is. This is
    /// the guard named in `RecurringCollector`'s own comment about a signer-as-data-service
    /// syphoning escrow, and it is worth having a test that fails for that reason specifically.
    function test_withoutAProvisionThereIsNothingToCollect() public {
        _fundEscrow();
        bytes16 id = _accept(2);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(dataService);
        vm.expectRevert();
        ICollect(address(COLLECTOR))
            .collect(
                INDEXING_FEE,
                abi.encode(
                    ICollect.CollectParams({
                    agreementId: id,
                    collectionId: bytes32(0),
                    tokens: 100 ether,
                    dataServiceCut: 0,
                    receiverDestination: serviceProvider,
                    maxSlippage: 100 ether
                })
                )
            );
    }

    /// Collecting twice in a row is refused by the rate limit rather than paying twice.
    function test_collectingAgainImmediatelyIsRateLimited() public {
        _provision();
        _fundEscrow();
        bytes16 id = _accept(3);
        vm.warp(block.timestamp + 1 hours);

        ICollect.CollectParams memory p = ICollect.CollectParams({
            agreementId: id,
            collectionId: bytes32(0),
            tokens: 100 ether,
            dataServiceCut: 0,
            receiverDestination: serviceProvider,
            maxSlippage: 100 ether
        });

        vm.prank(dataService);
        ICollect(address(COLLECTOR)).collect(INDEXING_FEE, abi.encode(p));

        vm.prank(dataService);
        vm.expectRevert();
        ICollect(address(COLLECTOR)).collect(INDEXING_FEE, abi.encode(p));
    }
}
