// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IKingHook} from "./interfaces/IKingHook.sol";

/// @title KingRouter
/// @notice The official swap router of the KING/ETH pool, deployed by `KingHook` itself.
/// @dev The hook only trusts the buyer identity carried in hookData when the swap comes from this
/// router, because this router always writes `msg.sender` there and always delivers the output to
/// `msg.sender`. The user therefore is the wallet that holds the tokens, which is what the holding
/// rule needs. Tokens for a sell are pulled from `msg.sender` before the PoolManager is unlocked and
/// settled from the router's own balance; ETH for a buy is `msg.value`, settled in full and the
/// unused part taken back to the user by the PoolManager. The router has no owner and holds nothing
/// between calls.
contract KingRouter is IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    IERC20 public immutable token;
    IKingHook public immutable hook;

    struct Order {
        address user;
        bool zeroForOne;
        int256 amountSpecified;
        bool mustTake;
    }

    error Expired();
    error ZeroAmount();
    error NotPoolManager();
    error UnexpectedCallback();
    error TooLittleReceived(uint256 received, uint256 minimum);
    error TooMuchRequested(uint256 required, uint256 maximum);

    event Swapped(address indexed user, bool isBuy, uint256 ethAmount, uint256 kingAmount);

    constructor(IPoolManager poolManager_, address token_, address hook_) {
        poolManager = poolManager_;
        token = IERC20(token_);
        hook = IKingHook(hook_);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @notice Buys KING with exactly `msg.value` ETH (fee included).
    /// @param minKingOut Slippage guard on the KING received.
    /// @param mustTake When true the swap reverts unless this buy takes the throne.
    function buyExactIn(uint256 minKingOut, bool mustTake, uint256 deadline)
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 kingOut)
    {
        if (msg.value < 1) revert ZeroAmount();
        BalanceDelta delta = _swap(Order(msg.sender, true, -int256(msg.value), mustTake));
        kingOut = uint256(uint128(delta.amount1()));
        if (kingOut < minKingOut) revert TooLittleReceived(kingOut, minKingOut);
        emit Swapped(msg.sender, true, uint256(uint128(-delta.amount0())), kingOut);
    }

    /// @notice Buys exactly `kingOut` KING, paying at most `msg.value` ETH (fee included).
    function buyExactOut(uint256 kingOut, bool mustTake, uint256 deadline)
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethIn)
    {
        if (kingOut < 1) revert ZeroAmount();
        BalanceDelta delta = _swap(Order(msg.sender, true, int256(kingOut), mustTake));
        ethIn = uint256(uint128(-delta.amount0()));
        emit Swapped(msg.sender, true, ethIn, uint256(uint128(delta.amount1())));
    }

    /// @notice Sells exactly `kingIn` KING for ETH (fee already deducted from the amount received).
    function sellExactIn(uint256 kingIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        if (kingIn < 1) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), kingIn);
        BalanceDelta delta = _swap(Order(msg.sender, false, -int256(kingIn), false));
        ethOut = uint256(uint128(delta.amount0()));
        if (ethOut < minEthOut) revert TooLittleReceived(ethOut, minEthOut);
        emit Swapped(msg.sender, false, ethOut, kingIn);
    }

    /// @notice Sells KING for exactly `ethOut` ETH (net of fee), spending at most `maxKingIn`.
    function sellExactOut(uint256 ethOut, uint256 maxKingIn, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 kingIn)
    {
        if (ethOut < 1 || maxKingIn < 1) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), maxKingIn);
        BalanceDelta delta = _swap(Order(msg.sender, false, int256(ethOut), false));
        kingIn = uint256(uint128(-delta.amount1()));
        emit Swapped(msg.sender, false, ethOut, kingIn);
        uint256 leftover = token.balanceOf(address(this));
        if (leftover > 0) token.safeTransfer(msg.sender, leftover);
    }

    /// @notice PoolManager callback: performs the swap and settles both sides.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_reentrancyGuardEntered()) revert UnexpectedCallback();
        Order memory order = abi.decode(data, (Order));
        PoolKey memory key = hook.poolKey();

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: order.amountSpecified,
                sqrtPriceLimitX96: order.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(order.user, order.mustTake)
        );

        if (order.zeroForOne) {
            uint256 ethIn = uint256(uint128(-delta.amount0()));
            uint256 available = address(this).balance;
            if (ethIn > available) revert TooMuchRequested(ethIn, available);
            // Settle everything the user sent, then let the PoolManager hand the surplus back.
            uint256 paid = poolManager.settle{value: available}();
            if (paid != available) revert TooMuchRequested(available, paid);
            if (available > ethIn) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, order.user, available - ethIn);
            uint256 kingOut = uint256(uint128(delta.amount1()));
            if (kingOut > 0) poolManager.take(key.currency1, order.user, kingOut);
        } else {
            uint256 kingIn = uint256(uint128(-delta.amount1()));
            uint256 held = token.balanceOf(address(this));
            if (kingIn > held) revert TooMuchRequested(kingIn, held);
            poolManager.sync(key.currency1);
            token.safeTransfer(address(poolManager), kingIn);
            uint256 paid = poolManager.settle();
            if (paid != kingIn) revert TooMuchRequested(kingIn, paid);
            uint256 ethOut = uint256(uint128(delta.amount0()));
            if (ethOut > 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, order.user, ethOut);
        }
        return abi.encode(delta);
    }

    function _swap(Order memory order) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(order)), (BalanceDelta));
    }
}
