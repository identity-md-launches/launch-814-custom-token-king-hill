// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KingBase} from "./KingBase.sol";
import {Halving} from "../src/libraries/Halving.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {wadExp, wadPow, wadLn} from "solmate/src/utils/SignedWadMath.sol";

/// @notice Property tests over the arithmetic at its edges: the fee on every path at every moment
/// of the anti-snipe decay, the takeover boundary after fractional decay, the income curve against an
/// independent exponential, and the `Halving` library against solmate's `wadExp`.
contract KingHookFuzzTest is KingBase {
    uint256 constant PPM = 1_000_000;
    uint256 constant FLOOR = 0.01 ether;
    int256 constant LN2_WAD = 693147180559945309; // ln 2
    int256 constant WAD = 1e18;

    // ------------------------------------------------------------------ fee, four paths, any moment

    /// @dev Exact-input buy: fee = rate · ETH in, taken from the input, at any point of the decay.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_exactInputBuyFeeAtAnyMoment(uint96 amount, uint32 elapsed) public {
        amount = uint96(bound(amount, 1, 100 ether));
        vm.warp(hook.launchTime() + bound(elapsed, 0, 2 hours));
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = alice.balance;
        uint256 managerBefore = address(manager).balance;

        uint256 kingOut = buyExactIn(alice, amount, false);

        assertEq(hookClaims() - claimsBefore, (uint256(amount) * rate) / PPM, "fee != rate of gross input");
        assertEq(ethBefore - alice.balance, amount, "buyer paid more or less than the input");
        assertEq(address(manager).balance - managerBefore, amount, "manager did not receive the gross input");
        assertEq(token.balanceOf(alice), kingOut);
        assertEq(token.balanceOf(address(hook)), 0, "fee taken in KING");
    }

    /// @dev Exact-output buy: the buyer pays pool ETH plus fee; fee is the rate of that gross amount.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_exactOutputBuyFeeAtAnyMoment(uint96 kingOut, uint32 elapsed) public {
        kingOut = uint96(bound(kingOut, 1e9, 20_000_000 ether));
        vm.warp(hook.launchTime() + bound(elapsed, 0, 2 hours));
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = bob.balance;

        uint256 ethIn = buyExactOut(bob, kingOut, 500 ether, false);

        uint256 fee = hookClaims() - claimsBefore;
        assertEq(token.balanceOf(bob), kingOut, "not exactly the KING asked for");
        assertEq(ethBefore - bob.balance, ethIn, "surplus not refunded");
        assertApproxEqAbs(fee, (ethIn * rate) / PPM, 2, "fee != rate of gross ETH paid");
        assertEq(address(manager).balance, ethIn, "manager holds the gross amount");
    }

    /// @dev Exact-input sell: the seller receives the pool's output minus the fee.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_exactInputSellFeeAtAnyMoment(uint96 buyAmount, uint32 elapsed, uint256 fraction) public {
        buyAmount = uint96(bound(buyAmount, 1e12, 100 ether));
        uint256 bought = buyExactIn(alice, buyAmount, false);
        vm.warp(hook.launchTime() + bound(elapsed, 0, 2 hours));
        uint256 sellAmount = bound(fraction, 1, bought);
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = alice.balance;
        uint256 managerBefore = address(manager).balance;

        uint256 ethOut = sellExactIn(alice, sellAmount);

        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = managerBefore - address(manager).balance + fee;
        assertEq(alice.balance - ethBefore, ethOut, "seller did not receive the net amount");
        assertEq(fee, (gross * rate) / PPM, "fee != rate of gross output");
        assertEq(token.balanceOf(alice), bought - sellAmount, "KING consumed differs from the input");
        assertEq(token.balanceOf(address(router)), 0, "router kept KING");
    }

    /// @dev Exact-output sell: the pool pays out net plus fee; the seller gets exactly net.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_exactOutputSellFeeAtAnyMoment(uint96 buyAmount, uint32 elapsed, uint96 ethOut) public {
        buyAmount = uint96(bound(buyAmount, 0.1 ether, 100 ether));
        uint256 bought = buyExactIn(alice, buyAmount, false);
        vm.warp(hook.launchTime() + bound(elapsed, 0, 2 hours));
        // Stay inside what the pool can pay: it received 75% to 97.5% of the buy, and at a 25% fee
        // the gross output is 4/3 of the net, so 40% net is at most 53% gross.
        ethOut = uint96(bound(ethOut, 1, (uint256(buyAmount) * 40) / 100));
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 ethBefore = alice.balance;
        uint256 managerBefore = address(manager).balance;

        uint256 kingIn = sellExactOut(alice, ethOut, bought);

        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = managerBefore - address(manager).balance + fee;
        assertEq(alice.balance - ethBefore, ethOut, "seller did not receive exactly the output");
        assertEq(gross, uint256(ethOut) + fee, "pool did not pay net plus fee");
        assertApproxEqAbs(fee, (gross * rate) / PPM, 2, "fee != rate of gross output");
        assertEq(token.balanceOf(alice), bought - kingIn, "leftover KING not refunded");
        assertEq(token.balanceOf(address(router)), 0, "router kept KING");
    }

    /// @dev The fee is never larger than the swap itself and never zero for a meaningful amount.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_feeNeverExceedsTheSwap(uint96 amount, uint32 elapsed) public {
        amount = uint96(bound(amount, 1, 1_000 ether));
        vm.warp(hook.launchTime() + bound(elapsed, 0, 1 hours));
        uint256 claimsBefore = hookClaims();
        buyExactIn(alice, amount, false);
        uint256 fee = hookClaims() - claimsBefore;
        assertLe(fee, (uint256(amount) * 250_000) / PPM, "fee above 25%");
        assertGe(fee, (uint256(amount) * 25_000) / PPM, "fee below 2.5%");
        if (amount >= 40) assertGt(fee, 0, "a swap of 40 wei or more always pays something");
    }

    // ------------------------------------------------------------------ throne price and takeover boundary

    /// @dev Price after a takeover and decay matches max(floor, 1.2·paid·2^(−t/1h)) computed with an
    /// independent exponential, is exactly halved on the hour, and never leaves [floor, 1.2·paid].
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_thronePriceCurve(uint96 paid, uint32 elapsed) public {
        paid = uint96(bound(paid, FLOOR, 200 ether));
        elapsed = uint32(bound(elapsed, 0, 20 hours));
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(alice, paid, false);
        uint256 base = (uint256(paid) * 12) / 10;
        uint256 start = block.timestamp;
        vm.warp(start + elapsed);

        uint256 price = hook.currentThronePrice();
        assertGe(price, FLOOR);
        assertLe(price, base);
        // Independent oracle: base · exp(−t · ln2 / 3600)
        int256 exponent = -(int256(uint256(elapsed)) * LN2_WAD) / 3600;
        uint256 oracle = (base * uint256(wadExp(exponent))) / 1e18;
        uint256 expected = oracle < FLOOR ? FLOOR : oracle;
        assertApproxEqRel(price, expected, 1e9, "price off the exponential curve"); // 1e-9 relative
        if (elapsed % 1 hours == 0 && price > FLOOR) {
            assertEq(price, base >> (elapsed / 1 hours), "not exactly halved on the hour");
        }
        uint256 next = hook.nextHalvingTime();
        if (price > FLOOR) {
            assertGt(next, block.timestamp);
            assertLe(next - block.timestamp, 1 hours);
            assertEq((next - start) % 1 hours, 0);
        } else {
            assertEq(next, 0);
        }
    }

    /// @dev After any amount of decay, a buy one wei under the price does nothing and a buy at the
    /// price takes the throne and sets 1.2× that payment as the new base.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_takeoverBoundaryAfterDecay(uint96 paid, uint32 elapsed) public {
        paid = uint96(bound(paid, FLOOR, 50 ether));
        elapsed = uint32(bound(elapsed, 0, 12 hours));
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(alice, paid, false);
        vm.warp(block.timestamp + elapsed);
        uint256 price = hook.currentThronePrice();

        buyExactIn(bob, price - 1, false);
        assertEq(hook.king(), alice, "one wei under the price took the throne");
        assertEq(hook.reignCount(), 1);

        expectHookRevert(
            IHooks.afterSwap.selector, abi.encodeWithSelector(IKingHook.ThroneNotTaken.selector, price - 1, price, true)
        );
        buyExactIn(bob, price - 1, true);

        uint256 kingOut = buyExactIn(bob, price, false);
        assertEq(hook.king(), bob, "a buy at the price did not take the throne");
        assertEq(hook.takeoverPaid(), price);
        assertEq(hook.requiredBalance(), kingOut);
        assertEq(hook.currentThronePrice(), (price * 12) / 10);
        assertEq(hook.reignCount(), 2);
        IKingHook.Reign memory r = hook.getReign(0);
        assertEq(r.end, block.timestamp);
        assertEq(uint8(r.reason), uint8(IKingHook.EndReason.Dethroned));
    }

    /// @dev Several buys below the price never add up, whatever their sizes.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_smallBuysNeverAddUp(uint96 a, uint96 b, uint96 c) public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(alice, 1 ether, false); // price 1.2 ETH
        uint256 price = hook.currentThronePrice();
        a = uint96(bound(a, 1, price - 1));
        b = uint96(bound(b, 1, price - 1));
        c = uint96(bound(c, 1, price - 1));
        buyExactIn(bob, a, false);
        buyExactIn(bob, b, false);
        buyExactIn(bob, c, false);
        assertEq(hook.king(), alice, "sub-price buys added up to a takeover");
        assertEq(hook.reignCount(), 1);
    }

    // ------------------------------------------------------------------ income curve

    /// @dev The king's income after t seconds is pool·(1 − 0.98^(t/1h)), checked against solmate's
    /// `wadPow`, and the pool shrinks by exactly what the king earned.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_incomeCurve(uint96 fund, uint32 elapsed) public {
        fund = uint96(bound(fund, 0.05 ether, 500 ether));
        elapsed = uint32(bound(elapsed, 1, 7 days));
        buyExactIn(carol, fund, false);
        openGame();
        buyExactIn(alice, FLOOR, false);
        uint256 poolAtStart = hook.pool();
        vm.warp(block.timestamp + elapsed);

        uint256 earned = hook.kingReignEarnings();
        int256 hoursWad = (int256(uint256(elapsed)) * WAD) / 3600;
        uint256 remainingOracle = (poolAtStart * uint256(wadPow(0.98e18, hoursWad))) / 1e18;
        uint256 expected = poolAtStart - remainingOracle;
        assertApproxEqRel(earned, expected, 1e9, "income off the 0.98^h curve");
        assertEq(hook.poolSize(), poolAtStart - earned, "pool did not shrink by the income");
        assertLe(earned, poolAtStart, "paid more than the pool");
        // What the website shows as per-hour income is 2% of the live pool.
        assertEq(hook.incomePerHour(), (hook.poolSize() * 2) / 100);
        // Claimable only after vesting, in full.
        if (elapsed >= 5 minutes) {
            assertEq(hook.unclaimedIncome(alice), earned);
            assertEq(hook.kingVestingIncome(), 0);
        } else {
            assertEq(hook.unclaimedIncome(alice), 0);
            assertEq(hook.kingVestingIncome(), earned);
        }
    }

    /// @dev Booking the income in random instalments pays exactly what one booking would (within
    /// rounding dust): nobody gains by poking the accrual.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_incomeIsPathIndependent(uint32 a, uint32 b, uint32 c) public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(alice, FLOOR, false);
        uint256 poolAtStart = hook.pool();
        a = uint32(bound(a, 1, 6 hours));
        b = uint32(bound(b, 1, 6 hours));
        c = uint32(bound(c, 1, 6 hours));
        uint256 total = uint256(a) + b + c;

        vm.warp(block.timestamp + a);
        vm.prank(bob);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim(); // books the accrual before reverting
        vm.warp(block.timestamp + b);
        vm.prank(bob);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();
        vm.warp(block.timestamp + c);

        uint256 direct = Halving.decay(poolAtStart, total * hook.INCOME_LOG2_PER_HOUR(), hook.INCOME_DEN());
        assertApproxEqAbs(hook.poolSize(), direct, 3 * 64, "stepped accrual drifted from the curve");
        assertEq(hook.kingReignEarnings(), poolAtStart - hook.poolSize());
    }

    // ------------------------------------------------------------------ Halving library

    /// @dev Whole half-lives are exact shifts for every value in range.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_halvingExactAtWholeHalfLives(uint192 value, uint8 k) public pure {
        k = uint8(bound(k, 0, 200));
        assertEq(Halving.decay(value, uint256(k) * 3600, 3600), uint256(value) >> k);
    }

    /// @dev Decay composes: two steps equal one step within rounding. The library's comment claims
    /// an absolute bound of 64 wei; the real bound is relative (each of up to 64 Q64 constants is
    /// rounded, about 64·2^-64 ≈ 3.5e-18 of the value) plus 64 wei. Reported in `.imd-findings.json`
    /// as a documentation defect; the property here uses the true bound.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_halvingComposes(uint128 value, uint32 a, uint32 b) public pure {
        uint256 one = Halving.decay(value, uint256(a) + b, 3600);
        uint256 two = Halving.decay(Halving.decay(value, a, 3600), b, 3600);
        uint256 tolerance = 128 + (uint256(value) * 8) / 1e18; // 8e-18 relative
        assertApproxEqAbs(one, two, tolerance);
    }

    /// @dev Against an independent 2^(−x): whole halvings are shifts, the fraction is solmate's
    /// `wadExp(−f·ln2)` (full precision only for f in [0, 1), so the oracle is split that way).
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_halvingMatchesWadExp(uint128 value, uint32 num) public pure {
        value = uint128(bound(value, 1e6, type(uint128).max));
        num = uint32(bound(num, 0, 100 * 3600));
        uint256 ours = Halving.decay(value, num, 3600);
        uint256 shifted = uint256(value) >> (num / 3600);
        int256 exponent = -(int256(uint256(num % 3600)) * LN2_WAD) / 3600;
        uint256 oracle = (shifted * uint256(wadExp(exponent))) / 1e18;
        // 64 wei from the table's roundings plus 1e-12 relative for the oracle's own precision.
        assertApproxEqAbs(ours, oracle, 64 + oracle / 1e12, "decay off the oracle");
    }

    /// @dev Never increases, never negative, zero stays zero.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_halvingBounds(uint192 value, uint64 num, uint64 den) public pure {
        den = uint64(bound(den, 1, type(uint64).max));
        uint256 r = Halving.decay(value, num, den);
        assertLe(r, value);
        if (value == 0) assertEq(r, 0);
        if (num == 0) assertEq(r, value);
    }

    /// @dev The income constant: one hour leaves 98%, to within 1e-9.
    function test_incomeConstantIsNinetyEightPercentPerHour() public view {
        uint256 v = Halving.decay(1e30, 3600 * hook.INCOME_LOG2_PER_HOUR(), hook.INCOME_DEN());
        assertApproxEqRel(v, 0.98e30, 1e9);
        // ln(0.98)/ln(2) · 1e12 recomputed independently
        int256 log2Inv = (-wadLn(0.98e18) * 1e12) / LN2_WAD;
        assertApproxEqAbs(uint256(log2Inv), hook.INCOME_LOG2_PER_HOUR(), 2);
    }
}
