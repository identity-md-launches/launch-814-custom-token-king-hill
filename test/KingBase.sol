// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {KingToken} from "../src/KingToken.sol";
import {KingHook} from "../src/KingHook.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IKingHook} from "../src/interfaces/IKingHook.sol";

/// @notice Shared fixture: a fresh PoolManager, the launch token, the hook at a mined address, the
/// KING/ETH pool at the launch price and the launch liquidity (90% of supply, KING only).
abstract contract KingBase is Test {
    using StateLibrary for IPoolManager;

    /// @dev sqrt(1e8) * 2^96: 1e8 KING per ETH, i.e. a 10 ETH market cap for 1e9 KING.
    uint160 internal constant INITIAL_SQRT_PRICE = 792281625142643375935439503360000;
    int24 internal constant INITIAL_TICK = 184216;
    /// @dev Launch liquidity sits entirely below the current tick, so it holds only KING.
    int24 internal constant LP_UPPER = 184200;
    int24 internal constant LP_LOWER = -887220;
    uint256 internal constant LP_SUPPLY = 900_000_000 ether;
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    KingToken internal token;
    KingHook internal hook;
    KingRouter internal router;
    PoolSwapTest internal thirdPartyRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    address internal team;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        token = new KingToken();
        hook = deployHook(manager, address(token));
        router = hook.router();
        team = hook.TEAM_WALLET();
        thirdPartyRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, INITIAL_SQRT_PRICE);
        seedLiquidity(LP_SUPPLY);

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    /// @dev Mines a salt for the declared flags and deploys the hook there with CREATE2.
    function deployHook(PoolManager manager_, address token_) internal returns (KingHook deployed) {
        bytes memory creationCode =
            abi.encodePacked(type(KingHook).creationCode, abi.encode(IPoolManager(address(manager_)), token_));
        (address predicted, bytes32 salt) =
            HookFlags.mine(address(this), HookFlags.KING_HOOK_FLAGS, creationCode, 500_000);
        deployed = new KingHook{salt: salt}(IPoolManager(address(manager_)), token_);
        require(address(deployed) == predicted, "hook address mismatch");
    }

    /// @dev Adds `amount` KING as single-sided liquidity below the current price.
    function seedLiquidity(uint256 amount) internal {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(LP_LOWER);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(LP_UPPER);
        uint128 liquidity = uint128(FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtB - sqrtA));
        token.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LP_LOWER, tickUpper: LP_UPPER, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
    }

    // ---------------------------------------------------------------- official router helpers

    function buyExactIn(address user, uint256 eth, bool mustTake) internal returns (uint256 kingOut) {
        vm.prank(user);
        kingOut = router.buyExactIn{value: eth}(0, mustTake, block.timestamp);
    }

    function buyExactOut(address user, uint256 kingOut, uint256 maxEth, bool mustTake)
        internal
        returns (uint256 ethIn)
    {
        vm.prank(user);
        ethIn = router.buyExactOut{value: maxEth}(kingOut, mustTake, block.timestamp);
    }

    function sellExactIn(address user, uint256 kingIn) internal returns (uint256 ethOut) {
        vm.startPrank(user);
        token.approve(address(router), kingIn);
        ethOut = router.sellExactIn(kingIn, 0, block.timestamp);
        vm.stopPrank();
    }

    function sellExactOut(address user, uint256 ethOut, uint256 maxKingIn) internal returns (uint256 kingIn) {
        vm.startPrank(user);
        token.approve(address(router), maxKingIn);
        kingIn = router.sellExactOut(ethOut, maxKingIn, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- third-party router helpers

    /// @dev A swap through a router the hook does not know, with arbitrary hookData.
    function thirdPartySwap(
        address user,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 ethValue,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        vm.startPrank(user);
        if (!zeroForOne) token.approve(address(thirdPartyRouter), type(uint256).max);
        delta = thirdPartyRouter.swap{value: ethValue}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- misc

    /// @dev A revert raised inside a hook callback reaches the caller wrapped by v4-core.
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

    function openGame() internal {
        vm.warp(hook.gameStart());
    }

    function hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), 0);
    }

    function giveTokens(address to, uint256 amount) internal {
        token.transfer(to, amount);
    }

    function assertApproxRel(uint256 a, uint256 b, uint256 relPpm, string memory err) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        assertLe(diff * 1_000_000, b * relPpm, err);
    }
}
