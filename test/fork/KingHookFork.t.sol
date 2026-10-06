// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {KingToken} from "../../src/KingToken.sol";
import {KingHook} from "../../src/KingHook.sol";
import {KingRouter} from "../../src/KingRouter.sol";
import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Launch rehearsal against the live Uniswap v4 PoolManager on Base (chain id 8453).
/// @dev Skipped, never passed, when no RPC is reachable: the verifier runs offline, and a test that
/// asserted nothing must not read as a pass. With network access it deploys the token and the hook
/// on a fork, opens the pool the way the factory will, seeds the launch liquidity and trades.
contract KingHookForkTest is Test {
    using StateLibrary for IPoolManager;

    string constant BASE_RPC = "https://mainnet.base.org";
    uint256 constant BASE_CHAIN_ID = 8453;
    /// @dev Uniswap v4 PoolManager on Base, checked with `cast code` on 2026-10-06. Not a source of
    /// truth for the launch: the deployer supplies the chain's PoolManager as `$poolManager`.
    address constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    uint160 constant INITIAL_SQRT_PRICE = 792281625142643375935439503360000;
    int24 constant LP_UPPER = 184200;
    int24 constant LP_LOWER = -887220;

    bool forked;
    IPoolManager manager;
    KingToken token;
    KingHook hook;
    KingRouter router;
    PoolKey key;
    // Fork-only names: addresses derived from common labels can carry code on a live chain.
    address alice = makeAddr("king-fork-rehearsal-alice-2026");
    address bob = makeAddr("king-fork-rehearsal-bob-2026");

    receive() external payable {}

    function setUp() public {
        try vm.createSelectFork(BASE_RPC) returns (uint256) {
            forked = block.chainid == BASE_CHAIN_ID && BASE_POOL_MANAGER.code.length > 0;
        } catch {
            forked = false;
        }
        if (!forked) {
            vm.skip(true);
            return;
        }

        manager = IPoolManager(BASE_POOL_MANAGER);
        token = new KingToken();
        bytes memory creationCode = abi.encodePacked(type(KingHook).creationCode, abi.encode(manager, address(token)));
        (address predicted, bytes32 salt) =
            HookFlags.mine(address(this), HookFlags.KING_HOOK_FLAGS, creationCode, 500_000);
        hook = new KingHook{salt: salt}(manager, address(token));
        assertEq(address(hook), predicted);
        router = hook.router();

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, INITIAL_SQRT_PRICE);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(LP_LOWER);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(LP_UPPER);
        uint128 liquidity = uint128(FullMath.mulDiv(900_000_000 ether, FixedPoint96.Q96, sqrtB - sqrtA));
        token.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(LP_LOWER, LP_UPPER, int256(uint256(liquidity)), 0), "");

        require(alice.code.length == 0 && bob.code.length == 0, "test wallets must be plain accounts on this fork");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_fork_poolOpensAtTheLaunchPrice() public view {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, INITIAL_SQRT_PRICE);
        assertEq(tick, 184216);
        assertTrue(hook.initialized());
        assertEq(hook.feeRate(), 250_000);
    }

    function test_fork_feesAndThroneOnTheLiveManager() public {
        uint256 managerEthBefore = address(manager).balance;
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);

        // Anti-snipe buy: 25% fee, held as claims on the live manager.
        uint256 aliceTokens = router.buyExactIn{value: 2 ether}(0, false, block.timestamp);
        assertEq(manager.balanceOf(address(hook), 0) - claimsBefore, 0.5 ether);
        assertEq(address(manager).balance - managerEthBefore, 2 ether);
        assertEq(hook.king(), address(0));

        // Game opens: bob takes the throne at the floor price, alice sells and pays the fee in ETH.
        vm.warp(hook.gameStart());
        assertEq(hook.feeRate(), 25_000);
        vm.prank(bob);
        router.buyExactIn{value: 0.5 ether}(0, true, block.timestamp);
        assertEq(hook.king(), bob);
        assertEq(hook.currentThronePrice(), 0.6 ether);

        token.approve(address(router), aliceTokens);
        uint256 ethOut = router.sellExactIn(aliceTokens / 2, 0, block.timestamp);
        assertGt(ethOut, 0);
        assertEq(hook.king(), bob, "another wallet's sell does not touch the throne");

        // An hour later bob claims his income from the live manager and the price has halved.
        vm.warp(block.timestamp + 1 hours);
        assertEq(hook.currentThronePrice(), 0.3 ether);
        uint256 owed = hook.unclaimedIncome(bob);
        assertGt(owed, 0);
        uint256 before = bob.balance;
        vm.prank(bob);
        hook.claim();
        assertEq(bob.balance - before, owed);

        // The team wallet pulls its 8%.
        address team = hook.TEAM_WALLET();
        uint256 teamOwed = hook.pendingIncome(team);
        assertGt(teamOwed, 0);
        vm.prank(team);
        hook.claim();
        assertEq(team.balance, teamOwed);

        assertEq(manager.balanceOf(address(hook), 0), hook.pool() + hook.pendingIncome(bob), "solvent");
    }
}
