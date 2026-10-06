// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {KingBase} from "./KingBase.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";
import {Halving} from "../src/libraries/Halving.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract NonPayableKingWallet {
    function buyIn(KingRouter router) external {
        router.buyExactIn{value: 0.5 ether}(0, false, block.timestamp);
    }

    function buyOut(KingRouter router) external {
        router.buyExactOut{value: 0.5 ether}(1000 ether, false, block.timestamp);
    }
}

contract KingHookRevisionTest is KingBase {
    event Swapped(address indexed user, bool isBuy, uint256 ethAmount, uint256 kingAmount);

    function fundAndOpen() internal {
        buyExactIn(carol, 10 ether, false);
        openGame();
    }

    function partialSell() internal returns (uint256 refund) {
        giveTokens(carol, 99_999_000 ether);
        giveTokens(bob, 1000 ether);
        openGame();
        buyExactIn(alice, 1 ether, false);
        uint256 supplied = token.balanceOf(carol);
        uint256 managerBefore = token.balanceOf(address(manager));
        vm.recordLogs();
        uint256 ethOut = sellExactIn(carol, supplied);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 consumed = token.balanceOf(address(manager)) - managerBefore;
        assertGt(ethOut, 0);
        assertLt(consumed, supplied, "exercise a real partial fill");
        bool found = false;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(router)
                    && logs[i].topics[0] == keccak256("Swapped(address,bool,uint256,uint256)")
            ) {
                (bool isBuy, uint256 reportedEth, uint256 reportedKing) =
                    abi.decode(logs[i].data, (bool, uint256, uint256));
                assertFalse(isBuy);
                assertEq(address(uint160(uint256(logs[i].topics[1]))), carol);
                assertEq(reportedEth, ethOut);
                assertEq(reportedKing, consumed, "event reports actual input");
                found = true;
            }
        }
        assertTrue(found, "Swapped emitted");
        refund = supplied - consumed;
        assertEq(token.balanceOf(carol), refund, "unused KING belongs to seller");
        assertEq(token.balanceOf(address(router)), 0, "no stranded KING");
    }

    function test_partialSellRefundsUnusedKing() public {
        partialSell();
    }

    function test_nextSellerCannotSweepPartialFillRefund() public {
        uint256 refund = partialSell();
        buyExactIn(alice, 1 ether, false);
        uint256 consumed = sellExactOut(bob, 1, 1000 ether);
        assertEq(token.balanceOf(bob), 1000 ether - consumed);
        assertEq(token.balanceOf(carol), refund);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_selfRetakeCannotReduceHoldingRequirement() public {
        fundAndOpen();
        uint256 original = buyExactIn(alice, 1 ether, true);
        vm.warp(block.timestamp + 7 hours);
        uint256 extra = buyExactIn(alice, 0.01 ether, true);
        assertLt(extra, original);
        assertEq(hook.requiredBalance(), original);
        assertEq(hook.getReign(1).required, original);
        thirdPartySwap(alice, false, -int256(original), 0, "");
        hook.dethrone();
        assertEq(hook.king(), address(0));
    }

    function test_officialExactInputSellIsRecordedAsSold() public {
        fundAndOpen();
        uint256 amount = buyExactIn(alice, 1 ether, true);
        vm.warp(block.timestamp + 10 minutes);
        uint256 earned = hook.unclaimedIncome(alice);
        sellExactIn(alice, amount);
        assertEq(uint8(hook.getReign(0).reason), uint8(IKingHook.EndReason.Sold));
        assertEq(hook.unclaimedIncome(alice), earned);
    }

    function test_officialExactOutputSellIsRecordedAsSoldDespiteEscrow() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, 1 ether, true);
        buyExactIn(alice, 0.5 ether, false);
        vm.warp(block.timestamp + 10 minutes);
        uint256 earned = hook.unclaimedIncome(alice);
        sellExactOut(alice, 0.001 ether, token.balanceOf(alice));
        assertGe(token.balanceOf(alice), required);
        assertEq(uint8(hook.getReign(0).reason), uint8(IKingHook.EndReason.Sold));
        assertEq(hook.unclaimedIncome(alice), earned);
    }

    function test_foreignMustTakeRevertsWithoutCharging() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, true);
        uint256 ethBefore = bob.balance;
        uint256 claimsBefore = hookClaims();
        expectHookRevert(
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(IKingHook.ThroneNotTaken.selector, 0.5 ether, 1.2 ether, true)
        );
        thirdPartySwap(bob, true, -0.5 ether, 0.5 ether, abi.encode(bob, true));
        assertEq(bob.balance, ethBefore);
        assertEq(hookClaims(), claimsBefore);
        assertEq(token.balanceOf(bob), 0);
        assertEq(hook.king(), alice);
    }

    function testFuzz_earlyTakeoversNeverVest(uint32 delay, bool selfRetake) public {
        delay = uint32(bound(delay, 1, 299));
        fundAndOpen();
        buyExactIn(alice, 0.01 ether, true);
        vm.warp(block.timestamp + delay);
        uint256 earned = hook.kingReignEarnings();
        buyExactIn(selfRetake ? alice : bob, hook.currentThronePrice(), true);
        assertEq(hook.pendingIncome(alice), 0);
        assertEq(hook.getReign(0).forfeited, earned);
        sellExactIn(alice, token.balanceOf(alice));
        if (!selfRetake) sellExactIn(bob, token.balanceOf(bob));
        assertEq(hook.king(), address(0));
        assertEq(hook.unclaimedIncome(alice) + hook.unclaimedIncome(bob), 0);
        assertEq(hookClaims(), hook.pool() + hook.pendingIncome(team));
    }

    function test_takeoverAtVestingBoundaryKeepsIncome() public {
        fundAndOpen();
        buyExactIn(alice, 0.01 ether, true);
        vm.warp(block.timestamp + 5 minutes);
        uint256 earned = hook.unclaimedIncome(alice);
        buyExactIn(bob, hook.currentThronePrice(), true);
        assertGt(earned, 0);
        assertEq(hook.pendingIncome(alice), earned);
        assertEq(hook.getReign(0).forfeited, 0);
        vm.prank(alice);
        hook.claim();
        assertEq(hook.pendingIncome(alice), 0);
    }

    function shortHolder(uint8 observation) internal {
        fundAndOpen();
        buyExactIn(alice, 1 ether, true);
        vm.warp(block.timestamp + 1 minutes);
        buyExactIn(bob, 1e12, false); // book provisional income while holdings are valid
        uint256 provisional = hook.provisionalIncome();
        uint256 pooled = hook.pool();
        uint256 claims = hookClaims();
        assertGt(provisional, 0);
        uint256 held = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, held);
        vm.warp(block.timestamp + 6 hours);
        assertEq(hook.unclaimedIncome(alice), 0);
        assertEq(hook.kingVestingIncome(), 0);
        assertEq(hook.kingReignEarnings(), 0);
        assertEq(hook.poolSize(), pooled + provisional);
        uint256 ethBefore = alice.balance;
        if (observation == 0) {
            vm.prank(alice);
            hook.claim(); // succeeds with zero payment so the dethrone persists
        } else if (observation == 1) {
            hook.dethrone();
        } else {
            buyExactIn(bob, 1e12, false);
        }
        assertEq(hook.king(), address(0));
        assertEq(alice.balance, ethBefore);
        assertEq(hook.unclaimedIncome(alice), 0);
        assertGt(hook.getReign(0).forfeited, provisional, "also records the unverified gap");
        assertEq(hook.getReign(0).earned, 0);
        assertEq(uint8(hook.getReign(0).reason), uint8(IKingHook.EndReason.Balance));
        assertEq(hook.provisionalIncome(), 0);
        uint256 newFee = observation == 2 ? 1e12 * 25_000 / 1_000_000 : 0;
        assertEq(hookClaims(), claims + newFee);
        assertEq(hook.pool(), pooled + provisional + newFee - newFee * 800 / 10_000);
        assertEq(hookClaims(), hook.pool() + hook.pendingIncome(team));
    }

    function test_claimForfeitsUnverifiedGapAndPersistsDethrone() public {
        shortHolder(0);
    }

    function test_dethroneForfeitsUnverifiedGap() public {
        shortHolder(1);
    }

    function test_swapForfeitsUnverifiedGap() public {
        shortHolder(2);
    }

    function test_transferAtTakeoverThenClaimAtFiveMinutesPaysNothing() public {
        fundAndOpen();
        uint256 amount = buyExactIn(alice, 0.01 ether, true);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.warp(block.timestamp + 5 minutes);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance, ethBefore);
        assertEq(hook.king(), address(0));
        assertEq(hook.unclaimedIncome(alice), 0);
    }

    function test_thirdPartyExitThenClaimPaysNoQuietPeriodIncome() public {
        fundAndOpen();
        uint256 amount = buyExactIn(alice, 0.01 ether, true);
        thirdPartySwap(alice, false, -int256(amount), 0, "");
        vm.warp(block.timestamp + 6 hours);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance, ethBefore);
        assertEq(hook.king(), address(0));
        assertEq(hook.unclaimedIncome(alice), 0);
    }

    function test_previouslyVestedCreditsSurviveHoldingFailure() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, true);
        vm.warp(block.timestamp + 10 minutes);
        buyExactIn(bob, 1e12, false);
        uint256 vested = hook.pendingIncome(alice);
        assertGt(vested, 0);
        uint256 held = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, held);
        vm.warp(block.timestamp + 6 hours);
        assertEq(hook.unclaimedIncome(alice), vested);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - ethBefore, vested);
        assertEq(hook.getReign(0).earned, vested);
        assertEq(hook.king(), address(0));
        assertEq(hookClaims(), hook.pool() + hook.pendingIncome(team));
    }

    function test_deficientKingCannotVestBySellingDust() public {
        fundAndOpen();
        uint256 amount = buyExactIn(alice, 0.01 ether, true);
        vm.prank(alice);
        token.transfer(bob, amount - 1 ether);
        vm.warp(block.timestamp + 6 hours);
        sellExactIn(alice, 1 ether);
        assertEq(hook.unclaimedIncome(alice), 0);
        assertEq(uint8(hook.getReign(0).reason), uint8(IKingHook.EndReason.Balance));
        assertEq(hook.king(), address(0));
    }

    function test_prepareSellRejectsUntrustedCallers() public {
        fundAndOpen();
        buyExactIn(alice, 0.01 ether, true);
        vm.prank(alice);
        vm.expectRevert(IKingHook.NotRouter.selector);
        hook.prepareSell(alice);
        assertEq(hook.king(), alice);
    }

    function test_failedSellRollsBackCheckpointAndTokens() public {
        fundAndOpen();
        uint256 amount = buyExactIn(alice, 1 ether, true);
        vm.warp(block.timestamp + 10 minutes);
        uint256 pooled = hook.pool();
        vm.startPrank(alice);
        vm.expectRevert(); // allowance failure after the checkpoint
        router.sellExactIn(amount, 0, block.timestamp);
        token.approve(address(router), amount);
        vm.expectRevert(); // output slippage failure after settlement
        router.sellExactIn(amount, 100 ether, block.timestamp);
        vm.stopPrank();
        assertEq(hook.king(), alice);
        assertEq(hook.getReign(0).end, 0);
        assertEq(hook.pool(), pooled);
        assertEq(hook.pendingIncome(alice), 0);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_exactOutputCannotSweepDonatedTokensOrExceedBudget() public {
        fundAndOpen();
        uint256 amount = buyExactIn(alice, 1 ether, true);
        uint256 donated = 1_000_000 ether;
        giveTokens(address(router), donated);
        uint256 consumed = sellExactOut(alice, 1, 1000 ether);
        assertEq(token.balanceOf(alice), amount - consumed);
        assertEq(token.balanceOf(address(router)), donated);
        vm.startPrank(alice);
        token.approve(address(router), 1);
        vm.expectRevert();
        router.sellExactOut(0.001 ether, 1, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), amount - consumed);
        assertEq(token.balanceOf(address(router)), donated);
    }

    function test_foreignUnrelatedMetadataIsIgnored() public {
        fundAndOpen();
        thirdPartySwap(alice, true, -0.5 ether, 0.5 ether, abi.encode(uint256(1), uint256(2)));
        thirdPartySwap(alice, true, -0.5 ether, 0.5 ether, abi.encode(type(uint256).max, uint256(1)));
        assertEq(hook.king(), address(0));
        assertGt(token.balanceOf(alice), 0);
    }

    function test_nonPayableWalletCannotReceiveExactOutputRefund() public {
        NonPayableKingWallet wallet = new NonPayableKingWallet();
        vm.deal(address(wallet), 1 ether);
        wallet.buyIn(router);
        uint256 held = token.balanceOf(address(wallet));
        assertGt(held, 0);
        vm.expectRevert();
        wallet.buyOut(router);
        assertEq(token.balanceOf(address(wallet)), held);
        assertEq(address(wallet).balance, 0.5 ether);
    }

    function test_halvingErrorIsRelativeNot64Wei() public pure {
        uint256 value = 176266364873727319699143;
        uint256 direct = Halving.decay(value, 15, 3600);
        uint256 stepped = Halving.decay(Halving.decay(value, 6, 3600), 9, 3600);
        assertEq(direct - stepped, 154_905);
        assertGt(direct - stepped, 128);
        assertLt(direct - stepped, 256 * value / (1 << 64) + 130);
    }
}
