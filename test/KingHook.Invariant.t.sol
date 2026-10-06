// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KingBase} from "./KingBase.sol";
import {KingHook} from "../src/KingHook.sol";
import {KingToken} from "../src/KingToken.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

/// @dev Drives the game with random buys, sells, transfers, claims, dethrones and time.
contract KingHandler is Test {
    KingHook immutable hook;
    KingRouter immutable router;
    KingToken immutable token;
    PoolManager immutable manager;
    address[] public actors;
    address immutable team;

    uint256 public ghostClaimed;
    uint256 public ghostFees;

    constructor(KingHook hook_, KingToken token_, PoolManager manager_, address[] memory actors_) {
        hook = hook_;
        router = hook_.router();
        token = token_;
        manager = manager_;
        actors = actors_;
        team = hook_.TEAM_WALLET();
    }

    function actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buyIn(uint256 seed, uint96 eth, bool mustTake) external {
        address a = actor(seed);
        eth = uint96(bound(eth, 1e12, 20 ether));
        if (a.balance < eth) return;
        vm.prank(a);
        try router.buyExactIn{value: eth}(0, mustTake, block.timestamp) {} catch {}
    }

    function buyOut(uint256 seed, uint96 kingOut) external {
        address a = actor(seed);
        kingOut = uint96(bound(kingOut, 1e15, 50_000_000 ether));
        uint256 maxEth = a.balance / 2;
        if (maxEth < 1e12) return;
        vm.prank(a);
        try router.buyExactOut{value: maxEth}(kingOut, false, block.timestamp) {} catch {}
    }

    function sellIn(uint256 seed, uint256 fraction) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal < 2) return;
        uint256 amount = bound(fraction, 1, bal);
        vm.startPrank(a);
        token.approve(address(router), amount);
        try router.sellExactIn(amount, 0, block.timestamp) {} catch {}
        vm.stopPrank();
    }

    function sellOut(uint256 seed, uint96 ethOut) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal < 1) return;
        ethOut = uint96(bound(ethOut, 1e9, 0.5 ether));
        vm.startPrank(a);
        token.approve(address(router), bal);
        try router.sellExactOut(ethOut, bal, block.timestamp) {} catch {}
        vm.stopPrank();
    }

    function transferOut(uint256 seed, uint256 seed2, uint256 fraction) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal < 1) return;
        vm.prank(a);
        token.transfer(actor(seed2), bound(fraction, 1, bal));
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + bound(by, 1, 12 hours));
    }

    function claim(uint256 seed) external {
        address a = seed % 7 == 0 ? team : actor(seed);
        uint256 owed = hook.unclaimedIncome(a);
        if (owed < 1) return;
        uint256 before = a.balance;
        vm.prank(a);
        hook.claim();
        uint256 got = a.balance - before;
        require(got == owed, "claim paid a different amount");
        ghostClaimed += got;
    }

    function dethrone() external {
        try hook.dethrone() {} catch {}
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @notice Solvency and consistency invariants under random play.
contract KingHookInvariantTest is KingBase {
    KingHandler handler;
    address[] actorList;

    function setUp() public override {
        super.setUp();
        actorList.push(alice);
        actorList.push(bob);
        actorList.push(carol);
        address dave = makeAddr("dave");
        vm.deal(dave, 1_000 ether);
        actorList.push(dave);
        handler = new KingHandler(hook, token, manager, actorList);
        targetContract(address(handler));
    }

    function owedTotal() internal view returns (uint256 owed) {
        owed = hook.pendingIncome(team);
        for (uint256 i = 0; i < actorList.length; i++) {
            owed += hook.pendingIncome(actorList[i]);
        }
    }

    /// @dev Every wei of fee is either in the pool or credited to someone, and the claims are real.
    function invariant_claimsBackThePoolAndEveryCredit() public view {
        assertEq(hookClaims(), hook.pool() + hook.provisionalIncome() + owedTotal());
        assertGe(address(manager).balance, hookClaims());
    }

    function invariant_hookAndRouterHoldNothing() public view {
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function invariant_throneStateIsConsistent() public view {
        if (hook.king() == address(0)) {
            assertEq(hook.requiredBalance(), 0);
            assertEq(hook.currentThronePrice(), 0.01 ether);
            assertEq(hook.kingReignEarnings(), 0);
            assertEq(hook.provisionalIncome(), 0);
        } else {
            assertTrue(hook.gameOpen(), "a king only exists once the game is open");
            assertGe(hook.currentThronePrice(), 0.01 ether);
            assertGt(hook.requiredBalance(), 0);
            assertEq(hook.getReign(hook.reignCount() - 1).end, 0);
            assertEq(hook.getReign(hook.reignCount() - 1).king, hook.king());
        }
        if (hook.king() != address(0) && token.balanceOf(hook.king()) < hook.requiredBalance()) {
            assertEq(hook.poolSize(), hook.pool() + hook.provisionalIncome(), "projects forfeiture");
            assertEq(hook.unclaimedIncome(hook.king()), hook.pendingIncome(hook.king()));
        } else {
            assertLe(hook.poolSize(), hook.pool());
        }
    }

    function invariant_nobodyIsOwedMoreThanTheClaimsCanPay() public view {
        assertLe(owedTotal() + hook.poolSize() + hook.kingVestingIncome(), hookClaims());
    }
}
