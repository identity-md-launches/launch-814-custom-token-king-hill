// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KingBase} from "./KingBase.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice The throne game: takeovers, price dynamics, income, claims, the holding rule, dethrone()
/// and the must-take flag.
contract KingHookThroneTest is KingBase {
    uint256 constant FLOOR = 0.01 ether;

    /// @dev Fund the throne pool during the anti-snipe period, then open the game.
    function fundAndOpen() internal returns (uint256 poolSize) {
        buyExactIn(carol, 10 ether, false); // 25% fee: 2.3 ETH to the pool
        openGame();
        poolSize = hook.pool();
        assertEq(poolSize, 2.3 ether);
    }

    // ------------------------------------------------------------------ opening

    function test_throneIsClosedDuringAntiSnipe() public {
        assertFalse(hook.gameOpen());
        assertEq(hook.currentThronePrice(), FLOOR);
        buyExactIn(alice, 1 ether, false);
        assertEq(hook.king(), address(0), "no king before the game opens");
        assertEq(hook.reignCount(), 0);
        assertGt(hook.pool(), 0, "fees still fill the pool");

        expectHookRevert(
            IHooks.afterSwap.selector, abi.encodeWithSelector(IKingHook.ThroneNotTaken.selector, 1 ether, FLOOR, false)
        );
        buyExactIn(alice, 1 ether, true);
    }

    function test_gameOpensExactlyWhenTheFeeReachesBase() public {
        vm.warp(hook.gameStart() - 1);
        assertFalse(hook.gameOpen());
        vm.warp(hook.gameStart());
        assertTrue(hook.gameOpen());
        assertEq(hook.feeRate(), 25_000);
    }

    // ------------------------------------------------------------------ takeover

    function test_takeoverAtExactlyTheFloorPrice() public {
        fundAndOpen();
        uint256 kingOut = buyExactIn(alice, FLOOR, false);
        assertEq(hook.king(), alice);
        assertEq(hook.reignStart(), block.timestamp);
        assertEq(hook.requiredBalance(), kingOut);
        assertEq(hook.takeoverPaid(), FLOOR);
        assertEq(hook.currentThronePrice(), (FLOOR * 12) / 10, "1.2x what the king paid");
        assertEq(hook.reignCount(), 1);
    }

    function test_buyOneWeiBelowThePriceDoesNotTake() public {
        fundAndOpen();
        buyExactIn(alice, FLOOR - 1, false);
        assertEq(hook.king(), address(0));
    }

    function test_smallBuysNeverAddUp() public {
        fundAndOpen();
        for (uint256 i = 0; i < 5; i++) {
            buyExactIn(alice, FLOOR / 2, false);
        }
        assertEq(hook.king(), address(0), "five half-price buys are not a takeover");
        assertEq(token.balanceOf(alice) > 0, true);
    }

    function test_takeoverThroughExactOutputBuyCountsTheFee() public {
        fundAndOpen();
        uint256 ethIn = buyExactOut(bob, 2_000_000 ether, 1 ether, false);
        assertGe(ethIn, FLOOR);
        assertEq(hook.king(), bob);
        assertEq(hook.takeoverPaid(), ethIn, "paid = pool ETH + fee");
        assertEq(hook.requiredBalance(), 2_000_000 ether);
    }

    function test_takeoverPriceIsTheFeeInclusiveAmount() public {
        fundAndOpen();
        // Alice pays exactly 1 ETH (0.025 of it is fee). The price then is 1.2 ETH, fee included.
        buyExactIn(alice, 1 ether, false);
        assertEq(hook.currentThronePrice(), 1.2 ether);
        buyExactIn(bob, 1.2 ether - 1, false);
        assertEq(hook.king(), alice, "1.2 ETH minus one wei is not enough");
        buyExactIn(bob, 1.2 ether, false);
        assertEq(hook.king(), bob);
        assertEq(hook.currentThronePrice(), 1.44 ether);
    }

    function test_kingCanRetakeHisOwnThroneStartingANewReign() public {
        fundAndOpen();
        uint256 first = buyExactIn(alice, 1 ether, false);
        vm.warp(block.timestamp + 10 minutes);
        uint256 second = buyExactIn(alice, 2 ether, false);
        assertEq(hook.king(), alice);
        assertEq(hook.reignCount(), 2);
        assertEq(hook.requiredBalance(), second, "the new takeover's tokens are the required balance");
        assertEq(hook.currentThronePrice(), 2.4 ether);
        IKingHook.Reign memory r0 = hook.getReign(0);
        assertEq(r0.end, block.timestamp);
        assertEq(uint8(r0.reason), uint8(IKingHook.EndReason.Dethroned));
        assertEq(r0.required, first);
    }

    // ------------------------------------------------------------------ price dynamics

    function test_priceHalvesEveryHourDownToTheFloor() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        uint256 start = block.timestamp;
        assertEq(hook.currentThronePrice(), 1.2 ether);
        assertEq(hook.nextHalvingTime(), start + 1 hours);

        vm.warp(start + 1 hours);
        assertEq(hook.currentThronePrice(), 0.6 ether, "exactly half after one hour");
        assertEq(hook.nextHalvingTime(), start + 2 hours);

        vm.warp(start + 2 hours);
        assertEq(hook.currentThronePrice(), 0.3 ether);

        vm.warp(start + 2 hours + 30 minutes);
        // 0.3 * 2^(-1/2) = 0.21213203435596425732...
        assertApproxEqAbs(hook.currentThronePrice(), 0.212132034355964257 ether, 1e6);
        assertEq(hook.nextHalvingTime(), start + 3 hours);

        vm.warp(start + 6 hours);
        assertEq(hook.currentThronePrice(), 0.01875 ether);

        vm.warp(start + 7 hours);
        assertEq(hook.currentThronePrice(), FLOOR, "0.009375 is clamped to the floor");
        assertEq(hook.nextHalvingTime(), 0, "nothing left to halve");

        vm.warp(start + 30 days);
        assertEq(hook.currentThronePrice(), FLOOR);
    }

    function test_priceDecayMakesALongSittingKingCheap() public {
        fundAndOpen();
        buyExactIn(alice, 8 ether, false);
        vm.warp(block.timestamp + 5 hours);
        assertEq(hook.currentThronePrice(), 0.3 ether);
        buyExactIn(bob, 0.3 ether, false);
        assertEq(hook.king(), bob);
        assertEq(hook.currentThronePrice(), 0.36 ether);
    }

    function test_priceIsTheFloorWhileTheThroneIsEmpty() public {
        fundAndOpen();
        buyExactIn(alice, 5 ether, false);
        assertEq(hook.currentThronePrice(), 6 ether);
        sellExactIn(alice, 1);
        assertEq(hook.king(), address(0));
        assertEq(hook.currentThronePrice(), FLOOR);
        assertEq(hook.nextHalvingTime(), 0);
    }

    // ------------------------------------------------------------------ income

    function test_incomeAccruesEverySecondAtTwoPercentPerHour() public {
        uint256 poolSize = fundAndOpen();
        buyExactIn(alice, FLOOR, false);
        poolSize = hook.pool();
        uint256 start = block.timestamp;
        assertEq(hook.unclaimedIncome(alice), 0);
        assertEq(hook.incomePerHour(), (poolSize * 2) / 100);

        vm.warp(start + 1);
        uint256 oneSecond = hook.kingReignEarnings();
        // 1 - 0.98^(1/3600) = 5.6118e-6 of the pool
        assertApproxEqRel(oneSecond, (poolSize * 56_118) / 1e10, 1e14, "per-second credit");
        assertEq(hook.kingVestingIncome(), oneSecond, "earned but still vesting");
        assertEq(hook.unclaimedIncome(alice), 0, "not claimable in the first five minutes");

        vm.warp(start + 1 hours);
        uint256 oneHour = hook.unclaimedIncome(alice);
        assertApproxEqRel(oneHour, (poolSize * 2) / 100, 1e12, "2% of the pool after one hour");
        assertEq(hook.poolSize(), poolSize - oneHour, "the pool shrinks by what was paid");
        assertEq(hook.kingReignEarnings(), oneHour);

        vm.warp(start + 2 hours);
        uint256 twoHours = hook.unclaimedIncome(alice);
        // 1 - 0.98^2 = 3.96%
        assertApproxEqRel(twoHours, (poolSize * 396) / 10_000, 1e12, "compounding: 3.96% after two hours");
        assertApproxEqRel(hook.incomePerHour(), (hook.poolSize() * 2) / 100, 1, "per-hour income tracks the pool");
    }

    // ------------------------------------------------------------------ vesting (take-and-dump defence)

    function test_takeAndDumpWithinFiveMinutesForfeitsTheIncome() public {
        fundAndOpen();
        buyExactIn(alice, FLOOR, false);
        uint256 poolAfterTake = hook.pool();
        vm.warp(block.timestamp + 2); // one Base block later
        uint256 skimmed = hook.kingReignEarnings();
        assertGt(skimmed, 0);
        assertEq(hook.unclaimedIncome(alice), 0);

        sellExactIn(alice, 1);
        assertEq(hook.king(), address(0));
        assertEq(hook.unclaimedIncome(alice), 0, "nothing to claim: the reign ended by the king's own sell");
        IKingHook.Reign memory r = hook.getReign(0);
        assertEq(r.forfeited, skimmed);
        assertEq(r.earned, 0);
        assertGe(hook.pool(), poolAfterTake, "the income went back to the pool (plus the sell fee)");
        vm.prank(alice);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();
    }

    function test_transferAndDethroneWithinFiveMinutesForfeitsTheIncome() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, FLOOR, false);
        vm.warp(block.timestamp + 4 minutes);
        vm.prank(alice);
        token.transfer(bob, required);
        hook.dethrone();
        assertEq(hook.unclaimedIncome(alice), 0);
        assertGt(hook.getReign(0).forfeited, 0);
    }

    function test_incomeVestsAfterFiveMinutes() public {
        fundAndOpen();
        buyExactIn(alice, FLOOR, false);
        uint256 start = block.timestamp;
        vm.warp(start + 5 minutes - 1);
        assertEq(hook.unclaimedIncome(alice), 0);
        assertGt(hook.kingVestingIncome(), 0);
        vm.prank(alice);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();

        vm.warp(start + 5 minutes);
        uint256 earned = hook.kingReignEarnings();
        assertEq(hook.unclaimedIncome(alice), earned, "everything earned so far vests at once");
        assertEq(hook.kingVestingIncome(), 0);
        IKingHook.ThroneView memory v = hook.throne();
        assertEq(v.vestsAt, start + 5 minutes);
        assertEq(v.kingVesting, 0);

        sellExactIn(alice, 1); // a sell after vesting keeps the income
        assertEq(hook.unclaimedIncome(alice), earned);
        assertEq(hook.getReign(0).forfeited, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - before, earned);
    }

    function test_beingOutbidWithinFiveMinutesKeepsTheIncome() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        vm.warp(block.timestamp + 1 minutes);
        uint256 earned = hook.kingReignEarnings();
        assertGt(earned, 0);
        buyExactIn(bob, 1.2 ether, false);
        assertEq(hook.king(), bob);
        assertEq(hook.unclaimedIncome(alice), earned, "dethroned by somebody else: income kept");
        assertEq(hook.getReign(0).earned, earned);
        assertEq(hook.getReign(0).forfeited, 0);
        assertEq(hook.provisionalIncome(), 0, "the new reign starts with nothing vesting");
    }

    function test_incomeIsPathIndependent() public {
        fundAndOpen();
        buyExactIn(alice, FLOOR, false);
        uint256 poolSize = hook.pool();
        uint256 start = block.timestamp;
        // Touch the accrual every 10 minutes for 3 hours.
        for (uint256 i = 1; i <= 18; i++) {
            vm.warp(start + i * 10 minutes);
            vm.prank(bob);
            vm.expectRevert(IKingHook.NothingToClaim.selector);
            hook.claim(); // reverts after accruing; use a successful path instead
            buyExactIn(bob, 1e12, false); // tiny buy, books the accrual (and adds dust to the pool)
        }
        uint256 earnedStepped = hook.kingReignEarnings();
        // 1 - 0.98^3 = 5.8808%
        assertApproxEqRel(earnedStepped, (poolSize * 58_808) / 1e6, 2e13, "stepped accrual matches the curve");
    }

    function test_feesArrivingDuringAReignEarnFromThenOn() public {
        fundAndOpen();
        buyExactIn(alice, 5 ether, false); // price 6 ETH, 3 ETH after an hour
        uint256 start = block.timestamp;
        vm.warp(start + 1 hours);
        uint256 beforeTopUp = hook.unclaimedIncome(alice);
        buyExactIn(bob, 1 ether, false); // 0.023 ETH more in the pool, far below the price
        assertEq(hook.king(), alice);
        assertEq(hook.unclaimedIncome(alice), beforeTopUp, "the top-up does not earn retroactively");
        vm.warp(start + 2 hours);
        assertGt(hook.unclaimedIncome(alice), beforeTopUp);
    }

    function test_incomeStopsWhenTheThroneEmpties() public {
        fundAndOpen();
        buyExactIn(alice, FLOOR, false);
        vm.warp(block.timestamp + 1 hours);
        sellExactIn(alice, 1); // dethroned
        uint256 earned = hook.unclaimedIncome(alice);
        assertGt(earned, 0);
        vm.warp(block.timestamp + 10 hours);
        assertEq(hook.unclaimedIncome(alice), earned, "no income without a king");
        assertEq(hook.poolSize(), hook.pool(), "the pool does not shrink without a king");
    }

    function test_claimWhileKingAndAfterLosingTheThrone() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        vm.warp(block.timestamp + 1 hours);
        uint256 first = hook.unclaimedIncome(alice);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - ethBefore, first, "paid while king");
        assertEq(hook.unclaimedIncome(alice), 0);
        assertEq(hook.king(), alice, "claiming does not affect the throne");

        vm.warp(block.timestamp + 1 hours);
        buyExactIn(bob, 1 ether, false); // alice loses the throne, income credited up to now
        assertEq(hook.king(), bob);
        uint256 second = hook.unclaimedIncome(alice);
        assertGt(second, 0);
        vm.warp(block.timestamp + 5 hours);
        assertEq(hook.unclaimedIncome(alice), second, "nothing more after losing the throne");

        ethBefore = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - ethBefore, second, "paid after losing the throne");

        vm.prank(alice);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();
    }

    function test_claimRevertsForWalletsWithNothing() public {
        vm.prank(carol);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();
    }

    function test_nobodyCanTakeFromThePoolOutsideTheGame() public {
        fundAndOpen();
        uint256 poolSize = hook.pool();
        // No function moves pool ETH except claim() of a credited balance.
        vm.prank(alice);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();
        assertEq(hook.pool(), poolSize);
        assertEq(hookClaims(), poolSize + hook.pendingIncome(team));
    }

    // ------------------------------------------------------------------ holding rule

    function test_anySellByTheKingThroughTheRouterDethronesAtOnce() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, 1 ether, false);
        buyExactIn(alice, 1 ether, false); // extra tokens, still king (re-take, 2.4 ETH price)
        assertEq(hook.king(), alice);
        uint256 held = token.balanceOf(alice);
        assertGt(held, required);

        vm.warp(block.timestamp + 30 minutes);
        sellExactIn(alice, 1); // one wei, balance still far above the requirement
        assertEq(hook.king(), address(0), "a sell by the king empties the throne");
        IKingHook.Reign memory r = hook.getReign(hook.reignCount() - 1);
        assertEq(uint8(r.reason), uint8(IKingHook.EndReason.Sold));
        assertEq(r.end, block.timestamp);
        assertGt(hook.unclaimedIncome(alice), 0, "income up to the sell stays claimable");
    }

    function test_kingSellExactOutThroughTheRouterDethrones() public {
        fundAndOpen();
        uint256 kingOut = buyExactIn(alice, 1 ether, false);
        sellExactOut(alice, 0.001 ether, kingOut);
        assertEq(hook.king(), address(0));
    }

    function test_kingSellThroughAnotherRouterIsCaughtByTheHoldingRule() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, 1 ether, false);
        // The third-party router settles after the hook ran, so the balance is intact during the
        // swap itself: the throne is still alice's when the sell completes...
        thirdPartySwap(alice, false, -int256(required / 2), 0, "");
        assertEq(hook.king(), alice, "not identified during that swap");
        // ...and lost at the very next interaction: anyone's swap, or dethrone().
        buyExactIn(bob, 1e15, false);
        assertEq(hook.king(), address(0));
        IKingHook.Reign memory r = hook.getReign(0);
        assertEq(uint8(r.reason), uint8(IKingHook.EndReason.Balance));
    }

    function test_sellsByOthersNeverAffectTheThrone() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        uint256 bobTokens = buyExactIn(bob, 0.5 ether, false); // below 1.2 ETH, no takeover
        assertEq(hook.king(), alice);
        sellExactIn(bob, bobTokens);
        thirdPartySwap(carol, false, -int256(token.balanceOf(carol) / 2), 0, "");
        assertEq(hook.king(), alice, "still king");
        assertEq(hook.reignCount(), 1);
    }

    function test_dethroneAfterATransferStopsIncomeAtThatMoment() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, 1 ether, false);
        uint256 start = block.timestamp;
        vm.warp(start + 1 hours);
        vm.prank(alice);
        token.transfer(bob, 1); // one wei below the requirement
        assertEq(token.balanceOf(alice), required - 1);

        uint256 earnedAtDethrone = hook.unclaimedIncome(alice);
        vm.prank(carol);
        hook.dethrone();
        assertEq(hook.king(), address(0));
        assertEq(hook.requiredBalance(), 0);
        assertEq(hook.currentThronePrice(), FLOOR);
        IKingHook.Reign memory r = hook.getReign(0);
        assertEq(uint8(r.reason), uint8(IKingHook.EndReason.Balance));
        assertEq(r.end, start + 1 hours);
        assertEq(r.earned, earnedAtDethrone);

        vm.warp(start + 10 hours);
        assertEq(hook.unclaimedIncome(alice), earnedAtDethrone, "income stopped at the dethrone");
    }

    function test_dethroneIsRefusedWhileTheKingHoldsEnough() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, 1 ether, false);
        vm.expectRevert(abi.encodeWithSelector(IKingHook.KingHoldsEnough.selector, required, required));
        hook.dethrone();

        // Extra tokens beyond the requirement can move freely.
        uint256 extra = buyExactIn(alice, 0.1 ether, false); // below 1.2 ETH, no new reign
        assertEq(hook.reignCount(), 1);
        vm.prank(alice);
        token.transfer(bob, extra);
        vm.expectRevert(abi.encodeWithSelector(IKingHook.KingHoldsEnough.selector, required, required));
        hook.dethrone();
        assertEq(hook.king(), alice);
    }

    function test_dethroneIsRefusedWhenTheThroneIsEmpty() public {
        fundAndOpen();
        vm.expectRevert(IKingHook.ThroneEmpty.selector);
        hook.dethrone();
    }

    // ------------------------------------------------------------------ must-take flag

    function test_mustTakeRevertsTheWholeSwapBelowThePrice() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        uint256 poolBefore = hook.pool();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = bob.balance;

        expectHookRevert(
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(IKingHook.ThroneNotTaken.selector, 1 ether, 1.2 ether, true)
        );
        buyExactIn(bob, 1 ether, true);

        assertEq(hook.pool(), poolBefore, "no fee was taken");
        assertEq(hookClaims(), claimsBefore);
        assertEq(bob.balance, ethBefore, "no ETH left the buyer");
        assertEq(token.balanceOf(bob), 0);
        assertEq(hook.king(), alice);
    }

    function test_mustTakeRevertsForExactOutputBuysToo() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        vm.prank(bob);
        vm.expectRevert();
        router.buyExactOut{value: 1 ether}(1_000_000 ether, true, block.timestamp);
        assertEq(hook.king(), alice);
        assertEq(bob.balance, 1_000 ether);
    }

    function test_mustTakeSucceedsAtThePrice() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        buyExactIn(bob, 1.2 ether, true);
        assertEq(hook.king(), bob);
    }

    function test_mustTakeIsIgnoredWithoutTheFlag() public {
        fundAndOpen();
        buyExactIn(alice, 1 ether, false);
        uint256 out = buyExactIn(bob, 1 ether, false);
        assertGt(out, 0, "a plain buy below the price simply buys");
        assertEq(hook.king(), alice);
    }

    // ------------------------------------------------------------------ history and views

    function test_pastKingsWithReignTimeAndEarnings() public {
        fundAndOpen();
        uint256 t0 = block.timestamp;
        uint256 aliceTokens = buyExactIn(alice, 1 ether, false);
        vm.warp(t0 + 2 hours);
        buyExactIn(bob, 2 ether, false);
        uint256 aliceEarned = hook.unclaimedIncome(alice);
        vm.warp(t0 + 3 hours);
        vm.prank(bob);
        token.transfer(carol, 1);
        hook.dethrone();

        assertEq(hook.reignCount(), 2);
        IKingHook.Reign[] memory all = hook.getReigns(0, 10);
        assertEq(all.length, 2);
        assertEq(all[0].king, alice);
        assertEq(all[0].start, t0);
        assertEq(all[0].end, t0 + 2 hours);
        assertEq(all[0].paid, 1 ether);
        assertEq(all[0].required, aliceTokens);
        assertEq(all[0].earned, aliceEarned);
        assertEq(uint8(all[0].reason), uint8(IKingHook.EndReason.Dethroned));
        assertEq(all[1].king, bob);
        assertEq(all[1].start, t0 + 2 hours);
        assertEq(all[1].end, t0 + 3 hours);
        assertEq(all[1].paid, 2 ether);
        assertEq(all[1].earned, hook.unclaimedIncome(bob));
        assertEq(uint8(all[1].reason), uint8(IKingHook.EndReason.Balance));

        IKingHook.Reign[] memory page = hook.getReigns(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].king, bob);
        assertEq(hook.getReigns(5, 1).length, 0);
    }

    function test_throneViewAggregatesEverything() public {
        fundAndOpen();
        uint256 required = buyExactIn(alice, 1 ether, false);
        vm.warp(block.timestamp + 30 minutes);
        IKingHook.ThroneView memory v = hook.throne();
        assertEq(v.king, alice);
        assertEq(v.reignStart, block.timestamp - 30 minutes);
        assertEq(v.requiredBalance, required);
        assertEq(v.kingBalance, required);
        assertEq(v.thronePrice, hook.currentThronePrice());
        assertEq(v.nextHalving, block.timestamp + 30 minutes);
        assertEq(v.poolSize, hook.poolSize());
        assertEq(v.incomePerHour, hook.incomePerHour());
        assertEq(v.kingUnclaimed, hook.unclaimedIncome(alice));
        assertEq(v.kingVesting, 0);
        assertEq(v.vestsAt, block.timestamp - 30 minutes + 5 minutes);
        assertEq(v.kingReignEarnings, hook.kingReignEarnings());
        assertEq(v.feeRate, 25_000);
        assertEq(v.launchTime, hook.launchTime());
        assertEq(v.gameStart, hook.gameStart());
        assertTrue(v.gameOpen);
    }

    function test_viewsOnAnEmptyThrone() public {
        fundAndOpen();
        IKingHook.ThroneView memory v = hook.throne();
        assertEq(v.king, address(0));
        assertEq(v.thronePrice, FLOOR);
        assertEq(v.nextHalving, 0);
        assertEq(v.kingUnclaimed, 0);
        assertEq(v.kingVesting, 0);
        assertEq(v.vestsAt, 0);
        assertEq(v.kingReignEarnings, 0);
        assertEq(v.kingBalance, 0);
        assertEq(hook.incomePerHour(), (hook.pool() * 2) / 100, "what a king would earn");
    }

    // ------------------------------------------------------------------ router guards

    function test_routerSlippageAndDeadline() public {
        vm.startPrank(alice);
        vm.expectRevert(KingRouter.Expired.selector);
        router.buyExactIn{value: 1 ether}(0, false, block.timestamp - 1);
        vm.expectRevert(KingRouter.ZeroAmount.selector);
        router.buyExactIn{value: 0}(1, false, block.timestamp);
        vm.expectRevert(KingRouter.ZeroAmount.selector);
        router.buyExactOut{value: 1 ether}(0, false, block.timestamp);
        vm.expectRevert(KingRouter.ZeroAmount.selector);
        router.sellExactIn(0, 0, block.timestamp);
        vm.expectRevert(KingRouter.ZeroAmount.selector);
        router.sellExactOut(1, 0, block.timestamp);
        vm.expectRevert();
        router.buyExactIn{value: 1 ether}(type(uint256).max, false, block.timestamp);
        vm.expectRevert();
        router.buyExactOut{value: 0.001 ether}(100_000_000 ether, false, block.timestamp);
        vm.stopPrank();
        assertEq(address(router).balance, 0);
    }
}
