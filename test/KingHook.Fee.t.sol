// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KingBase} from "./KingBase.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice The trading fee: anti-snipe decay, ETH on both sides in both exact modes, the 92/8 split,
/// and fee collection on a PoolManager that holds no ETH yet.
contract KingHookFeeTest is KingBase {
    uint256 constant PPM = 1_000_000;

    // ------------------------------------------------------------------ anti-snipe decay

    function test_feeStartsAt25PercentAndDecaysLinearlyTo2_5Percent() public {
        uint256 launch = hook.launchTime();
        assertEq(block.timestamp, launch);
        assertEq(hook.feeRate(), 250_000, "25% at launch");

        vm.warp(launch + 15 minutes);
        assertEq(hook.feeRate(), 137_500, "half way: 13.75%");

        vm.warp(launch + 29 minutes + 59 seconds);
        assertGt(hook.feeRate(), 25_000);

        vm.warp(launch + 30 minutes);
        assertEq(hook.feeRate(), 25_000, "2.5% when the game opens");

        vm.warp(launch + 100 days);
        assertEq(hook.feeRate(), 25_000, "never changes afterwards");
    }

    function testFuzz_feeRateFollowsTheLine(uint32 elapsed) public {
        vm.warp(hook.launchTime() + elapsed);
        uint256 expected = elapsed >= 1800 ? 25_000 : 25_000 + (225_000 * (1800 - uint256(elapsed))) / 1800;
        assertEq(hook.feeRate(), expected);
    }

    function test_feeDecayIsAppliedToSwaps() public {
        uint256 launch = hook.launchTime();
        uint256 claimsBefore = hookClaims();
        buyExactIn(alice, 1 ether, false);
        assertEq(hookClaims() - claimsBefore, 0.25 ether, "25% of 1 ETH at launch");

        vm.warp(launch + 15 minutes);
        claimsBefore = hookClaims();
        buyExactIn(alice, 1 ether, false);
        assertEq(hookClaims() - claimsBefore, 0.1375 ether, "13.75% after 15 minutes");

        vm.warp(launch + 1 hours);
        claimsBefore = hookClaims();
        buyExactIn(alice, 1 ether, false);
        assertEq(hookClaims() - claimsBefore, 0.025 ether, "2.5% after the period");
    }

    // ------------------------------------------------------------------ ETH fee, both sides, both modes

    function test_exactInputBuy_feeIsTakenFromTheEthInput() public {
        uint256 rate = hook.feeRate();
        uint256 ethBefore = alice.balance;
        uint256 managerEthBefore = address(manager).balance;
        uint256 claimsBefore = hookClaims();

        uint256 kingOut = buyExactIn(alice, 2 ether, false);

        uint256 fee = (2 ether * rate) / PPM;
        assertEq(ethBefore - alice.balance, 2 ether, "the buyer pays exactly the amount specified");
        assertEq(token.balanceOf(alice), kingOut, "KING delivered to the buyer");
        assertEq(hookClaims() - claimsBefore, fee, "fee held as ETH claims");
        assertEq(address(manager).balance - managerEthBefore, 2 ether, "the manager received the whole input");
        assertEq(token.balanceOf(address(hook)), 0, "no KING taken");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no KING claims");
    }

    function test_exactOutputBuy_feeIsAddedToTheEthInput() public {
        uint256 rate = hook.feeRate();
        uint256 ethBefore = bob.balance;
        uint256 claimsBefore = hookClaims();
        uint256 want = 5_000_000 ether;

        uint256 ethIn = buyExactOut(bob, want, 10 ether, false);

        uint256 fee = hookClaims() - claimsBefore;
        assertEq(token.balanceOf(bob), want, "exactly the KING asked for");
        assertEq(ethBefore - bob.balance, ethIn, "unused ETH refunded");
        assertApproxEqAbs(fee, (ethIn * rate) / PPM, 2, "fee is the rate of the gross ETH paid");
        assertEq(address(manager).balance, ethIn, "manager holds gross ETH including the fee");
    }

    function test_exactInputSell_feeIsTakenFromTheEthOutput() public {
        uint256 kingOut = buyExactIn(alice, 3 ether, false);
        openGame();
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = alice.balance;
        uint256 managerEthBefore = address(manager).balance;

        uint256 ethOut = sellExactIn(alice, kingOut / 2);

        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = managerEthBefore - address(manager).balance + fee;
        assertEq(alice.balance - ethBefore, ethOut, "seller receives the net amount");
        assertEq(token.balanceOf(alice), kingOut - kingOut / 2, "exactly the KING sold left");
        assertEq(fee, (gross * rate) / PPM, "fee is the rate of the gross ETH out");
        assertEq(ethOut + fee, gross, "net plus fee is the gross pool output");
    }

    function test_exactOutputSell_feeIsAddedOnTopOfTheEthOutput() public {
        uint256 kingOut = buyExactIn(alice, 3 ether, false);
        openGame();
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = alice.balance;
        uint256 tokensBefore = token.balanceOf(alice);
        uint256 managerEthBefore = address(manager).balance;

        uint256 kingIn = sellExactOut(alice, 0.5 ether, kingOut);

        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = managerEthBefore - address(manager).balance + fee;
        assertEq(alice.balance - ethBefore, 0.5 ether, "seller receives exactly what was asked");
        assertEq(tokensBefore - token.balanceOf(alice), kingIn, "leftover KING refunded by the router");
        assertEq(gross, 0.5 ether + fee, "the pool paid out net plus fee");
        assertApproxEqAbs(fee, (gross * rate) / PPM, 2, "fee is the rate of the gross ETH out");
        assertEq(token.balanceOf(address(router)), 0, "router keeps nothing");
    }

    function test_feeIsNeverTakenInKingOnAnyPath() public {
        uint256 kingOut = buyExactIn(alice, 1 ether, false);
        buyExactOut(bob, 1_000_000 ether, 1 ether, false);
        sellExactIn(alice, kingOut / 4);
        sellExactOut(alice, 0.01 ether, kingOut / 4);
        thirdPartySwap(carol, true, -0.5 ether, 0.5 ether, "");
        thirdPartySwap(carol, false, -int256(token.balanceOf(carol) / 2), 0, "");

        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0);
        assertEq(address(hook).balance, 0, "the hook never holds raw ETH");
        assertGt(hookClaims(), 0);
        assertEq(hookClaims(), hook.pool() + hook.pendingIncome(team), "every wei of fee is pool or team");
    }

    function test_feeOnThirdPartyRouterBothDirections() public {
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        BalanceDelta delta = thirdPartySwap(carol, true, -1 ether, 1 ether, "");
        assertEq(int256(delta.amount0()), -1 ether, "swapper delta is the full input");
        assertEq(hookClaims() - claimsBefore, (1 ether * rate) / PPM);

        claimsBefore = hookClaims();
        uint256 managerEthBefore = address(manager).balance;
        delta = thirdPartySwap(carol, false, -int256(token.balanceOf(carol)), 0, "");
        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = managerEthBefore - address(manager).balance + fee;
        assertEq(uint256(uint128(delta.amount0())), gross - fee, "swapper receives net");
        assertEq(fee, (gross * rate) / PPM);
    }

    function test_exactOutputFeeIsComputedOnTheSettledDelta() public {
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        BalanceDelta delta = thirdPartySwap(carol, true, int256(2_000_000 ether), 5 ether, "");
        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = uint256(uint128(-delta.amount0()));
        assertEq(uint256(uint128(delta.amount1())), 2_000_000 ether);
        assertApproxEqAbs(fee, (gross * rate) / PPM, 2, "fee is the rate of the gross settled ETH");
    }

    // ------------------------------------------------------------------ 92 / 8 split

    function testFuzz_feeSplits92To8(uint96 amount) public {
        amount = uint96(bound(amount, 1e9, 500 ether));
        uint256 poolBefore = hook.pool();
        uint256 teamBefore = hook.pendingIncome(team);
        uint256 claimsBefore = hookClaims();

        buyExactIn(alice, amount, false);

        uint256 fee = hookClaims() - claimsBefore;
        uint256 toTeam = hook.pendingIncome(team) - teamBefore;
        uint256 toPool = hook.pool() - poolBefore;
        assertEq(toTeam, (fee * 800) / 10_000, "8% to the team wallet");
        assertEq(toPool, fee - toTeam, "92% (and the rounding dust) to the throne pool");
    }

    function test_teamWalletClaimsItsShareOnlyByPulling() public {
        buyExactIn(alice, 4 ether, false);
        uint256 share = hook.pendingIncome(team);
        assertEq(share, 0.08 ether);
        assertEq(team.balance, 0, "nothing is pushed");

        vm.prank(team);
        hook.claim();
        assertEq(team.balance, share);
        assertEq(hook.pendingIncome(team), 0);
        assertEq(hook.pool(), 0.92 ether, "the throne pool is untouched");
    }

    // ------------------------------------------------------------------ solvency of the fee path

    function test_firstBuyOnManagerHoldingNoEthSucceeds() public {
        assertEq(address(manager).balance, 0, "fresh manager, token-only pool");
        buyExactIn(alice, 1 ether, false);
        assertEq(address(manager).balance, 1 ether);
        assertEq(hookClaims(), 0.25 ether);
        // The fee is immediately spendable: the team claims part of it.
        vm.prank(team);
        hook.claim();
        assertEq(team.balance, 0.02 ether);
    }

    function test_feeCollectionDoesNotDependOnRecipientsAcceptingEth() public {
        // A rejecting team wallet would only break its own claim, never a swap.
        vm.etch(team, hex"fe"); // INVALID: any call reverts
        buyExactIn(alice, 1 ether, false);
        assertEq(hook.pendingIncome(team), 0.02 ether);
        vm.prank(team);
        vm.expectRevert();
        hook.claim();
    }
}
