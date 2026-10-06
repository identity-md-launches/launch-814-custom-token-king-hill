// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KingHookForkTest} from "./KingHookFork.t.sol";
import {IKingHook} from "../../src/interfaces/IKingHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice More of the launch rehearsal on the live Base PoolManager: the two fee paths the first
/// rehearsal did not trade, the holding rule with `dethrone()`, the must-take flag, the decayed
/// price and the history, all against the deployed v4 code. Inherits the fork-or-skip `setUp`.
contract KingHookForkMoreTest is KingHookForkTest {
    function expectHookRevert(bytes4 callback, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_fork_exactOutputBuyAndBothSellModesPayTheFeeInEth() public {
        // Exact-output buy during the anti-snipe window.
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 ethIn = router.buyExactOut{value: 5 ether}(10_000_000 ether, false, block.timestamp);
        uint256 fee = manager.balanceOf(address(hook), 0) - claimsBefore;
        assertEq(token.balanceOf(alice), 10_000_000 ether);
        assertEq(ethBefore - alice.balance, ethIn, "surplus refunded through the live manager");
        assertApproxEqAbs(fee, (ethIn * rate) / 1_000_000, 2);

        vm.warp(hook.gameStart());
        rate = hook.feeRate();

        // Exact-input sell: net = gross - fee.
        claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 managerBefore = address(manager).balance;
        ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        uint256 ethOut = router.sellExactIn(4_000_000 ether, 0, block.timestamp);
        vm.stopPrank();
        fee = manager.balanceOf(address(hook), 0) - claimsBefore;
        uint256 gross = managerBefore - address(manager).balance + fee;
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(fee, (gross * rate) / 1_000_000);

        // Exact-output sell: the pool pays net + fee, the seller gets exactly net.
        claimsBefore = manager.balanceOf(address(hook), 0);
        managerBefore = address(manager).balance;
        ethBefore = alice.balance;
        vm.prank(alice);
        uint256 kingIn = router.sellExactOut(0.01 ether, 6_000_000 ether, block.timestamp);
        fee = manager.balanceOf(address(hook), 0) - claimsBefore;
        gross = managerBefore - address(manager).balance + fee;
        assertEq(alice.balance - ethBefore, 0.01 ether);
        assertEq(gross, 0.01 ether + fee);
        assertApproxEqAbs(fee, (gross * rate) / 1_000_000, 2);
        assertEq(token.balanceOf(alice), 6_000_000 ether - kingIn, "leftover KING returned");
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_fork_holdingRuleDethroneAndMustTakeOnTheLiveManager() public {
        router.buyExactIn{value: 3 ether}(0, false, block.timestamp);
        vm.warp(hook.gameStart());

        // Must-take below the price reverts the whole swap on the live manager.
        vm.prank(bob);
        uint256 required = router.buyExactIn{value: 1 ether}(0, true, block.timestamp);
        assertEq(hook.king(), bob);
        uint256 claims = manager.balanceOf(address(hook), 0);
        expectHookRevert(
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(IKingHook.ThroneNotTaken.selector, 1 ether, 1.2 ether, true)
        );
        vm.prank(alice);
        router.buyExactIn{value: 1 ether}(0, true, block.timestamp);
        assertEq(manager.balanceOf(address(hook), 0), claims, "no fee on the reverted swap");
        assertEq(token.balanceOf(alice), 0);

        // Dethrone is refused while bob holds enough, and succeeds after a transfer.
        vm.expectRevert(abi.encodeWithSelector(IKingHook.KingHoldsEnough.selector, required, required));
        hook.dethrone();
        vm.warp(block.timestamp + 30 minutes);
        uint256 owed = hook.unclaimedIncome(bob);
        assertGt(owed, 0);
        vm.prank(bob);
        token.transfer(alice, 1);
        vm.prank(alice);
        hook.dethrone();
        assertEq(hook.king(), address(0));
        assertEq(hook.currentThronePrice(), 0.01 ether);
        IKingHook.Reign memory r = hook.getReign(0);
        assertEq(uint8(r.reason), uint8(IKingHook.EndReason.Balance));
        assertEq(r.earned, owed);

        // The ex-king claims from the live manager; the price decays for the next king.
        vm.warp(block.timestamp + 2 hours);
        assertEq(hook.unclaimedIncome(bob), owed, "income stopped at the dethrone");
        uint256 before = bob.balance;
        vm.prank(bob);
        hook.claim();
        assertEq(bob.balance - before, owed);

        vm.prank(alice);
        router.buyExactIn{value: 0.5 ether}(0, true, block.timestamp);
        assertEq(hook.king(), alice);
        assertEq(hook.currentThronePrice(), 0.6 ether);
        vm.warp(block.timestamp + 1 hours);
        assertEq(hook.currentThronePrice(), 0.3 ether);
        assertEq(hook.nextHalvingTime(), block.timestamp + 1 hours);
        vm.prank(bob);
        router.buyExactIn{value: 0.3 ether}(0, true, block.timestamp);
        assertEq(hook.king(), bob);
        assertEq(hook.reignCount(), 3);
        assertEq(
            manager.balanceOf(address(hook), 0),
            hook.pool() + hook.provisionalIncome() + hook.pendingIncome(alice) + hook.pendingIncome(hook.TEAM_WALLET()),
            "solvent on the live manager"
        );
    }
}
