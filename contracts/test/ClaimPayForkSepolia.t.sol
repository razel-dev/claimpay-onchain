// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimPay} from "../src/ClaimPay.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Tests sur un fork de Sepolia, contre le VRAI USDC de test Circle.
/// @dev Activés seulement si SEPOLIA_RPC_URL et USDC_SEPOLIA sont définis dans .env.
///      Lancer avec : forge test --match-contract Fork -vv
contract ClaimPayForkSepoliaTest is Test {
    ClaimPay internal claimpay;
    IERC20 internal usdc;
    address internal usdcAddr;

    address internal admin = makeAddr("admin");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal arbiter = makeAddr("arbiter");

    uint64 internal constant DEADLINE = 3 days;

    function setUp() public {
        // Fork de Sepolia (URL lue depuis l'env, jamais codée en dur).
        string memory rpc = vm.envString("SEPOLIA_RPC_URL");
        vm.createSelectFork(rpc);

        usdcAddr = vm.envAddress("USDC_SEPOLIA");
        usdc = IERC20(usdcAddr);

        vm.prank(admin);
        claimpay = new ClaimPay(admin);
        vm.prank(admin);
        claimpay.setTokenWhitelisted(usdcAddr, true);

        // On donne au client du vrai USDC en forçant son solde (cheatcode deal).
        deal(usdcAddr, client, 10_000e6);
    }

    function _amounts() internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = 1_000e6;
        a[1] = 500e6;
    }

    /// @dev Happy path complet contre le vrai USDC : create -> sign -> start ->
    ///      submit -> approve, avec un transfert réel.
    function testFork_happyPath_realUSDC() public {
        vm.prank(client);
        uint256 id = claimpay.createAgreement(provider, usdcAddr, _amounts(), bytes32(0), arbiter, DEADLINE);

        vm.prank(client);
        usdc.approve(address(claimpay), type(uint256).max);

        vm.prank(provider);
        claimpay.signAgreement(id);

        vm.prank(client);
        claimpay.startMilestone(id, 0);

        vm.prank(provider);
        claimpay.submitMilestone(id, 0, keccak256("v1"));

        uint256 provBefore = usdc.balanceOf(provider);
        vm.prank(client);
        claimpay.approveMilestone(id, 0);

        // Le vrai USDC a bien transféré 1000 au provider.
        assertEq(usdc.balanceOf(provider), provBefore + 1_000e6);
    }

    /// @dev Litige résolu partiellement contre le vrai USDC.
    function testFork_disputePartial_realUSDC() public {
        vm.prank(client);
        uint256 id = claimpay.createAgreement(provider, usdcAddr, _amounts(), bytes32(0), arbiter, DEADLINE);
        vm.prank(client);
        usdc.approve(address(claimpay), type(uint256).max);
        vm.prank(provider);
        claimpay.signAgreement(id);
        vm.prank(client);
        claimpay.startMilestone(id, 0);
        vm.prank(provider);
        claimpay.submitMilestone(id, 0, keccak256("v1"));
        vm.prank(client);
        claimpay.openDispute(id, 0);

        uint256 provBefore = usdc.balanceOf(provider);
        vm.prank(arbiter);
        claimpay.resolveDispute(id, 0, 400e6);

        assertEq(usdc.balanceOf(provider), provBefore + 400e6);
    }
}