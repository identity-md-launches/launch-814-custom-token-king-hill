// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KingBase} from "./KingBase.sol";
import {KingHook} from "../src/KingHook.sol";
import {KingToken} from "../src/KingToken.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {Halving} from "../src/libraries/Halving.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Drives the whole system with bounded random play and checks per-operation postconditions
/// (assertion mode). A postcondition that fails is recorded in `violations` and surfaced by an
/// invariant, because `fail_on_revert = false` would otherwise silently discard a reverting handler
/// call together with the assertion inside it.
/// @dev Players: four actors who trade through the official router and through a third-party router
/// (random hookData), transfer KING to each other and to two outsiders, claim and call `dethrone()`.
/// A separate whale sells KING that never came out of the pool (the launch's remaining 10%) through
/// the third-party router, which drains the curve and makes later sells fill partially.
/// `KingRouter.sellExactIn` keeps the unconsumed part of a partially filled sell (reported in
/// `.imd-findings.json`, found by this handler before the cap existed), so exact-input router sells
/// are capped at what the curve can absorb (`routerSellCapacity`) instead of asserting the stranding.
contract KingPlayHandler is Test {
    KingHook immutable hook;
    KingRouter immutable router;
    KingToken immutable token;
    PoolManager immutable manager;
    PoolSwapTest immutable tpRouter;
    PoolKey key;
    address immutable team;
    address immutable treasury; // holds the launch's non-pool KING
    /// @dev Sells KING that never came out of the pool; never trades through `KingRouter`.
    address public immutable whale;

    address[] public actors;
    address[] public outsiders;

    // ---- ghosts
    uint256 public ghostFees; // every wei of fee the hook ever minted as a claim
    uint256 public ghostClaimed; // every wei paid out by claim()
    uint256 public ghostActorClaimed; // the part of ghostClaimed paid to actors (king income)
    uint256 public ghostTeamClaimed;
    uint256 public ghostTakeovers;
    uint256 public ghostRouterSwaps;
    uint256 public ghostThirdPartySwaps;
    uint256 public ghostMustTakeReverts;
    uint256 public ghostDethrones;
    uint256 public ghostOutsideSells;
    uint256 public violations;
    string public lastViolation;

    struct Snap {
        address king;
        uint256 required;
        uint256 kingBalance;
        uint256 price;
        uint256 poolSize;
        uint256 claims;
        uint256 teamPending;
        uint256 reigns;
        uint256 managerEth;
        bool open;
    }

    constructor(
        KingHook hook_,
        KingToken token_,
        PoolManager manager_,
        PoolSwapTest tpRouter_,
        PoolKey memory key_,
        address[] memory actors_,
        address[] memory outsiders_,
        address treasury_
    ) {
        hook = hook_;
        router = hook_.router();
        token = token_;
        manager = manager_;
        tpRouter = tpRouter_;
        key = key_;
        actors = actors_;
        outsiders = outsiders_;
        team = hook_.TEAM_WALLET();
        treasury = treasury_;
        whale = makeAddr("whale-outside-supply");
    }

    // ------------------------------------------------------------------ helpers

    function actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function outsider(uint256 seed) internal view returns (address) {
        return outsiders[seed % outsiders.length];
    }

    function record(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    function check(bool ok, string memory why) internal {
        if (!ok) record(why);
    }

    function snapshot() internal view returns (Snap memory s) {
        s.king = hook.king();
        s.required = hook.requiredBalance();
        s.kingBalance = s.king == address(0) ? 0 : token.balanceOf(s.king);
        s.price = hook.currentThronePrice();
        s.poolSize = hook.poolSize();
        s.claims = manager.balanceOf(address(hook), 0);
        s.teamPending = hook.pendingIncome(team);
        s.reigns = hook.reignCount();
        s.managerEth = address(manager).balance;
        s.open = hook.gameOpen();
    }

    /// @dev Whether the sitting king, if any, would lose the throne at the next swap by the holding rule.
    function kingShort(Snap memory s) internal pure returns (bool) {
        return s.king != address(0) && s.kingBalance < s.required;
    }

    /// @dev After a sell that exhausted the pool's ETH the price sits at the maximum; every further
    /// sell reverts in v4 (`PriceLimitAlreadyExceeded`) until a buy moves the price back.
    function sellsBlocked() internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), key.toId());
        return sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev The most KING an exact-input sell can hand the curve before the price leaves the launch
    /// position's range (upper tick 184200), net of the 0.3% LP fee and with a margin. Beyond it a
    /// sell fills partially, and `KingRouter.sellExactIn` then keeps the unconsumed part: that is the
    /// defect reported in `.imd-findings.json`, so the handler stays under the cap rather than
    /// asserting the stranding is fine. Drop this cap once the router refunds the remainder.
    function routerSellCapacity() internal view returns (uint256) {
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(pm, key.toId());
        uint128 liquidity = StateLibrary.getLiquidity(pm, key.toId());
        uint160 sqrtTop = TickMath.getSqrtPriceAtTick(184200);
        if (sqrtPriceX96 >= sqrtTop || liquidity == 0) return 0;
        uint256 absorbable = SqrtPriceMath.getAmount1Delta(sqrtPriceX96, sqrtTop, liquidity, false);
        return (absorbable * 990) / 1000;
    }

    /// @dev Checks every swap: the fee is ETH held as a claim, split 92/8, and the hook keeps nothing.
    function checkFee(Snap memory s, uint256 gross, bool exact) internal {
        uint256 feeDelta = manager.balanceOf(address(hook), 0) - s.claims;
        ghostFees += feeDelta;
        uint256 teamDelta = hook.pendingIncome(team) - s.teamPending;
        check(teamDelta == (feeDelta * 800) / 10_000, "team share is not 8% of the fee");
        uint256 expected = (gross * hook.feeRate()) / 1_000_000;
        if (exact) check(feeDelta == expected, "fee is not the rate of the gross ETH");
        else check(feeDelta + 2 >= expected && feeDelta <= expected + 2, "fee is off the rate by more than 2 wei");
        check(token.balanceOf(address(hook)) == 0, "hook holds KING");
        check(address(hook).balance == 0, "hook holds ETH");
        check(manager.balanceOf(address(hook), uint256(uint160(address(token)))) == 0, "hook holds KING claims");
    }

    // ------------------------------------------------------------------ official router

    function buyIn(uint256 seed, uint96 eth, bool mustTake) external {
        address a = actor(seed);
        eth = uint96(bound(eth, 1e12, 20 ether));
        if (a.balance < eth) return;
        Snap memory s = snapshot();
        uint256 tokensBefore = token.balanceOf(a);
        bool wouldTake = s.open && eth >= s.price;
        if (kingShort(s)) wouldTake = s.open && eth >= 0.01 ether;

        vm.prank(a);
        try router.buyExactIn{value: eth}(0, mustTake, block.timestamp) returns (uint256 kingOut) {
            ghostRouterSwaps++;
            check(!(mustTake && !wouldTake), "a must-take buy below the price went through");
            check(token.balanceOf(a) - tokensBefore == kingOut, "buyer did not receive the KING reported");
            check(address(manager).balance - s.managerEth == eth, "manager did not receive the full ETH input");
            checkFee(s, eth, true);
            if (wouldTake) {
                ghostTakeovers++;
                check(hook.king() == a, "a buy at or above the price did not take the throne");
                check(hook.takeoverPaid() == eth, "takeoverPaid is not the fee-inclusive ETH");
                check(hook.currentThronePrice() == (uint256(eth) * 12) / 10, "price is not 1.2x the payment");
                check(hook.requiredBalance() == kingOut, "required balance is not the KING delivered");
                check(hook.reignStart() == block.timestamp, "reign did not start now");
                check(hook.reignCount() == s.reigns + 1, "no history entry for the takeover");
            } else {
                check(hook.reignCount() == s.reigns, "a buy below the price opened a reign");
                if (kingShort(s)) check(hook.king() == address(0), "a short king survived a swap");
                else check(hook.king() == s.king, "a buy below the price changed the king");
            }
        } catch {
            if (mustTake && !wouldTake) {
                ghostMustTakeReverts++;
                check(manager.balanceOf(address(hook), 0) == s.claims, "a reverted must-take buy left a fee");
                check(token.balanceOf(a) == tokensBefore, "a reverted must-take buy delivered KING");
            } else {
                record("a plain buy reverted");
            }
        }
    }

    function buyOut(uint256 seed, uint96 kingOut, uint8 budgetPct) external {
        address a = actor(seed);
        kingOut = uint96(bound(kingOut, 1e15, 50_000_000 ether));
        uint256 maxEth = (a.balance * bound(budgetPct, 1, 50)) / 100;
        if (maxEth < 1e12) return;
        Snap memory s = snapshot();
        uint256 tokensBefore = token.balanceOf(a);
        uint256 ethBefore = a.balance;

        vm.prank(a);
        try router.buyExactOut{value: maxEth}(kingOut, false, block.timestamp) returns (uint256 ethIn) {
            ghostRouterSwaps++;
            check(token.balanceOf(a) - tokensBefore == kingOut, "exact-output buy delivered a different amount");
            check(ethBefore - a.balance == ethIn, "unused ETH was not refunded");
            check(address(manager).balance - s.managerEth == ethIn, "manager did not receive the gross ETH");
            checkFee(s, ethIn, false);
            bool took = s.open && ethIn >= (kingShort(s) ? 0.01 ether : s.price);
            if (took) {
                ghostTakeovers++;
                check(hook.king() == a, "an exact-output buy at the price did not take the throne");
                check(hook.takeoverPaid() == ethIn, "takeoverPaid is not pool ETH plus fee");
                check(hook.requiredBalance() == kingOut, "required balance is not the KING delivered");
            } else {
                check(hook.reignCount() == s.reigns, "an exact-output buy below the price opened a reign");
            }
        } catch {
            // Only an unaffordable request may fail: the budget was too small for the KING asked.
        }
    }

    function sellIn(uint256 seed, uint256 fraction) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        uint256 cap = routerSellCapacity();
        if (cap < bal) bal = cap;
        if (bal < 1) return;
        uint256 amount = bound(fraction, 1, bal);
        bal = token.balanceOf(a);
        Snap memory s = snapshot();
        uint256 ethBefore = a.balance;

        vm.startPrank(a);
        token.approve(address(router), amount);
        try router.sellExactIn(amount, 0, block.timestamp) returns (uint256 ethOut) {
            vm.stopPrank();
            ghostRouterSwaps++;
            check(token.balanceOf(a) == bal - amount, "exact-input sell did not consume exactly the amount");
            check(token.balanceOf(address(router)) == 0, "router kept KING after an exact-input sell");
            check(a.balance - ethBefore == ethOut, "seller did not receive the ETH reported");
            uint256 fee = manager.balanceOf(address(hook), 0) - s.claims;
            uint256 gross = s.managerEth - address(manager).balance + fee;
            check(ethOut + fee == gross, "net plus fee is not the gross pool output");
            checkFee(s, gross, true);
            if (a == s.king) check(hook.king() == address(0), "the king sold through the router and kept the throne");
            else if (kingShort(s)) check(hook.king() == address(0), "a short king survived a swap");
            else check(hook.king() == s.king, "somebody else's sell changed the king");
        } catch {
            vm.stopPrank();
            check(sellsBlocked(), "an exact-input sell of pool-sourced KING reverted");
            check(token.balanceOf(a) == bal, "a reverted exact-input sell kept KING");
        }
    }

    function sellOut(uint256 seed, uint96 ethOut) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal < 1) return;
        ethOut = uint96(bound(ethOut, 1e9, 0.5 ether));
        Snap memory s = snapshot();
        uint256 ethBefore = a.balance;

        vm.startPrank(a);
        token.approve(address(router), bal);
        try router.sellExactOut(ethOut, bal, block.timestamp) returns (uint256 kingIn) {
            vm.stopPrank();
            ghostRouterSwaps++;
            check(a.balance - ethBefore == ethOut, "exact-output sell paid a different amount");
            check(bal - token.balanceOf(a) == kingIn, "leftover KING was not refunded");
            check(token.balanceOf(address(router)) == 0, "router kept KING after an exact-output sell");
            uint256 fee = manager.balanceOf(address(hook), 0) - s.claims;
            uint256 gross = s.managerEth - address(manager).balance + fee;
            check(gross == ethOut + fee, "the pool did not pay net plus fee");
            checkFee(s, gross, false);
            if (a == s.king) check(hook.king() == address(0), "the king sold through the router and kept the throne");
            else if (kingShort(s)) check(hook.king() == address(0), "a short king survived a swap");
            else check(hook.king() == s.king, "somebody else's sell changed the king");
        } catch {
            vm.stopPrank();
            // The pool may not hold enough ETH (PartialFill) or the KING may not suffice: both revert whole.
            check(token.balanceOf(a) == bal, "a reverted exact-output sell kept KING");
        }
    }

    // ------------------------------------------------------------------ third-party router

    function tpBuy(uint256 seed, uint96 eth, bool exactOut, uint256 nameSeed, bool mustTake) external {
        address a = actor(seed);
        eth = uint96(bound(eth, 1e12, 10 ether));
        if (a.balance < eth) return;
        Snap memory s = snapshot();
        bytes memory hookData = abi.encode(actor(nameSeed), mustTake);
        int256 amount = exactOut ? int256(uint256(eth) * 1e7) : -int256(uint256(eth));
        uint256 value = exactOut ? uint256(eth) * 4 : eth; // generous budget for exact-output
        if (a.balance < value) return;
        vm.prank(a);
        try tpRouter.swap{value: value}(
            key,
            SwapParams(true, amount, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            hookData
        ) {
            ghostThirdPartySwaps++;
            uint256 gross = address(manager).balance - s.managerEth;
            checkFee(s, gross, !exactOut);
            check(hook.reignCount() == s.reigns, "a third-party buy opened a reign");
            if (kingShort(s)) check(hook.king() == address(0), "a short king survived a swap");
            else check(hook.king() == s.king, "a third-party buy changed the king");
        } catch {
            // An exact-output request can exceed the budget once the price has moved; exact input never fails.
            check(exactOut, "a third-party exact-input buy reverted");
            check(manager.balanceOf(address(hook), 0) == s.claims, "a reverted third-party buy left a fee");
        }
    }

    function tpSell(uint256 seed, uint256 fraction, uint256 nameSeed) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal < 1) return;
        uint256 amount = bound(fraction, 1, bal);
        Snap memory s = snapshot();
        vm.startPrank(a);
        token.approve(address(tpRouter), amount);
        try tpRouter.swap(
            key,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(actor(nameSeed), true)
        ) {
            vm.stopPrank();
            ghostThirdPartySwaps++;
            uint256 fee = manager.balanceOf(address(hook), 0) - s.claims;
            uint256 gross = s.managerEth - address(manager).balance + fee;
            checkFee(s, gross, true);
            check(hook.reignCount() == s.reigns, "a third-party sell opened a reign");
            // Not attributable during the swap: the king is caught by the balance rule at the next call.
            if (kingShort(s)) check(hook.king() == address(0), "a short king survived a swap");
            else check(hook.king() == s.king, "a third-party sell changed the king");
        } catch {
            vm.stopPrank();
            check(sellsBlocked(), "a third-party sell reverted");
        }
    }

    /// @dev KING that never came out of the pool, sold through the third-party router: this can
    /// exceed the ETH in the curve and partially fill. The seller keeps the unconsumed part.
    function sellOutsideSupply(uint96 amount) external {
        address a = whale;
        amount = uint96(bound(amount, 1e18, 5_000_000 ether));
        if (token.balanceOf(treasury) < amount) return;
        vm.prank(treasury);
        token.transfer(a, amount);
        Snap memory s = snapshot();
        uint256 bal = token.balanceOf(a);
        vm.startPrank(a);
        token.approve(address(tpRouter), amount);
        try tpRouter.swap(
            key,
            SwapParams(false, -int256(uint256(amount)), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            vm.stopPrank();
            ghostOutsideSells++;
            uint256 fee = manager.balanceOf(address(hook), 0) - s.claims;
            uint256 gross = s.managerEth - address(manager).balance + fee;
            checkFee(s, gross, true);
            check(token.balanceOf(a) >= bal - amount, "seller lost more KING than the swap consumed");
            check(token.balanceOf(address(tpRouter)) == 0, "third-party router kept KING");
            if (kingShort(s)) check(hook.king() == address(0), "a short king survived a swap");
            else check(hook.king() == s.king, "an outside sell changed the king");
        } catch {
            vm.stopPrank();
            check(sellsBlocked(), "an outside-supply sell reverted");
        }
    }

    // ------------------------------------------------------------------ plain transfers

    function transferOut(uint256 seed, uint256 seed2, uint256 fraction, bool toOutsider) external {
        address a = actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal < 1) return;
        address to = toOutsider ? outsider(seed2) : actor(seed2);
        Snap memory s = snapshot();
        vm.prank(a);
        token.transfer(to, bound(fraction, 1, bal));
        check(hook.king() == s.king, "a plain transfer changed the king");
        check(hook.reignCount() == s.reigns, "a plain transfer touched the history");
        check(manager.balanceOf(address(hook), 0) == s.claims, "a plain transfer moved fees");
    }

    // ------------------------------------------------------------------ time

    function warp(uint32 by) external {
        uint256 dt = bound(by, 1, 8 hours);
        Snap memory s = snapshot();
        uint256[] memory owedBefore = new uint256[](actors.length);
        for (uint256 i = 0; i < actors.length; i++) {
            owedBefore[i] = hook.unclaimedIncome(actors[i]);
        }
        vm.warp(block.timestamp + dt);

        check(hook.king() == s.king, "time changed the king");
        check(hook.requiredBalance() == s.required, "time changed the required balance");
        check(hook.currentThronePrice() <= s.price, "the throne price rose with time");
        check(hook.currentThronePrice() >= 0.01 ether, "the throne price fell below the floor");
        uint256 poolAfter = hook.poolSize();
        check(poolAfter <= s.poolSize, "the pool grew with time");
        if (s.king == address(0)) {
            check(poolAfter == s.poolSize, "the pool shrank without a king");
        } else {
            // Two chained decays each round down by at most 64 wei; the hook decays once from the
            // last booking, so allow for that composition error only.
            uint256 floor_ = Halving.decay(s.poolSize, dt * hook.INCOME_LOG2_PER_HOUR(), hook.INCOME_DEN());
            uint256 tolerance = 256 + floor_ / 1e16; // the library's rounding is relative, ~1e-17
            check(poolAfter + tolerance >= floor_, "the king was paid faster than 2% per hour compounded");
        }
        for (uint256 i = 0; i < actors.length; i++) {
            check(hook.unclaimedIncome(actors[i]) >= owedBefore[i], "time reduced somebody's claimable income");
        }
    }

    // ------------------------------------------------------------------ claims and dethrone

    function claim(uint256 seed) external {
        address a = seed % 5 == 0 ? team : actor(seed);
        uint256 owed = hook.unclaimedIncome(a);
        Snap memory s = snapshot();
        uint256 before = a.balance;
        vm.prank(a);
        try hook.claim() {
            uint256 got = a.balance - before;
            check(owed > 0, "claim paid with nothing owed");
            check(got == owed, "claim paid a different amount than unclaimedIncome");
            check(hook.unclaimedIncome(a) == 0, "something stayed claimable after a claim");
            check(s.claims - manager.balanceOf(address(hook), 0) == got, "claims burned differ from ETH paid");
            check(hook.king() == s.king, "a claim changed the king");
            ghostClaimed += got;
            if (a == team) ghostTeamClaimed += got;
            else ghostActorClaimed += got;
        } catch {
            check(owed == 0, "a wallet with income could not claim it");
        }
    }

    function dethrone() external {
        Snap memory s = snapshot();
        uint256 owedBefore = s.king == address(0) ? 0 : hook.unclaimedIncome(s.king);
        try hook.dethrone() {
            ghostDethrones++;
            if (!kingShort(s) || s.reigns == 0) {
                record("dethrone succeeded although the king held enough (or there was none)");
                return;
            }
            check(hook.king() == address(0), "dethrone left a king");
            check(hook.requiredBalance() == 0 && hook.currentThronePrice() == 0.01 ether, "throne not reset");
            IKingHook.Reign memory r = hook.getReign(s.reigns - 1);
            check(r.end == block.timestamp && r.reason == IKingHook.EndReason.Balance, "history not closed");
            bool vested = block.timestamp - r.start >= 5 minutes;
            if (vested) check(hook.unclaimedIncome(s.king) >= owedBefore, "dethrone reduced vested income");
            else check(r.earned == 0 && hook.unclaimedIncome(s.king) == owedBefore, "unvested income was kept");
        } catch {
            check(!kingShort(s), "dethrone refused although the king's balance is short");
            check(hook.king() == s.king, "a refused dethrone changed the king");
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function outsiderCount() external view returns (uint256) {
        return outsiders.length;
    }
}

/// @notice Conservation, consistency and liveness of the throne pool under random play.
contract KingHookConservationTest is KingBase {
    using StateLibrary for IPoolManager;

    KingPlayHandler handler;
    address[] actorList;
    address[] outsiderList;
    uint256 initialEth;

    function setUp() public override {
        super.setUp();
        actorList.push(alice);
        actorList.push(bob);
        actorList.push(carol);
        address dave = makeAddr("dave");
        vm.deal(dave, 1_000 ether);
        actorList.push(dave);
        outsiderList.push(makeAddr("erin"));
        outsiderList.push(makeAddr("frank"));
        // The launch's non-pool KING (10% of supply) sits with this contract, the handler's treasury.
        handler =
            new KingPlayHandler(hook, token, manager, thirdPartyRouter, key, actorList, outsiderList, address(this));
        targetContract(address(handler));
        initialEth = systemEth();
    }

    function systemEth() internal view returns (uint256 total) {
        total = address(manager).balance + address(hook).balance + address(router).balance
            + address(thirdPartyRouter).balance + address(handler).balance + team.balance + address(this).balance
            + handler.whale().balance;
        for (uint256 i = 0; i < actorList.length; i++) {
            total += actorList[i].balance;
        }
        for (uint256 i = 0; i < outsiderList.length; i++) {
            total += outsiderList[i].balance;
        }
    }

    function owedToEveryone() internal view returns (uint256 owed) {
        owed = hook.pendingIncome(team);
        for (uint256 i = 0; i < actorList.length; i++) {
            owed += hook.pendingIncome(actorList[i]);
        }
        for (uint256 i = 0; i < outsiderList.length; i++) {
            owed += hook.pendingIncome(outsiderList[i]);
        }
    }

    function actorsPending() internal view returns (uint256 owed) {
        for (uint256 i = 0; i < actorList.length; i++) {
            owed += hook.pendingIncome(actorList[i]);
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_everyPostconditionHeld() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @dev Every wei of fee ever taken is either still a claim or was paid out by claim().
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_feesAreConserved() public view {
        assertEq(handler.ghostFees(), hookClaims() + handler.ghostClaimed(), "fees in != claims + paid out");
    }

    /// @dev Internal accounting equals the claims, and the claims are backed by ETH in the manager.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_claimsEqualPoolPlusCredits() public view {
        assertEq(hookClaims(), hook.pool() + hook.provisionalIncome() + owedToEveryone(), "claims != pool + credits");
        assertGe(address(manager).balance, hookClaims(), "manager cannot back the claims");
        assertLe(hook.poolSize(), hook.pool(), "live pool above the booked pool");
    }

    /// @dev No ETH is created or destroyed anywhere in the system.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_ethIsConserved() public view {
        assertEq(systemEth(), initialEth, "ETH appeared or vanished");
    }

    /// @dev The reign history is a non-overlapping sequence whose earnings add up to what kings were
    /// credited, were paid, or are still earning.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_reignHistoryIsConsistent() public view {
        uint256 n = hook.reignCount();
        uint256 earnedSum;
        uint64 prevEnd;
        for (uint256 i = 0; i < n; i++) {
            IKingHook.Reign memory r = hook.getReign(i);
            earnedSum += r.earned;
            assertGe(r.start, prevEnd, "reigns overlap");
            assertGe(r.paid, 0.01 ether, "a reign was bought below the floor");
            assertGt(r.required, 0, "a reign requires no KING");
            if (i + 1 < n) {
                assertGt(r.end, 0, "a past reign is still open");
                assertGe(r.end, r.start, "a reign ended before it started");
                assertTrue(r.reason != IKingHook.EndReason.None, "a closed reign has no reason");
                prevEnd = r.end;
            } else if (r.end == 0) {
                assertEq(r.king, hook.king(), "the open reign's king is not the king");
                assertEq(r.reason == IKingHook.EndReason.None, true);
                assertEq(r.forfeited, 0, "an open reign forfeited income");
            } else {
                assertEq(hook.king(), address(0), "the last reign is closed but there is a king");
            }
            if (r.forfeited > 0) {
                assertTrue(r.reason == IKingHook.EndReason.Sold || r.reason == IKingHook.EndReason.Balance);
                assertLt(r.end - r.start, 5 minutes, "vested income was forfeited");
            }
        }
        assertEq(
            earnedSum,
            actorsPending() + handler.ghostActorClaimed() + hook.provisionalIncome() + (hook.pool() - hook.poolSize()),
            "reign earnings != credited + paid + accruing"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_throneIsConsistent() public view {
        address king = hook.king();
        if (king == address(0)) {
            assertEq(hook.requiredBalance(), 0);
            assertEq(hook.takeoverPaid(), 0);
            assertEq(hook.reignStart(), 0);
            assertEq(hook.currentThronePrice(), 0.01 ether);
            assertEq(hook.nextHalvingTime(), 0);
            assertEq(hook.kingReignEarnings(), 0);
            assertEq(hook.kingVestingIncome(), 0);
            assertEq(hook.provisionalIncome(), 0);
        } else {
            assertTrue(hook.gameOpen(), "a king before the game opened");
            assertGt(hook.requiredBalance(), 0);
            assertGe(hook.currentThronePrice(), 0.01 ether);
            assertLe(hook.currentThronePrice(), (hook.takeoverPaid() * 12) / 10, "price above 1.2x the payment");
            uint256 age = block.timestamp - hook.reignStart();
            if (age < 5 minutes) {
                assertEq(hook.kingVestingIncome(), hook.kingReignEarnings(), "reign income claimable before vesting");
                assertEq(hook.unclaimedIncome(king), hook.pendingIncome(king), "unvested income is claimable");
            } else {
                assertEq(hook.kingVestingIncome(), 0, "income still vesting after five minutes");
                assertEq(
                    hook.unclaimedIncome(king),
                    hook.pendingIncome(king) + hook.provisionalIncome() + (hook.pool() - hook.poolSize()),
                    "vested income not all claimable"
                );
            }
            uint256 next = hook.nextHalvingTime();
            if (next != 0) {
                assertGt(next, block.timestamp);
                assertEq((next - hook.reignStart()) % 1 hours, 0, "halving time off the hourly grid");
                assertLe(next - block.timestamp, 1 hours);
            }
        }
    }

    /// @dev The two routers and the hook hold nothing between calls (pool-sourced KING only through
    /// the official router; see the handler's note).
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_nothingIsStranded() public view {
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(thirdPartyRouter).balance, 0);
        assertEq(token.balanceOf(address(thirdPartyRouter)), 0);
    }

    /// @dev Drives the same handler through a seeded sequence, then everybody leaves: every credit
    /// is paid, the liquidity provider withdraws everything, and what remains is still backed.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_everyoneCanExitAfterRandomPlay(uint256 seed) public {
        uint256 r = seed;
        for (uint256 i = 0; i < 48; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            uint8 op = uint8(r % 11);
            uint256 x = r >> 8;
            if (op == 0) handler.buyIn(x, uint96(x >> 32), x % 3 == 0);
            else if (op == 1) handler.buyOut(x, uint96(x >> 32), uint8(x >> 128));
            else if (op == 2) handler.sellIn(x, x >> 64);
            else if (op == 3) handler.sellOut(x, uint96(x >> 32));
            else if (op == 4) handler.tpBuy(x, uint96(x >> 32), x % 2 == 0, x >> 160, x % 5 == 0);
            else if (op == 5) handler.tpSell(x, x >> 64, x >> 160);
            else if (op == 6) handler.transferOut(x, x >> 40, x >> 80, x % 2 == 0);
            else if (op == 7) handler.warp(uint32(x));
            else if (op == 8) handler.claim(x);
            else if (op == 9) handler.dethrone();
            else handler.sellOutsideSupply(uint96(x >> 32));
        }
        assertEq(handler.violations(), 0, handler.lastViolation());

        // Everybody with a credit is paid exactly that credit.
        address[] memory all = new address[](actorList.length + 1);
        for (uint256 i = 0; i < actorList.length; i++) {
            all[i] = actorList[i];
        }
        all[actorList.length] = team;
        for (uint256 i = 0; i < all.length; i++) {
            uint256 owed = hook.unclaimedIncome(all[i]);
            if (owed < 1) continue;
            uint256 before = all[i].balance;
            vm.prank(all[i]);
            hook.claim();
            assertEq(all[i].balance - before, owed);
        }

        // The liquidity provider removes the whole position; the pool's ETH leaves with it.
        (uint128 liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(lpRouter), LP_LOWER, LP_UPPER, bytes32(0));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LP_LOWER, tickUpper: LP_UPPER, liquidityDelta: -int256(uint256(liquidity)), salt: 0
            }),
            ""
        );

        // What is left is exactly the throne pool and the king's unvested accrual, still backed.
        // v4 rounds swap steps in the pool's favour, so a few wei per swap stay in the manager.
        uint256 kingPending = hook.king() == address(0) ? 0 : hook.pendingIncome(hook.king());
        assertEq(hookClaims(), hook.pool() + hook.provisionalIncome() + kingPending, "claims != pool + king credit");
        assertGe(address(manager).balance, hookClaims(), "LP exit left the claims unbacked");
        assertLt(address(manager).balance - hookClaims(), 1e6, "the manager holds ETH that belongs to nobody");
        assertLt(token.balanceOf(address(manager)), 1e6, "the manager holds KING that belongs to nobody");
    }
}
