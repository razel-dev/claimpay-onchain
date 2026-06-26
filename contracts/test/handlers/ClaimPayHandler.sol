// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimPay} from "../../src/ClaimPay.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Handler pour le test d'invariant : expose des actions « sûres » que
///         Foundry appelle dans un ordre aléatoire sur UN accord unique.
/// @dev Suit deux totaux fantômes (ghost variables) pour les assertions :
///      - totalPaid : somme effectivement transférée au provider
///      - le total du palier disputé courant.
contract ClaimPayHandler is Test {
    ClaimPay public claimpay;
    MockUSDC public usdc;

    address public client = makeAddr("h_client");
    address public provider = makeAddr("h_provider");
    address public arbiter = makeAddr("h_arbiter");

    uint256 public id;
    uint256 public totalPaid; // ghost : somme reçue par le provider

    constructor(ClaimPay _claimpay, MockUSDC _usdc) {
        claimpay = _claimpay;
        usdc = _usdc;

        // 3 paliers de 1000 USDC ; on finance large pour ne jamais manquer.
        uint256[] memory amts = new uint256[](3);
        amts[0] = 1_000e6;
        amts[1] = 1_000e6;
        amts[2] = 1_000e6;

        usdc.mint(client, 10_000e6);
        vm.prank(client);
        usdc.approve(address(claimpay), type(uint256).max);

        vm.prank(client);
        id = claimpay.createAgreement(provider, address(usdc), amts, bytes32(0), arbiter, 3 days);

        vm.prank(provider);
        claimpay.signAgreement(id);
    }

    function _cursor() internal view returns (uint256 cursor) {
        (,,,,,, cursor,,,,) = claimpay.getAgreement(id);
    }

    function _state(uint256 index) internal view returns (ClaimPay.MilestoneState) {
        return claimpay.getMilestone(id, index).state;
    }

    // ---- Actions exposées au fuzzer ----

    function start() public {
        uint256 c = _cursor();
        if (c >= 3) return;
        if (_state(c) != ClaimPay.MilestoneState.PENDING) return;
        vm.prank(client);
        claimpay.startMilestone(id, c);
    }

    function submit(bytes32 hash) public {
        uint256 c = _cursor();
        if (c >= 3) return;
        if (_state(c) != ClaimPay.MilestoneState.IN_PROGRESS) return;
        vm.prank(provider);
        claimpay.submitMilestone(id, c, hash);
    }

    function revise() public {
        uint256 c = _cursor();
        if (c >= 3) return;
        if (_state(c) != ClaimPay.MilestoneState.SUBMITTED) return;
        vm.prank(client);
        claimpay.requestRevision(id, c);
    }

    function approve() public {
        uint256 c = _cursor();
        if (c >= 3) return;
        if (_state(c) != ClaimPay.MilestoneState.SUBMITTED) return;
        vm.prank(client);
        claimpay.approveMilestone(id, c);
        totalPaid += 1_000e6;
    }

    function dispute() public {
        uint256 c = _cursor();
        if (c >= 3) return;
        if (_state(c) != ClaimPay.MilestoneState.SUBMITTED) return;
        vm.prank(client);
        claimpay.openDispute(id, c);
    }

    function resolve(uint256 award) public {
        uint256 c = _cursor();
        if (c >= 3) return;
        if (_state(c) != ClaimPay.MilestoneState.DISPUTED) return;
        award = bound(award, 0, 1_000e6);
        vm.prank(arbiter);
        claimpay.resolveDispute(id, c, award);
        totalPaid += award;
    }
}