// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimPay} from "../src/ClaimPay.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ClaimPayTest is Test {
    ClaimPay internal claimpay;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal arbiter = makeAddr("arbiter");

    uint64 internal constant DEADLINE = 3 days;

    event AgreementCreated(
        uint256 indexed id,
        address indexed client,
        address indexed provider,
        address token,
        address arbiter,
        uint256 totalAmount,
        uint256 milestoneCount
    );
    event AgreementSigned(uint256 indexed id, address indexed provider);
    event MilestoneStarted(uint256 indexed id, uint256 indexed index);
    event MilestoneSubmitted(uint256 indexed id, uint256 indexed index, bytes32 deliverableHash);
    event RevisionRequested(uint256 indexed id, uint256 indexed index);
    event MilestonePaid(
        uint256 indexed id, uint256 indexed index, address indexed client, address provider, uint256 amount
    );
    event DisputeOpened(uint256 indexed id, uint256 indexed index, address indexed opener);
    event DisputeResolved(
        uint256 indexed id, uint256 indexed index, address client, address provider, uint256 amountToProvider
    );
    event AgreementCancelled(uint256 indexed id, address indexed by);
    event TokenWhitelisted(address indexed token, bool allowed);


    function setUp() public {
        vm.prank(admin);
        claimpay = new ClaimPay(admin);

        usdc = new MockUSDC();

        vm.prank(admin);
        claimpay.setTokenWhitelisted(address(usdc), true);
    }

    function _amounts() internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = 1_000e6;
        a[1] = 500e6;
    }

    function _create() internal returns (uint256 id) {
        vm.prank(client);
        id = claimpay.createAgreement(provider, address(usdc), _amounts(), bytes32("terms"), arbiter, DEADLINE);
    }

    /// @dev Donne `amount` de USDC au client et l'autorise sur le contrat.
    function _fundClient(uint256 amount) internal {
        usdc.mint(client, amount);
        vm.prank(client);
        usdc.approve(address(claimpay), amount);
    }

    /// @dev Crée un accord, le finance (1500 USDC), et le fait signer -> ACTIVE.
    function _createAndSign() internal returns (uint256 id) {
        id = _create();
        _fundClient(1_500e6);
        vm.prank(provider);
        claimpay.signAgreement(id);
    }
    function test_createAgreement_nominal() public {
        vm.expectEmit(true, true, true, true);
        emit AgreementCreated(0, client, provider, address(usdc), arbiter, 1_500e6, 2);

        uint256 id = _create();

        assertEq(id, 0);
        assertEq(claimpay.agreementCount(), 1);

        (
            address c,
            address p,
            address t,
            address arb,
            uint256 total,
            ClaimPay.AgreementState state,
            uint256 cursor,
            ,
            ,
            ,
            uint256 mcount
        ) = claimpay.getAgreement(id);

        assertEq(c, client);
        assertEq(p, provider);
        assertEq(t, address(usdc));
        assertEq(arb, arbiter);
        assertEq(total, 1_500e6);
        assertEq(uint256(state), uint256(ClaimPay.AgreementState.DRAFT));
        assertEq(cursor, 0);
        assertEq(mcount, 2);
    }

    function test_createAgreement_revert_tokenNotWhitelisted() public {
        MockUSDC other = new MockUSDC();
        vm.prank(client);
        vm.expectRevert(ClaimPay.TokenNotWhitelisted.selector);
        claimpay.createAgreement(provider, address(other), _amounts(), bytes32(0), arbiter, DEADLINE);
    }

    function test_createAgreement_revert_providerIsClient() public {
        vm.prank(client);
        vm.expectRevert(ClaimPay.ProviderIsClient.selector);
        claimpay.createAgreement(client, address(usdc), _amounts(), bytes32(0), arbiter, DEADLINE);
    }

    function test_createAgreement_revert_arbiterNotNeutral() public {
        vm.prank(client);
        vm.expectRevert(ClaimPay.ArbiterNotNeutral.selector);
        claimpay.createAgreement(provider, address(usdc), _amounts(), bytes32(0), provider, DEADLINE);
    }

    function test_createAgreement_revert_emptyMilestones() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(client);
        vm.expectRevert(ClaimPay.EmptyMilestones.selector);
        claimpay.createAgreement(provider, address(usdc), empty, bytes32(0), arbiter, DEADLINE);
    }

    function test_createAgreement_revert_zeroMilestoneAmount() public {
        uint256[] memory amts = new uint256[](2);
        amts[0] = 1_000e6;
        amts[1] = 0;
        vm.prank(client);
        vm.expectRevert(ClaimPay.ZeroMilestoneAmount.selector);
        claimpay.createAgreement(provider, address(usdc), amts, bytes32(0), arbiter, DEADLINE);
    }

    function test_createAgreement_revert_zeroDeadline() public {
        vm.prank(client);
        vm.expectRevert(ClaimPay.ZeroDeadline.selector);
        claimpay.createAgreement(provider, address(usdc), _amounts(), bytes32(0), arbiter, 0);
    }

    function test_signAgreement_nominal() public {
        uint256 id = _create();

        vm.expectEmit(true, true, false, false);
        emit AgreementSigned(id, provider);

        vm.prank(provider);
        claimpay.signAgreement(id);

        (,,,,, ClaimPay.AgreementState state,,,,,) = claimpay.getAgreement(id);
        assertEq(uint256(state), uint256(ClaimPay.AgreementState.ACTIVE));
    }

    function test_signAgreement_revert_notProvider() public {
        uint256 id = _create();
        vm.prank(client);
        vm.expectRevert(ClaimPay.NotProvider.selector);
        claimpay.signAgreement(id);
    }

    function test_signAgreement_revert_doubleSign() public {
        uint256 id = _create();
        vm.prank(provider);
        claimpay.signAgreement(id);

        vm.prank(provider);
        vm.expectRevert(ClaimPay.InvalidAgreementState.selector);
        claimpay.signAgreement(id);
    }

    function test_signAgreement_revert_expired() public {
        uint256 id = _create();
        vm.warp(block.timestamp + DEADLINE + 1);

        vm.prank(provider);
        vm.expectRevert(ClaimPay.DeadlinePassed.selector);
        claimpay.signAgreement(id);
    }

    // --------------------------------------------------------------------- //
    //                    Cycle de vie d'un palier + révisions               //
    // --------------------------------------------------------------------- //

    bytes32 internal constant HASH_V1 = keccak256("livrable v1");
    bytes32 internal constant HASH_V2 = keccak256("livrable v2");

    function test_startMilestone_nominal() public {
        uint256 id = _createAndSign();

        vm.expectEmit(true, true, false, false);
        emit MilestoneStarted(id, 0);

        vm.prank(client);
        claimpay.startMilestone(id, 0);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.IN_PROGRESS));
        assertGt(m.startedAt, 0);
        assertEq(m.submittedAt, 0); // jamais soumis
    }

    function test_startMilestone_revert_insufficientAllowance() public {
        uint256 id = _create();
        // signé mais SANS financement -> allowance = 0
        vm.prank(provider);
        claimpay.signAgreement(id);

        vm.prank(client);
        vm.expectRevert(ClaimPay.InsufficientAllowance.selector);
        claimpay.startMilestone(id, 0);
    }

    function test_startMilestone_revert_notClient() public {
        uint256 id = _createAndSign();
        vm.prank(provider);
        vm.expectRevert(ClaimPay.NotClient.selector);
        claimpay.startMilestone(id, 0);
    }

    function test_startMilestone_revert_wrongIndex() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        vm.expectRevert(ClaimPay.NotCurrentMilestone.selector);
        claimpay.startMilestone(id, 1); // cursor == 0
    }

    function test_submitMilestone_nominal() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0);

        vm.expectEmit(true, true, false, true);
        emit MilestoneSubmitted(id, 0, HASH_V1);

        vm.prank(provider);
        claimpay.submitMilestone(id, 0, HASH_V1);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.SUBMITTED));
        assertEq(m.deliverableHash, HASH_V1);
        assertGt(m.submittedAt, 0);
    }

    function test_submitMilestone_revert_notProvider() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0);

        vm.prank(client);
        vm.expectRevert(ClaimPay.NotProvider.selector);
        claimpay.submitMilestone(id, 0, HASH_V1);
    }

    function test_submitMilestone_revert_notStarted() public {
        uint256 id = _createAndSign();
        // palier encore PENDING
        vm.prank(provider);
        vm.expectRevert(ClaimPay.InvalidMilestoneState.selector);
        claimpay.submitMilestone(id, 0, HASH_V1);
    }

    function test_revisionLoop_noFundsMoved_cursorStable() public {
        uint256 id = _createAndSign();

        vm.prank(client);
        claimpay.startMilestone(id, 0);

        uint256 clientBalBefore = usdc.balanceOf(client);
        uint256 providerBalBefore = usdc.balanceOf(provider);

        // Boucle: submit -> revision -> submit -> revision -> submit (3 itérations)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(provider);
            claimpay.submitMilestone(id, 0, i % 2 == 0 ? HASH_V1 : HASH_V2);

            ClaimPay.Milestone memory ms = claimpay.getMilestone(id, 0);
            assertEq(uint256(ms.state), uint256(ClaimPay.MilestoneState.SUBMITTED));

            vm.expectEmit(true, true, false, false);
            emit RevisionRequested(id, 0);
            vm.prank(client);
            claimpay.requestRevision(id, 0);

            ms = claimpay.getMilestone(id, 0);
            assertEq(uint256(ms.state), uint256(ClaimPay.MilestoneState.IN_PROGRESS));
            assertGt(ms.submittedAt, 0); // marqueur boucle de révision
        }

        // Aucun fonds n'a bougé, le curseur n'a pas avancé.
        assertEq(usdc.balanceOf(client), clientBalBefore);
        assertEq(usdc.balanceOf(provider), providerBalBefore);

        (,,,,,, uint256 cursor,,,,) = claimpay.getAgreement(id);
        assertEq(cursor, 0);
    }

    function test_requestRevision_revert_notSubmitted() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0); // IN_PROGRESS, pas SUBMITTED

        vm.prank(client);
        vm.expectRevert(ClaimPay.InvalidMilestoneState.selector);
        claimpay.requestRevision(id, 0);
    }
// --------------------------------------------------------------------- //
    //                              Paiement                                  //
    // --------------------------------------------------------------------- //

    /// @dev Amène le palier 0 jusqu'à SUBMITTED (prêt à être approuvé/payé).
    function _toSubmitted(uint256 id) internal {
        vm.prank(client);
        claimpay.startMilestone(id, 0);
        vm.prank(provider);
        claimpay.submitMilestone(id, 0, HASH_V1);
    }

    function test_approveMilestone_paysProvider() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.expectEmit(true, true, true, true);
        emit MilestonePaid(id, 0, client, provider, 1_000e6);

        vm.prank(client);
        claimpay.approveMilestone(id, 0);

        // Transfert direct client -> provider de 1000 USDC.
        assertEq(usdc.balanceOf(client), clientBefore - 1_000e6);
        assertEq(usdc.balanceOf(provider), providerBefore + 1_000e6);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.PAID));

        (,,,,,, uint256 cursor,,,,) = claimpay.getAgreement(id);
        assertEq(cursor, 1);
    }

    function test_approveMilestone_completesAgreement() public {
        uint256 id = _createAndSign();

        // Palier 0
        _toSubmitted(id);
        vm.prank(client);
        claimpay.approveMilestone(id, 0);

        // Palier 1
        vm.prank(client);
        claimpay.startMilestone(id, 1);
        vm.prank(provider);
        claimpay.submitMilestone(id, 1, HASH_V2);
        vm.prank(client);
        claimpay.approveMilestone(id, 1);

        // Les deux paliers payés -> 1500 USDC au provider, accord COMPLETED.
        assertEq(usdc.balanceOf(provider), 1_500e6);

        (,,,,, ClaimPay.AgreementState state, uint256 cursor,,,,) = claimpay.getAgreement(id);
        assertEq(uint256(state), uint256(ClaimPay.AgreementState.COMPLETED));
        assertEq(cursor, 2);
    }

    function test_approveMilestone_revert_notClient() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);

        vm.prank(provider);
        vm.expectRevert(ClaimPay.NotClient.selector);
        claimpay.approveMilestone(id, 0);
    }

    function test_approveMilestone_revert_notSubmitted() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0); // IN_PROGRESS, pas SUBMITTED

        vm.prank(client);
        vm.expectRevert(ClaimPay.InvalidMilestoneState.selector);
        claimpay.approveMilestone(id, 0);
    }

    function test_approveMilestone_rollbackIfAllowanceRevoked() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);

        // Le client retire son allowance juste avant d'approuver.
        vm.prank(client);
        usdc.approve(address(claimpay), 0);

        vm.prank(client);
        vm.expectRevert(); // SafeERC20 revert (allowance insuffisante)
        claimpay.approveMilestone(id, 0);

        // Rollback prouvé : le palier est resté SUBMITTED, rien n'a été payé.
        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.SUBMITTED));
        assertEq(usdc.balanceOf(provider), 0);

        (,,,,,, uint256 cursor,,,,) = claimpay.getAgreement(id);
        assertEq(cursor, 0);
    }

    // --------------------------------------------------------------------- //
    //                               Litiges                                  //
    // --------------------------------------------------------------------- //

    // ---- Voie A : SUBMITTED + client, à tout moment ----
    function test_openDispute_clientOnSubmitted() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);

        vm.expectEmit(true, true, true, false);
        emit DisputeOpened(id, 0, client);

        vm.prank(client);
        claimpay.openDispute(id, 0);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.DISPUTED));
    }

    function test_openDispute_revert_thirdParty() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(ClaimPay.NotParty.selector);
        claimpay.openDispute(id, 0);
    }

    // ---- Voie US-14 : SUBMITTED + provider, client fantôme, après délai ----
    function test_openDispute_US14_providerAfterTimeout() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);

        // Avant l'échéance -> revert
        vm.prank(provider);
        vm.expectRevert(ClaimPay.DeadlineNotReached.selector);
        claimpay.openDispute(id, 0);

        // Après l'échéance (depuis submittedAt) -> OK
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(provider);
        claimpay.openDispute(id, 0);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.DISPUTED));
    }

    // ---- Voie US-13 : IN_PROGRESS jamais soumis + client, après délai ----
    function test_openDispute_US13_clientAfterTimeout() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0); // IN_PROGRESS, submittedAt == 0

        // Avant l'échéance -> revert
        vm.prank(client);
        vm.expectRevert(ClaimPay.DeadlineNotReached.selector);
        claimpay.openDispute(id, 0);

        // Après l'échéance (depuis startedAt) -> OK
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.DISPUTED));
    }

    // ---- Voie boucle : IN_PROGRESS après révision + provider, après délai ----
    function test_openDispute_revisionLoopExit_providerAfterTimeout() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0);
        vm.prank(provider);
        claimpay.submitMilestone(id, 0, HASH_V1);
        vm.prank(client);
        claimpay.requestRevision(id, 0); // IN_PROGRESS, submittedAt != 0

        // Avant l'échéance -> revert
        vm.prank(provider);
        vm.expectRevert(ClaimPay.DeadlineNotReached.selector);
        claimpay.openDispute(id, 0);

        // Après l'échéance (depuis submittedAt) -> OK
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(provider);
        claimpay.openDispute(id, 0);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.DISPUTED));
    }

    // ---- resolveDispute : favorable / partiel / nul ----
    function test_resolveDispute_fullToProvider() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        uint256 providerBefore = usdc.balanceOf(provider);

        vm.expectEmit(true, true, false, true);
        emit DisputeResolved(id, 0, client, provider, 1_000e6);

        vm.prank(arbiter);
        claimpay.resolveDispute(id, 0, 1_000e6);

        assertEq(usdc.balanceOf(provider), providerBefore + 1_000e6);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.PAID));
        (,,,,,, uint256 cursor,,,,) = claimpay.getAgreement(id);
        assertEq(cursor, 1);
    }

    function test_resolveDispute_partial() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(arbiter);
        claimpay.resolveDispute(id, 0, 400e6); // partiel

        // Provider reçoit 400, le reliquat (600) reste chez le client.
        assertEq(usdc.balanceOf(provider), providerBefore + 400e6);
        assertEq(usdc.balanceOf(client), clientBefore - 400e6);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.PAID));
    }

    function test_resolveDispute_void() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(arbiter);
        claimpay.resolveDispute(id, 0, 0); // rien au provider

        // Aucun transfert : VOID.
        assertEq(usdc.balanceOf(provider), providerBefore);
        assertEq(usdc.balanceOf(client), clientBefore);

        ClaimPay.Milestone memory m = claimpay.getMilestone(id, 0);
        assertEq(uint256(m.state), uint256(ClaimPay.MilestoneState.VOID));
        (,,,,,, uint256 cursor,,,,) = claimpay.getAgreement(id);
        assertEq(cursor, 1);
    }

    function test_resolveDispute_revert_notArbiter() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        vm.prank(client);
        vm.expectRevert(ClaimPay.NotArbiter.selector);
        claimpay.resolveDispute(id, 0, 500e6);
    }

    function test_resolveDispute_revert_amountExceeds() public {
        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        vm.prank(arbiter);
        vm.expectRevert(ClaimPay.AmountExceedsMilestone.selector);
        claimpay.resolveDispute(id, 0, 1_000e6 + 1); // > montant du palier
    }

    // --------------------------------------------------------------------- //
    //                        Accès, whitelist, cancel                        //
    // --------------------------------------------------------------------- //

    function test_setTokenWhitelisted_onlyAdmin() public {
        MockUSDC other = new MockUSDC();

        // Un non-admin ne peut pas whitelister.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, client, claimpay.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(client);
        claimpay.setTokenWhitelisted(address(other), true);

        // L'admin, lui, le peut.
        vm.prank(admin);
        claimpay.setTokenWhitelisted(address(other), true);
        assertTrue(claimpay.isTokenWhitelisted(address(other)));
    }

    function test_setTokenWhitelisted_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ClaimPay.ZeroAddress.selector);
        claimpay.setTokenWhitelisted(address(0), true);
    }

    function test_revert_onNonexistentAgreement() public {
        vm.prank(provider);
        vm.expectRevert(ClaimPay.AgreementDoesNotExist.selector);
        claimpay.signAgreement(999);
    }

    // ---- cancelAgreement ----
    function test_cancel_neverSigned_afterTimeout() public {
        uint256 id = _create(); // reste DRAFT

        // Avant l'échéance -> revert
        vm.prank(client);
        vm.expectRevert(ClaimPay.DeadlineNotReached.selector);
        claimpay.cancelAgreement(id);

        // Après l'échéance -> OK (le provider n'a jamais signé)
        vm.warp(block.timestamp + DEADLINE + 1);

        vm.expectEmit(true, true, false, false);
        emit AgreementCancelled(id, client);

        vm.prank(client);
        claimpay.cancelAgreement(id);

        (,,,,, ClaimPay.AgreementState state,,,,,) = claimpay.getAgreement(id);
        assertEq(uint256(state), uint256(ClaimPay.AgreementState.CANCELLED));
    }

    function test_cancel_activeUntouched_afterTimeout() public {
        uint256 id = _create();
        _fundClient(1_500e6);
        vm.prank(provider);
        claimpay.signAgreement(id); // ACTIVE, cursor 0, palier PENDING

        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(client);
        claimpay.cancelAgreement(id);

        (,,,,, ClaimPay.AgreementState state,,,,,) = claimpay.getAgreement(id);
        assertEq(uint256(state), uint256(ClaimPay.AgreementState.CANCELLED));
    }

    function test_cancel_revert_notClient() public {
        uint256 id = _create();
        vm.warp(block.timestamp + DEADLINE + 1);

        vm.prank(provider);
        vm.expectRevert(ClaimPay.NotClient.selector);
        claimpay.cancelAgreement(id);
    }

    function test_cancel_revert_ifMilestoneProgressed() public {
        uint256 id = _createAndSign();
        vm.prank(client);
        claimpay.startMilestone(id, 0); // palier IN_PROGRESS

        vm.warp(block.timestamp + DEADLINE + 1);

        vm.prank(client);
        vm.expectRevert(ClaimPay.CannotCancel.selector);
        claimpay.cancelAgreement(id);
    }

    // --------------------------------------------------------------------- //
    //                          Fuzzing                                       //
    // --------------------------------------------------------------------- //

    /// @dev Pour tout montant valide, la création stocke un total cohérent.
    function testFuzz_createAgreement_totalMatchesSum(uint128 a0, uint128 a1) public {
        // On borne pour éviter overflow et montants nuls.
        vm.assume(a0 > 0 && a1 > 0);
        uint256[] memory amts = new uint256[](2);
        amts[0] = uint256(a0);
        amts[1] = uint256(a1);

        vm.prank(client);
        uint256 id = claimpay.createAgreement(provider, address(usdc), amts, bytes32(0), arbiter, DEADLINE);

        (,,,, uint256 total,,,,,,) = claimpay.getAgreement(id);
        assertEq(total, uint256(a0) + uint256(a1));
    }

    /// @dev Pour tout montant arbitré ≤ palier, le provider reçoit exactement ça
    ///      et jamais plus que le montant du palier.
    function testFuzz_resolveDispute_neverPaysMoreThanMilestone(uint256 award) public {
        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        // award borné au montant du palier (1000e6).
        award = bound(award, 0, 1_000e6);

        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(arbiter);
        claimpay.resolveDispute(id, 0, award);

        assertEq(usdc.balanceOf(provider), providerBefore + award);
        assertLe(award, 1_000e6); // jamais plus que le palier
    }

    /// @dev Tout montant arbitré strictement supérieur au palier revert.
    function testFuzz_resolveDispute_revertIfExceeds(uint256 excess) public {
        excess = bound(excess, 1_000e6 + 1, type(uint256).max);

        uint256 id = _createAndSign();
        _toSubmitted(id);
        vm.prank(client);
        claimpay.openDispute(id, 0);

        vm.prank(arbiter);
        vm.expectRevert(ClaimPay.AmountExceedsMilestone.selector);
        claimpay.resolveDispute(id, 0, excess);
    }
}