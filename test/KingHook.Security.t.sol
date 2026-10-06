// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KingBase} from "./KingBase.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {KingHook} from "../src/KingHook.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A king whose wallet is a contract that re-enters the hook when it receives ETH.
contract ReentrantKing {
    KingHook immutable hook;
    KingRouter immutable router;
    uint256 public reentries;
    uint256 public reentryFailures;
    uint8 public mode; // 0: claim again, 1: swap during the payout, 2: dethrone during the payout

    constructor(KingHook hook_) {
        hook = hook_;
        router = hook_.router();
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function take() external payable {
        router.buyExactIn{value: msg.value}(0, true, block.timestamp);
    }

    function claim() external {
        hook.claim();
    }

    receive() external payable {
        reentries++;
        if (reentries > 3) return;
        if (mode == 0) {
            try hook.claim() {}
            catch {
                reentryFailures++;
            }
        } else if (mode == 1) {
            try router.buyExactIn{value: 0.01 ether}(0, false, block.timestamp) {}
            catch {
                reentryFailures++;
            }
        } else {
            try hook.dethrone() {}
            catch {
                reentryFailures++;
            }
        }
    }
}

/// @notice Access control, initialization, reentrancy, solvency and the absence of any admin surface.
contract KingHookSecurityTest is KingBase {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // ------------------------------------------------------------------ permissions and address

    function test_permissionsMatchTheMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize, "launch hooks need an initialization callback");
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.KING_HOOK_FLAGS);
        assertEq(HookFlags.KING_HOOK_FLAGS, 0x20CC);
        assertEq(hook.FLAGS(), HookFlags.KING_HOOK_FLAGS);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), LP_FEE));
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "over the EIP-170 limit");
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "SELFDESTRUCT, DELEGATECALL or CALLCODE");
        }
    }

    // ------------------------------------------------------------------ caller checks

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        vm.expectRevert(IKingHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(IKingHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(IKingHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
        vm.expectRevert(IKingHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(address(this), 1 ether));
        vm.expectRevert(KingRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    function test_unlockCallbackRefusesThePoolManagerOutsideAPayout() public {
        vm.prank(address(manager));
        vm.expectRevert(IKingHook.UnexpectedCallback.selector);
        hook.unlockCallback(abi.encode(address(this), 1 ether));
    }

    function test_unimplementedCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        vm.startPrank(address(manager));
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(IKingHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ initialization

    function test_initializationRecordsTheLaunch() public view {
        assertTrue(hook.initialized());
        assertEq(hook.launchTime(), block.timestamp);
        assertEq(hook.gameStart(), block.timestamp + 30 minutes);
        PoolKey memory stored = hook.poolKey();
        assertEq(Currency.unwrap(stored.currency1), address(token));
        assertEq(stored.fee, LP_FEE);
    }

    function test_hookAcceptsOnlyOnePool() public {
        PoolKey memory other = key;
        other.fee = 10_000;
        other.tickSpacing = 200;
        vm.expectRevert();
        manager.initialize(other, INITIAL_SQRT_PRICE);
    }

    function test_hookRejectsWrongCurrencies() public {
        PoolManager fresh = new PoolManager(address(this));
        KingHook freshHook = deployHook(fresh, address(token));
        MockERC20 other = new MockERC20("O", "O", 1 ether);
        (Currency c0, Currency c1) = address(other) < address(token)
            ? (Currency.wrap(address(other)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(other)));
        PoolKey memory bad = PoolKey(c0, c1, LP_FEE, TICK_SPACING, IHooks(address(freshHook)));
        vm.expectRevert();
        fresh.initialize(bad, SQRT_PRICE_1_1);

        PoolKey memory badToken = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(other)),
            LP_FEE,
            TICK_SPACING,
            IHooks(address(freshHook))
        );
        vm.expectRevert();
        fresh.initialize(badToken, SQRT_PRICE_1_1);
        assertFalse(freshHook.initialized());
    }

    function test_hookRejectsUnlistedAndDynamicLpFees() public {
        PoolManager fresh = new PoolManager(address(this));
        KingHook freshHook = deployHook(fresh, address(token));
        PoolKey memory k =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 100, 1, IHooks(address(freshHook)));
        vm.expectRevert();
        fresh.initialize(k, INITIAL_SQRT_PRICE);
        k.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        k.tickSpacing = 60;
        vm.expectRevert();
        fresh.initialize(k, INITIAL_SQRT_PRICE);
        k.fee = 0;
        vm.expectRevert();
        fresh.initialize(k, INITIAL_SQRT_PRICE);
        assertFalse(freshHook.initialized());
    }

    function test_hookAcceptsEveryListedLpFee() public {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10_000)];
        int24[3] memory spacings = [int24(10), int24(60), int24(200)];
        for (uint256 i = 0; i < fees.length; i++) {
            PoolManager fresh = new PoolManager(address(this));
            KingHook freshHook = deployHook(fresh, address(token));
            PoolKey memory k = PoolKey(
                CurrencyLibrary.ADDRESS_ZERO,
                Currency.wrap(address(token)),
                fees[i],
                spacings[i],
                IHooks(address(freshHook))
            );
            fresh.initialize(k, INITIAL_SQRT_PRICE);
            assertTrue(freshHook.initialized());
        }
    }

    function test_constructorRejectsAddressesWithoutCode() public {
        vm.expectRevert("KingHook: token has no code");
        new KingHook(IPoolManager(address(manager)), address(0xdead));
        vm.expectRevert("KingHook: pool manager has no code");
        new KingHook(IPoolManager(address(0xdead)), address(token));
    }

    function test_swapsBeforeInitializationAreImpossible() public {
        PoolManager fresh = new PoolManager(address(this));
        KingHook freshHook = deployHook(fresh, address(token));
        assertFalse(freshHook.gameOpen());
        assertEq(freshHook.feeRate(), 250_000);
        KingRouter freshRouter = freshHook.router();
        vm.expectRevert();
        freshRouter.buyExactIn{value: 1 ether}(0, false, block.timestamp);
    }

    // ------------------------------------------------------------------ reentrancy

    function setUpReentrantKing() internal returns (ReentrantKing k) {
        buyExactIn(carol, 10 ether, false);
        openGame();
        k = new ReentrantKing(hook);
        vm.deal(address(k), 10 ether);
        k.take{value: 1 ether}();
        assertEq(hook.king(), address(k));
        vm.warp(block.timestamp + 1 hours);
    }

    function test_reentrantClaimIsPaidExactlyOnce() public {
        ReentrantKing k = setUpReentrantKing();
        uint256 owed = hook.unclaimedIncome(address(k));
        uint256 before = address(k).balance;
        uint256 claimsBefore = hookClaims();
        k.claim();
        assertEq(address(k).balance - before, owed, "paid once");
        assertEq(k.reentries(), 1);
        assertEq(k.reentryFailures(), 1, "the nested claim reverted");
        assertEq(hook.pendingIncome(address(k)), 0);
        assertEq(claimsBefore - hookClaims(), owed, "claims burned once");
    }

    function test_swapDuringAPayoutIsRefused() public {
        ReentrantKing k = setUpReentrantKing();
        k.setMode(1);
        uint256 kingBefore = token.balanceOf(address(k));
        k.claim();
        assertEq(k.reentryFailures(), 1, "the nested swap reverted");
        assertEq(token.balanceOf(address(k)), kingBefore);
        assertEq(hook.king(), address(k));
    }

    function test_dethroneDuringAPayoutIsRefused() public {
        ReentrantKing k = setUpReentrantKing();
        k.setMode(2);
        k.claim();
        assertEq(k.reentryFailures(), 1);
        assertEq(hook.king(), address(k));
    }

    function test_hookCallbacksRefuseToRunDuringAPayout() public {
        // Direct check of the guard: pretend the manager calls back while the guard is set is not
        // possible from outside, so verify via the swap-during-payout path above and the claim path.
        ReentrantKing k = setUpReentrantKing();
        k.setMode(1);
        uint256 poolBefore = hook.poolSize();
        k.claim();
        assertEq(hook.poolSize(), poolBefore, "no fee reached the pool during the payout");
    }

    // ------------------------------------------------------------------ foreign routers

    function test_hookDataFromAnotherRouterIsIgnored() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        thirdPartySwap(alice, true, -1 ether, 1 ether, abi.encode(alice, true));
        assertEq(hook.king(), address(0), "a foreign router cannot name a king");
        assertGt(token.balanceOf(alice), 0, "...and the flag does not revert its swap");
        thirdPartySwap(alice, true, -1 ether, 1 ether, abi.encode(bob, false));
        assertEq(hook.king(), address(0));
    }

    function test_routerCannotBeSpoofedThroughTheManager() public {
        // Calling the manager directly with the router's hookData from this contract: sender is this
        // contract, not the router, so no throne.
        buyExactIn(carol, 10 ether, false);
        openGame();
        thirdPartySwap(alice, true, -1 ether, 1 ether, abi.encode(alice, false));
        assertEq(hook.king(), address(0));
    }

    // ------------------------------------------------------------------ no owner, no parameters

    function test_noOwnerOrParameterFunctions() public {
        string[14] memory signatures = [
            "owner()",
            "pause()",
            "unpause()",
            "transferOwnership(address)",
            "setFee(uint256)",
            "setTeamWallet(address)",
            "setFloor(uint256)",
            "withdraw(uint256)",
            "withdraw()",
            "emergencyWithdraw()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "sweep(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(this), uint256(1));
            (bool ok,) = address(hook).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = address(router).call(data);
            assertFalse(ok, signatures[i]);
        }
    }

    function test_hookNeverHoldsValueDirectly() public {
        buyExactIn(carol, 10 ether, false);
        openGame();
        uint256 t = buyExactIn(alice, 1 ether, false);
        sellExactIn(alice, t / 3);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------------------ partial fills

    function test_exactOutputSellBeyondPoolEthReverts() public {
        uint256 t = buyExactIn(alice, 1 ether, false); // the pool now holds 0.75 ETH
        vm.startPrank(alice);
        token.approve(address(router), t);
        vm.expectRevert();
        router.sellExactOut(5 ether, t, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), t, "tokens returned on revert");
    }

    // ------------------------------------------------------------------ solvency

    function test_poolSolvencyAcrossALifecycle() public {
        address[4] memory users = [alice, bob, carol, address(this)];
        buyExactIn(alice, 5 ether, false);
        buyExactOut(bob, 3_000_000 ether, 2 ether, false);
        openGame();
        buyExactIn(carol, 1 ether, false); // carol is king
        vm.warp(block.timestamp + 2 hours);
        sellExactIn(alice, token.balanceOf(alice) / 2);
        buyExactIn(alice, 2 ether, false); // alice dethrones carol (price 0.3 after 2h)
        vm.warp(block.timestamp + 5 hours);
        sellExactOut(bob, 0.01 ether, token.balanceOf(bob));
        assertEq(hook.king(), alice);
        uint256 excess = token.balanceOf(alice) - hook.requiredBalance() + 1;
        vm.prank(alice);
        token.transfer(bob, excess);
        hook.dethrone();
        vm.warp(block.timestamp + 1 hours);
        buyExactIn(bob, 0.5 ether, false);

        assertSolvent(users);
        for (uint256 i = 0; i < users.length; i++) {
            uint256 owed = hook.unclaimedIncome(users[i]);
            if (owed < 1) continue;
            uint256 before = users[i].balance;
            vm.prank(users[i]);
            hook.claim();
            assertEq(users[i].balance - before, owed);
        }
        vm.prank(team);
        hook.claim();
        assertEq(
            hookClaims(),
            hook.poolSize() + hook.unclaimedIncome(hook.king()),
            "only the pool and the king's accrual remain"
        );
        assertSolvent(users);
    }

    function assertSolvent(address[4] memory users) internal view {
        uint256 owed = hook.pendingIncome(team);
        for (uint256 i = 0; i < users.length; i++) {
            owed += hook.pendingIncome(users[i]);
        }
        assertEq(hookClaims(), hook.pool() + hook.provisionalIncome() + owed, "claims cover the pool and every credit");
        assertGe(address(manager).balance, hookClaims(), "the manager holds the ETH behind the claims");
    }
}
