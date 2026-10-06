// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KingBase} from "./KingBase.sol";
import {KingHook} from "../src/KingHook.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A wallet contract that re-enters the PoolManager or the hook while the router refunds its
/// ETH, i.e. while the PoolManager is unlocked by the router and the hook's own guard is not set.
contract SettlementReentrant {
    KingHook immutable hook;
    KingRouter immutable router;
    IPoolManager immutable manager;
    uint8 public mode; // 0: dethrone, 1: direct swap on the manager, 2: claim, 3: router buy
    uint256 public entered;
    bool public nestedSucceeded;

    constructor(KingHook hook_, IPoolManager manager_) {
        hook = hook_;
        router = hook_.router();
        manager = manager_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function buyOut(uint256 kingOut) external payable {
        router.buyExactOut{value: msg.value}(kingOut, false, block.timestamp);
    }

    function buyIn(bool mustTake) external payable {
        router.buyExactIn{value: msg.value}(0, mustTake, block.timestamp);
    }

    function sell(uint256 amount) external {
        IERC20(address(hook.token())).approve(address(router), amount);
        router.sellExactIn(amount, 0, block.timestamp);
    }

    receive() external payable {
        entered++;
        if (entered > 1) return;
        if (mode == 0) {
            try hook.dethrone() {
                nestedSucceeded = true;
            } catch {}
        } else if (mode == 1) {
            PoolKey memory key = hook.poolKey();
            try manager.swap(key, SwapParams(true, -int256(1e15), TickMath.MIN_SQRT_PRICE + 1), "") returns (
                BalanceDelta d
            ) {
                nestedSucceeded = true;
                manager.settle{value: uint256(uint128(-d.amount0()))}();
                manager.take(key.currency1, address(this), uint256(uint128(d.amount1())));
            } catch {}
        } else if (mode == 2) {
            try hook.claim() {
                nestedSucceeded = true;
            } catch {}
        } else {
            try router.buyExactIn{value: 0.01 ether}(0, false, block.timestamp) {
                nestedSucceeded = true;
            } catch {}
        }
    }
}

/// @dev A wallet that cannot receive ETH.
contract NoReceive {
    KingRouter immutable router;

    constructor(KingRouter r) {
        router = r;
    }

    function buyIn() external payable {
        router.buyExactIn{value: msg.value}(0, true, block.timestamp);
    }

    function buyOut(uint256 kingOut) external payable {
        router.buyExactOut{value: msg.value}(kingOut, false, block.timestamp);
    }
}

/// @dev Lends the king his tokens back for the duration of one call.
contract FlashHolder {
    IERC20 immutable token;
    KingHook immutable hook;

    constructor(IERC20 t, KingHook h) {
        token = t;
        hook = h;
    }

    /// @notice Returns true if `dethrone()` succeeded while the king was holding borrowed tokens.
    function shield(address king, uint256 amount) external returns (bool dethroned) {
        token.transfer(king, amount);
        try hook.dethrone() {
            dethroned = true;
        } catch {}
        token.transferFrom(king, address(this), amount);
    }
}

/// @notice Inputs the implementation did not expect: a drained pool, settlement-time reentry,
/// dust-sized swaps, contract wallets, flash-held balances, the team wallet on the throne.
contract KingHookAdversarialTest is KingBase {
    using StateLibrary for IPoolManager;

    uint256 constant FLOOR = 0.01 ether;

    function assertAccountingHolds(address[] memory wallets) internal view {
        uint256 owed = hook.pendingIncome(team);
        for (uint256 i = 0; i < wallets.length; i++) {
            owed += hook.pendingIncome(wallets[i]);
        }
        assertEq(hookClaims(), hook.pool() + hook.provisionalIncome() + owed, "claims != pool + credits");
        assertGe(address(manager).balance, hookClaims(), "claims not backed");
    }

    // ------------------------------------------------------------------ a pool drained of ETH

    /// @dev KING that never came out of the pool (the launch's remaining 10%) can exceed the ETH in
    /// the curve. Through a router that settles the real delta the seller keeps the unconsumed part
    /// and the fee is the rate of what the pool actually paid. (Through `KingRouter.sellExactIn` the
    /// unconsumed part stays in the router: reported, not tested around.)
    function test_thirdPartySellBeyondThePoolsEthFillsPartiallyAndKeepsTheRest() public {
        buyExactIn(alice, 1 ether, false); // 0.75 ETH in the curve
        address whale = makeAddr("whale");
        giveTokens(whale, 80_000_000 ether);
        uint256 rate = hook.feeRate();
        uint256 claimsBefore = hookClaims();
        uint256 managerBefore = address(manager).balance;

        BalanceDelta d = thirdPartySwap(whale, false, -int256(80_000_000 ether), 0, "");

        uint256 consumed = uint256(uint128(-d.amount1()));
        assertLt(consumed, 80_000_000 ether, "the pool could not absorb the whole sell");
        assertEq(token.balanceOf(whale), 80_000_000 ether - consumed, "unconsumed KING stays with the seller");
        assertEq(token.balanceOf(address(thirdPartyRouter)), 0);
        uint256 fee = hookClaims() - claimsBefore;
        uint256 gross = managerBefore - address(manager).balance + fee;
        assertEq(fee, (gross * rate) / 1_000_000, "fee is the rate of the ETH actually paid out");
        assertGt(whale.balance, 0);
        assertGe(address(manager).balance, hookClaims(), "the claims survive a drained curve");
    }

    /// @dev After a sell that drained the curve the price sits at the maximum; v4 refuses further
    /// sells at that limit until a buy moves the price back. The game and the fee keep working.
    function test_drainedPoolRecoversWithTheNextBuy() public {
        buyExactIn(carol, 0.1 ether, false); // a thin curve: ~0.075 ETH
        openGame();
        uint256 aliceTokens = buyExactIn(alice, 0.02 ether, false); // alice is king, price 0.024
        address whale = makeAddr("whale");
        giveTokens(whale, 100_000_000 ether);
        thirdPartySwap(whale, false, -int256(100_000_000 ether), 0, "");
        (uint160 sqrtPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPrice, TickMath.MAX_SQRT_PRICE - 1, "price pinned at the limit");
        assertEq(hook.king(), alice, "draining the pool does not touch the throne");
        assertGt(token.balanceOf(whale), 0, "the whale keeps what the pool could not buy");

        // Nothing to sell into: every sell reverts at the limit (v4's PriceLimitAlreadyExceeded).
        vm.startPrank(alice);
        token.approve(address(router), 1);
        vm.expectRevert();
        router.sellExactIn(1, 0, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), aliceTokens, "a refused sell returns the tokens");
        assertEq(hook.king(), alice);

        // A buy walks the price back into the range and pays its fee.
        uint256 claimsBefore = hookClaims();
        uint256 got = buyExactIn(bob, 0.02 ether, false);
        assertGt(got, 0);
        assertEq(hookClaims() - claimsBefore, 0.0005 ether);
        assertEq(hook.king(), alice, "0.02 ETH is below the 0.024 ETH price");
        // Sells work again and a sell by the king still dethrones him.
        sellExactIn(alice, 1);
        assertEq(hook.king(), address(0));
        address[] memory w = new address[](3);
        (w[0], w[1], w[2]) = (alice, bob, carol);
        assertAccountingHolds(w);
    }

    // ------------------------------------------------------------------ settlement-time reentrancy

    /// @dev While the router refunds a buyer's surplus ETH the PoolManager is unlocked by the router
    /// and the hook's guard is down. Nothing a buyer does in that window changes who is king, and
    /// the accounting still balances.
    function test_reentryDuringRouterSettlementCannotTouchTheThrone() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(bob, 1 ether, false); // bob is king, price 1.2 ETH
        vm.warp(block.timestamp + 10 minutes);
        uint256 bobOwed = hook.unclaimedIncome(bob);
        address[] memory w = new address[](2);
        (w[0], w[1]) = (bob, carol);

        for (uint8 mode = 0; mode < 4; mode++) {
            SettlementReentrant a = new SettlementReentrant(hook, IPoolManager(address(manager)));
            vm.deal(address(a), 10 ether);
            a.setMode(mode);
            a.buyOut{value: 0.5 ether}(1_000_000 ether); // far below the price; surplus refunded
            assertEq(a.entered(), 1, "the refund re-entered the buyer");
            assertEq(hook.king(), bob, "a nested call changed the king");
            assertEq(hook.reignCount(), 1);
            assertGe(hook.unclaimedIncome(bob), bobOwed, "a nested call cost the king income");
            if (mode == 1) {
                assertTrue(a.nestedSucceeded(), "a direct swap in the window is allowed and harmless");
            } else {
                assertFalse(a.nestedSucceeded(), "dethrone, claim and router calls are refused in the window");
            }
            assertAccountingHolds(w);
        }
    }

    /// @dev A buyer crowned by the outer swap who nests a swap before his tokens are delivered only
    /// ends his own reign: the holding rule sees his empty balance. The throne cannot be kept
    /// without the tokens even for the duration of one transaction.
    function test_selfCrownedBuyerNestingASwapLosesHisOwnThrone() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(bob, 1 ether, false);
        vm.warp(block.timestamp + 10 minutes);
        SettlementReentrant a = new SettlementReentrant(hook, IPoolManager(address(manager)));
        vm.deal(address(a), 10 ether);
        a.setMode(1);
        a.buyOut{value: 6 ether}(100_000_000 ether); // above 1.2 ETH: crowned in afterSwap
        assertTrue(a.nestedSucceeded());
        assertEq(hook.king(), address(0), "the nested swap dethroned the buyer before his tokens arrived");
        assertEq(hook.reignCount(), 2);
        IKingHook.Reign memory r = hook.getReign(1);
        assertEq(r.king, address(a));
        assertEq(r.end, block.timestamp);
        assertEq(uint8(r.reason), uint8(IKingHook.EndReason.Balance));
        assertGt(hook.unclaimedIncome(bob), 0, "bob was dethroned by a takeover and keeps his income");
        assertGe(token.balanceOf(address(a)), 100_000_000 ether, "the outer swap's tokens were still delivered");
        address[] memory w = new address[](3);
        (w[0], w[1], w[2]) = (bob, carol, address(a));
        assertAccountingHolds(w);
        // The throne is empty at the floor; anyone takes it.
        buyExactIn(alice, FLOOR, false);
        assertEq(hook.king(), alice);
    }

    // ------------------------------------------------------------------ dust

    /// @dev Amounts too small to carry a fee, or too small for v4 to swap at all (the LP fee is
    /// rounded off the input first, so a few wei buy nothing), neither revert nor mint a claim.
    function test_dustSwapsPayNoFeeAndDoNotRevert() public {
        uint256 bought = buyExactIn(alice, 1e12, false);
        uint256 claimsBefore = hookClaims();
        uint256 kingOut = buyExactIn(alice, 1, false); // 1 wei: fee rounds to zero
        assertEq(kingOut, 0, "v4 swaps nothing for one wei");
        buyExactIn(alice, 3, false);
        assertEq(hookClaims(), claimsBefore, "no claim is minted for a zero fee");
        // 4 wei at 25% is the first amount that pays (and the first that buys anything).
        buyExactIn(alice, 4, false);
        assertEq(hookClaims() - claimsBefore, 1);
        uint256 held = token.balanceOf(alice);
        assertGt(held, bought);
        openGame();
        uint256 ethOut = sellExactIn(alice, 1); // 1 wei of KING is worth 0 wei of ETH
        assertEq(ethOut, 0);
        assertEq(token.balanceOf(alice), held - 1);
        assertEq(hook.king(), address(0));
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    /// @dev The smallest takeover: exactly the floor, then exactly 1.2x of it, forever halving.
    function test_takeoverChainAtTheFloorIsExact() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 price = FLOOR;
        address[3] memory kings = [alice, bob, carol];
        for (uint256 i = 0; i < 6; i++) {
            buyExactIn(kings[i % 3], price, false);
            assertEq(hook.king(), kings[i % 3]);
            price = (price * 12) / 10;
            assertEq(hook.currentThronePrice(), price);
        }
        assertEq(hook.reignCount(), 6);
        vm.warp(block.timestamp + 1 hours);
        assertEq(hook.currentThronePrice(), price / 2);
    }

    // ------------------------------------------------------------------ wallets that are contracts

    /// @dev The buyer named by the router is `msg.sender`, so a contract wallet is the king and the
    /// holder. A wallet that cannot receive ETH can still buy exact-input and claim is the only call
    /// that fails for it; an exact-output buy with surplus fails because the refund cannot land.
    function test_contractWalletsAreIdentifiedAsTheBuyer() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        NoReceive w = new NoReceive(router);
        vm.deal(address(w), 2 ether);
        w.buyIn{value: 1 ether}();
        assertEq(hook.king(), address(w), "the contract, not its deployer, is the king");
        assertEq(token.balanceOf(address(w)), hook.requiredBalance());
        vm.warp(block.timestamp + 1 hours);
        assertGt(hook.unclaimedIncome(address(w)), 0);
        vm.prank(address(w));
        vm.expectRevert();
        hook.claim(); // its own problem only: the ETH cannot be delivered
        vm.expectRevert();
        w.buyOut{value: 0.5 ether}(1_000 ether); // the surplus refund cannot be delivered either
        assertEq(hook.king(), address(w));
        // Everyone else is unaffected.
        buyExactIn(bob, 1.2 ether, true);
        assertEq(hook.king(), bob);
        vm.prank(team);
        hook.claim();
    }

    // ------------------------------------------------------------------ the holding rule

    function test_aGiftToTheKingKeepsHimOnTheThrone() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 required = buyExactIn(alice, 1 ether, false);
        vm.prank(alice);
        token.transfer(bob, required / 2);
        giveTokens(alice, required / 2); // somebody tops the king up
        vm.expectRevert(abi.encodeWithSelector(IKingHook.KingHoldsEnough.selector, required, required));
        hook.dethrone();
        assertEq(hook.king(), alice, "the rule is about the balance, not where it came from");
    }

    /// @dev Borrowed tokens shield the king only for the duration of the borrow.
    function test_flashHeldTokensDoNotProtectTheKingBetweenTransactions() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 required = buyExactIn(alice, 1 ether, false);
        FlashHolder lender = new FlashHolder(IERC20(address(token)), hook);
        giveTokens(address(lender), required);
        vm.prank(alice);
        token.transfer(bob, required); // alice holds nothing
        vm.prank(alice);
        token.approve(address(lender), type(uint256).max);

        assertFalse(lender.shield(alice, required), "dethrone is refused while the borrowed tokens sit with the king");
        assertEq(hook.king(), alice);
        assertEq(token.balanceOf(alice), 0);
        hook.dethrone();
        assertEq(hook.king(), address(0), "and succeeds as soon as they are gone");
    }

    /// @dev An ex-king cannot gain by front-running `dethrone()` with `claim()`: the income credited
    /// is the same either way, and the dethrone still goes through.
    function test_frontRunningDethroneWithAClaimChangesNothing() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 required = buyExactIn(alice, 1 ether, false);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        token.transfer(bob, required);
        uint256 owed = hook.unclaimedIncome(alice);

        uint256 snap = vm.snapshotState();
        hook.dethrone();
        uint256 viaDethrone = hook.unclaimedIncome(alice);
        vm.revertToState(snap);

        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance, 1_000 ether - 1 ether + owed);
        hook.dethrone();
        assertEq(hook.king(), address(0));
        assertEq(hook.unclaimedIncome(alice), 0);
        assertEq(viaDethrone, owed, "same credit whichever runs first");
    }

    /// @dev The swap that evicts a short king still pays its fee, and if it is large enough it takes
    /// the empty throne at the floor inside the same swap.
    function test_theSwapThatEvictsAShortKingPaysItsFeeAndMayTakeTheThrone() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 required = buyExactIn(alice, 5 ether, false); // price 6 ETH
        vm.prank(alice);
        token.transfer(bob, required);
        uint256 claimsBefore = hookClaims();

        buyExactIn(bob, 0.5 ether, true); // far below 6 ETH, but the throne is empty by then
        assertEq(hook.king(), bob);
        assertEq(hookClaims() - claimsBefore, 0.0125 ether, "fee paid on the evicting swap");
        assertEq(hook.reignCount(), 2);
        assertEq(uint8(hook.getReign(0).reason), uint8(IKingHook.EndReason.Balance));
        assertEq(hook.getReign(1).paid, 0.5 ether);
        assertEq(hook.currentThronePrice(), 0.6 ether);
    }

    // ------------------------------------------------------------------ the team wallet

    function test_teamWalletCanBeKingAndClaimsBothShares() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        vm.deal(team, 10 ether);
        vm.prank(team);
        router.buyExactIn{value: 1 ether}(0, true, block.timestamp);
        assertEq(hook.king(), team);
        uint256 share = hook.pendingIncome(team);
        vm.warp(block.timestamp + 1 hours);
        uint256 income = hook.kingReignEarnings();
        assertEq(hook.unclaimedIncome(team), share + income);
        uint256 before = team.balance;
        vm.prank(team);
        hook.claim();
        assertEq(team.balance - before, share + income);
        assertEq(hook.unclaimedIncome(team), 0);
        assertEq(hook.king(), team);
    }

    // ------------------------------------------------------------------ credits across reigns

    function test_creditsAccumulateAcrossReignsAndOneClaimPaysAll() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 t0 = block.timestamp;
        buyExactIn(alice, 1 ether, false);
        vm.warp(t0 + 1 hours);
        buyExactIn(bob, 0.6 ether, false); // price halved to 0.6: bob takes
        uint256 first = hook.unclaimedIncome(alice);
        assertGt(first, 0);
        vm.warp(t0 + 2 hours);
        buyExactIn(alice, 0.36 ether, false); // bob's 0.72 halved
        assertEq(hook.king(), alice);
        vm.warp(t0 + 3 hours);
        buyExactIn(carol, 0.216 ether, false);
        uint256 second = hook.unclaimedIncome(alice) - first;
        assertGt(second, 0);
        assertEq(hook.getReign(0).earned, first);
        assertEq(hook.getReign(2).earned, second);

        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - before, first + second, "one claim pays both reigns");
        address[] memory w = new address[](3);
        (w[0], w[1], w[2]) = (alice, bob, carol);
        assertAccountingHolds(w);
    }

    // ------------------------------------------------------------------ boundaries

    function test_mustTakeAroundTheOpeningSecond() public {
        buyExactIn(carol, 10 ether, false);
        vm.warp(hook.gameStart() - 1);
        expectHookRevert(
            IHooks.afterSwap.selector, abi.encodeWithSelector(IKingHook.ThroneNotTaken.selector, 1 ether, FLOOR, false)
        );
        buyExactIn(alice, 1 ether, true);
        assertEq(hook.king(), address(0));
        vm.warp(hook.gameStart());
        buyExactIn(alice, 1 ether, true);
        assertEq(hook.king(), alice);
        assertEq(hook.reignStart(), hook.gameStart());
    }

    function test_reignHistoryPaginationEdges() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        assertEq(hook.getReigns(0, 10).length, 0);
        assertEq(hook.getReigns(0, 0).length, 0);
        buyExactIn(alice, FLOOR, false);
        buyExactIn(bob, 0.012 ether, false);
        assertEq(hook.getReigns(0, 0).length, 0);
        assertEq(hook.getReigns(2, 10).length, 0);
        assertEq(hook.getReigns(1, 10).length, 1);
        assertEq(hook.getReigns(0, 1)[0].king, alice);
        assertEq(hook.getReigns(0, 100).length, 2);
        vm.expectRevert();
        hook.getReign(2);
    }

    /// @dev `unclaimedIncome` is exactly what `claim()` pays, for every wallet and at every moment,
    /// including a king mid-vesting and a king past vesting with unbooked income.
    function test_unclaimedIncomeIsWhatClaimPays() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        buyExactIn(alice, 1 ether, false);
        vm.warp(block.timestamp + 2 minutes);
        assertEq(hook.unclaimedIncome(alice), 0);
        vm.prank(alice);
        vm.expectRevert(IKingHook.NothingToClaim.selector);
        hook.claim();
        vm.warp(block.timestamp + 20 minutes);
        uint256 owed = hook.unclaimedIncome(alice);
        assertGt(owed, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - before, owed);
        vm.warp(block.timestamp + 1);
        assertGt(hook.unclaimedIncome(alice), 0, "a second later there is income again");
    }
}
