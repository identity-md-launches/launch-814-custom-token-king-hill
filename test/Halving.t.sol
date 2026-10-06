// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Halving} from "../src/libraries/Halving.sol";

contract HalvingTest is Test {
    uint256 constant ONE = 1 ether;

    function test_zeroElapsedIsIdentity() public pure {
        assertEq(Halving.decay(ONE, 0, 3600), ONE);
    }

    function test_exactAtWholeHalfLives() public pure {
        assertEq(Halving.decay(ONE, 3600, 3600), ONE / 2);
        assertEq(Halving.decay(ONE, 7200, 3600), ONE / 4);
        assertEq(Halving.decay(ONE, 36_000, 3600), ONE >> 10);
        assertEq(Halving.decay(ONE, 3600 * 256, 3600), 0);
    }

    function test_halfWayIsOneOverSqrtTwo() public pure {
        // 2^(-1/2) = 0.70710678118654752440...
        uint256 v = Halving.decay(ONE, 1800, 3600);
        assertApproxEqAbs(v, 707_106_781_186_547_524, 2);
    }

    function test_quarterWay() public pure {
        // 2^(-1/4) = 0.84089641525371454303...
        uint256 v = Halving.decay(ONE, 900, 3600);
        assertApproxEqAbs(v, 840_896_415_253_714_543, 2);
    }

    function test_oneHourOfIncomeLeavesNinetyEightPercent() public pure {
        // The hook's income constant: 2^(-3600 * 29146345660 / (3600e12)) = 0.98.
        uint256 v = Halving.decay(ONE, 3600 * 29_146_345_660, 3600 * 1e12);
        assertApproxEqAbs(v, 0.98 ether, 1e6);
    }

    function test_perSecondCompoundingIsPathIndependent() public pure {
        uint256 num = 29_146_345_660;
        uint256 den = 3600 * 1e12;
        uint256 direct = Halving.decay(ONE, 7200 * num, den);
        uint256 stepped = ONE;
        for (uint256 i = 0; i < 24; i++) {
            stepped = Halving.decay(stepped, 300 * num, den);
        }
        // Each step rounds down by at most a few wei.
        assertApproxEqAbs(direct, stepped, 24 * 64);
    }

    /// @dev Each set bit of the fraction rounds down once, so two nearby exponents can differ by a
    /// few wei in the "wrong" direction; the documented bound is 64 wei.
    function testFuzz_monotoneAndBounded(uint192 value, uint64 a, uint64 b) public pure {
        uint256 ra = Halving.decay(value, a, 3600);
        uint256 rb = Halving.decay(value, b, 3600);
        assertLe(ra, value);
        assertLe(rb, value);
        if (a <= b) assertGe(ra + 64, rb);
        else assertGe(rb + 64, ra);
    }

    function testFuzz_monotoneForRealAmounts(uint64 a, uint64 b) public pure {
        uint256 value = 1 ether;
        uint256 ra = Halving.decay(value, a, 3600);
        uint256 rb = Halving.decay(value, b, 3600);
        if (a <= b) assertGe(ra, rb);
        else assertGe(rb, ra);
    }

    function testFuzz_fractionBelowHalfLifeStaysAboveHalf(uint192 value, uint32 rem) public pure {
        vm.assume(value > 1e6);
        uint256 r = Halving.decay(value, uint256(rem) % 3600, 3600);
        assertGe(r, value / 2);
        assertLe(r, value);
    }

    function test_rejectsOverflowingInputs() public {
        vm.expectRevert(Halving.HalvingOverflow.selector);
        this.callDecay(1 << 192, 1, 1);
        vm.expectRevert(Halving.HalvingOverflow.selector);
        this.callDecay(1, 1, 0);
    }

    function callDecay(uint256 v, uint256 n, uint256 d) external pure returns (uint256) {
        return Halving.decay(v, n, d);
    }
}
