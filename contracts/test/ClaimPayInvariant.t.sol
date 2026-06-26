// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimPay} from "../src/ClaimPay.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ClaimPayHandler} from "./handlers/ClaimPayHandler.sol";

contract ClaimPayInvariantTest is Test {
    ClaimPay internal claimpay;
    MockUSDC internal usdc;
    ClaimPayHandler internal handler;

    function setUp() public {
        claimpay = new ClaimPay(address(this));
        usdc = new MockUSDC();
        claimpay.setTokenWhitelisted(address(usdc), true);

        handler = new ClaimPayHandler(claimpay, usdc);

        // Seul le handler est « ciblé » par le fuzzer d'invariants.
        targetContract(address(handler));
    }

    /// @dev Le provider ne reçoit jamais plus que la somme versée suivie en ghost.
    function invariant_providerBalanceMatchesPaid() public view {
        assertEq(usdc.balanceOf(handler.provider()), handler.totalPaid());
    }

    /// @dev La somme versée ne dépasse jamais le total de l'accord (3 x 1000).
    function invariant_totalPaidNeverExceedsTotal() public view {
        assertLe(handler.totalPaid(), 3_000e6);
    }

    /// @dev Le curseur ne dépasse jamais le nombre de paliers.
    function invariant_cursorBounded() public view {
        (,,,,,, uint256 cursor,,,,) = claimpay.getAgreement(handler.id());
        assertLe(cursor, 3);
    }
}