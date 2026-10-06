// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IKingHook} from "./interfaces/IKingHook.sol";
import {KingRouter} from "./KingRouter.sol";
import {Halving} from "./libraries/Halving.sol";
import {HookFlags} from "./HookFlags.sol";

/// @title KingHook
/// @notice Uniswap v4 hook for the KING/ETH pool: an ETH trading fee that funds a "King of the Hill"
/// throne game. There is no owner, nothing is upgradeable or pausable, and no parameter can change.
///
/// Fee: every buy and sell pays a fee in ETH, computed on the settled ETH delta of the swap. It starts
/// at 25% when the pool is initialized and decays linearly to 2.5% over 30 minutes. 92% of every fee
/// goes to the throne pool and 8% is credited to the team wallet, which claims it like any king.
///
/// Throne: once the anti-snipe period ends, a single buy through the official `KingRouter` whose ETH
/// amount (fee included) is at least the current throne price makes the buyer the king. The price
/// then becomes 1.2x what the king paid and halves every hour down to a floor of 0.01 ETH. While a
/// king sits, the throne pool pays him 2% of itself per hour, credited every second; the income of
/// the first five minutes vests only if the reign lasts that long or ends by somebody else's
/// takeover. The king must keep the KING tokens his takeover bought: a sell through the router, or
/// any swap or `dethrone()` call that finds his balance below that amount, empties the throne.
///
/// Fees are held as ERC-6909 claims on the PoolManager, so a swap never needs the PoolManager to hold
/// ETH up front; payouts burn claims and take ETH inside a PoolManager unlock the hook initiates.
contract KingHook is IKingHook, IHooks, IUnlockCallback, ReentrancyGuardTransient {
    using SafeCast for uint256;
    using SafeCast for int128;
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------------------------------
    // Fixed parameters
    // ------------------------------------------------------------------------------------------

    /// @notice The wallet that receives 8% of every fee (pull-based through `claim()`).
    address public constant TEAM_WALLET = 0x39E3414e7a43DE41675e9bEC52F7C9F6ae489CB6;
    /// @notice Permission bits this hook's address must carry.
    uint160 public constant FLAGS = HookFlags.KING_HOOK_FLAGS;

    uint256 public constant PPM = 1_000_000;
    /// @notice Fee at launch, parts per million (25%).
    uint256 public constant FEE_START_PPM = 250_000;
    /// @notice Fee after the anti-snipe period, parts per million (2.5%).
    uint256 public constant FEE_BASE_PPM = 25_000;
    /// @notice Length of the linear fee decay; the throne game opens when it ends.
    uint256 public constant ANTI_SNIPE_DURATION = 30 minutes;
    /// @notice Share of every fee credited to the team wallet, in basis points (8%).
    uint256 public constant TEAM_SHARE_BPS = 800;
    uint256 public constant BPS = 10_000;
    /// @notice Lowest throne price, and the price while the throne is empty.
    uint256 public constant THRONE_FLOOR = 0.01 ether;
    /// @notice Throne price right after a takeover, relative to what the king paid (1.2x).
    uint256 public constant THRONE_PREMIUM_BPS = 12_000;
    /// @notice Half-life of the throne price.
    uint256 public constant THRONE_HALF_LIFE = 1 hours;
    /// @notice Share of the throne pool paid to the king per hour, in basis points (2%).
    uint256 public constant INCOME_BPS_PER_HOUR = 200;
    /// @notice Income earned in the first minutes of a reign is only kept if the reign lasts this
    /// long or ends through somebody else's takeover. A king who sells or lets his balance drop
    /// before that forfeits it to the pool: the defence against take-and-dump bots.
    uint256 public constant INCOME_VESTING = 5 minutes;
    /// @dev `log2(1 / 0.98) * 1e12`: the pool keeps 98% of itself per hour, i.e. decays by
    /// `2^(-elapsed * INCOME_LOG2_PER_HOUR / INCOME_DEN)`.
    uint256 public constant INCOME_LOG2_PER_HOUR = 29_146_345_660;
    uint256 public constant INCOME_DEN = 3600 * 1e12;
    /// @dev ERC-6909 id of native ETH on the PoolManager.
    uint256 internal constant ETH_ID = 0;

    // ------------------------------------------------------------------------------------------
    // Immutables
    // ------------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    IERC20 public immutable token;
    /// @notice The only router whose hookData the hook trusts to name the real buyer or seller.
    KingRouter public immutable router;

    // ------------------------------------------------------------------------------------------
    // Pool state
    // ------------------------------------------------------------------------------------------

    bool public initialized;
    uint64 public launchTime;
    PoolId internal _poolId;
    PoolKey internal _poolKey;

    // ------------------------------------------------------------------------------------------
    // Game state
    // ------------------------------------------------------------------------------------------

    address public king;
    uint64 public reignStart;
    uint64 public lastAccrual;
    uint256 public requiredBalance;
    uint256 public takeoverPaid;
    /// @dev 1.2x `takeoverPaid`, the throne price at `reignStart` before decay.
    uint256 public priceBase;
    /// @notice ETH in the throne pool, held as ERC-6909 claims on the PoolManager.
    uint256 public pool;
    /// @notice ETH credited and not yet claimed, per wallet (kings and the team wallet).
    mapping(address => uint256) public pendingIncome;
    /// @notice Income of the current reign that has not vested yet (zero once the reign is
    /// `INCOME_VESTING` old).
    uint256 public provisionalIncome;
    Reign[] internal _reigns;

    constructor(IPoolManager poolManager_, address token_) {
        require(address(poolManager_).code.length > 0, "KingHook: pool manager has no code");
        require(token_.code.length > 0, "KingHook: token has no code");
        poolManager = poolManager_;
        token = IERC20(token_);
        router = new KingRouter(poolManager_, token_, address(this));
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Hook permissions
    // ------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements; its address is mined to carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Accepts exactly one pool: native ETH against the KING token at a static LP fee tier.
    /// The launch factory initializes the pool in the transaction that deploys the hook, so nobody
    /// can claim the pool first. Initialization starts the anti-snipe clock.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(token)) {
            revert WrongCurrencies();
        }
        if (key.fee != 500 && key.fee != 3000 && key.fee != 10_000) revert UnsupportedLpFee(key.fee);

        initialized = true;
        launchTime = uint64(block.timestamp);
        lastAccrual = uint64(block.timestamp);
        _poolKey = key;
        _poolId = key.toId();
        emit PoolLaunched(launchTime, uint64(block.timestamp + ANTI_SNIPE_DURATION));
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Settles the king's income and the holding rule, then charges the fee on swaps whose
    /// specified amount is ETH (exact-input buys and exact-output sells): the fee is returned as a
    /// hook delta on the specified currency, so the pool swaps the remainder and the hook is owed the
    /// fee. The other two cases are charged in `afterSwap` where the ETH amount is known.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_reentrancyGuardEntered()) revert PayoutInProgress();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolId)) revert WrongPool();

        _accrue();
        _enforceHolding();

        bool ethSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (!ethSpecified) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _specifiedFee(params);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Charges the fee on swaps whose unspecified amount is ETH (exact-output buys and
    /// exact-input sells) from the settled delta, books every fee, and runs the throne game.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (_reentrancyGuardEntered()) revert PayoutInProgress();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolId)) revert WrongPool();

        (uint256 fee, int128 hookDeltaUnspecified) =
            params.zeroForOne ? _afterBuy(sender, params, delta, hookData) : _afterSell(sender, params, delta, hookData);

        // Interaction last: convert the fee the hook is owed into an ERC-6909 claim. The claim is
        // backed by the swapper's settlement, so the PoolManager never needs ETH up front.
        if (fee > 0) poolManager.mint(address(this), ETH_ID, fee);
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @dev Buy: the swapper paid ETH (amount0 < 0) and receives KING (amount1 > 0).
    function _afterBuy(address sender, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        returns (uint256 fee, int128 hookDeltaUnspecified)
    {
        uint256 poolEth = _abs(delta.amount0());
        uint256 ethGross = 0;
        if (params.amountSpecified < 0) {
            // Exact-input buy: the fee was taken in beforeSwap from the specified ETH.
            ethGross = _abs(params.amountSpecified);
            fee = _specifiedFee(params);
            if (poolEth + fee < ethGross) revert PartialFill();
        } else {
            // Exact-output buy: the pool consumed `poolEth`; charge the fee on top, in ETH.
            uint256 rate = feeRate();
            fee = (poolEth * rate) / (PPM - rate);
            ethGross = poolEth + fee;
            hookDeltaUnspecified = fee.toInt128();
        }
        _book(sender, true, ethGross, fee);
        _onBuy(sender, hookData, ethGross, _abs(delta.amount1()));
    }

    /// @dev Sell: the swapper paid KING (amount1 < 0) and receives ETH (amount0 > 0).
    function _afterSell(address sender, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        returns (uint256 fee, int128 hookDeltaUnspecified)
    {
        uint256 poolEth = _abs(delta.amount0());
        uint256 ethGross = 0;
        if (params.amountSpecified > 0) {
            // Exact-output sell: the fee was added in beforeSwap to the specified ETH output.
            fee = _specifiedFee(params);
            ethGross = _abs(params.amountSpecified) + fee;
            if (poolEth < ethGross) revert PartialFill();
        } else {
            // Exact-input sell: charge the fee from the settled ETH output.
            fee = (poolEth * feeRate()) / PPM;
            ethGross = poolEth;
            hookDeltaUnspecified = fee.toInt128();
        }
        _book(sender, false, ethGross, fee);
        _onSell(sender, hookData);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------------------------------
    // Public game actions
    // ------------------------------------------------------------------------------------------

    /// @notice Pays the caller everything credited to them: king income (current or past) or the
    /// team wallet's share. Credits are zeroed before any value moves.
    function claim() external nonReentrant {
        _accrue();
        uint256 amount = pendingIncome[msg.sender];
        if (amount < 1) revert NothingToClaim();
        pendingIncome[msg.sender] = 0;
        emit Claimed(msg.sender, amount);
        _payout(msg.sender, amount);
    }

    /// @notice Empties the throne when the king no longer holds the KING his takeover bought, for
    /// example after a transfer to another wallet. Anyone may call it. The king's income stops at
    /// this moment; what he earned until now stays claimable.
    function dethrone() external nonReentrant {
        _accrue();
        if (king == address(0)) revert ThroneEmpty();
        uint256 balance = token.balanceOf(king);
        if (balance >= requiredBalance) revert KingHoldsEnough(balance, requiredBalance);
        _endReign(EndReason.Balance);
    }

    /// @notice PoolManager callback for payouts: burns the hook's ETH claims and sends the ETH.
    /// @dev Reachable only inside `claim()`: the PoolManager calls back whoever called `unlock`, and
    /// the hook calls `unlock` only from `_payout`, under the reentrancy guard.
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        if (!_reentrancyGuardEntered()) revert UnexpectedCallback();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), ETH_ID, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, to, amount);
        return abi.encode(amount);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IKingHook
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Timestamp at which the anti-snipe period ends and the throne opens.
    function gameStart() public view returns (uint64) {
        return launchTime + uint64(ANTI_SNIPE_DURATION);
    }

    /// @inheritdoc IKingHook
    function gameOpen() public view returns (bool) {
        return initialized && block.timestamp >= gameStart();
    }

    /// @inheritdoc IKingHook
    /// @dev Parts per million of the gross ETH side of a swap. 25% at initialization, falling
    /// linearly to 2.5% at `gameStart()` and constant afterwards.
    function feeRate() public view returns (uint256) {
        if (!initialized) return FEE_START_PPM;
        uint256 elapsed = block.timestamp - launchTime;
        if (elapsed >= ANTI_SNIPE_DURATION) return FEE_BASE_PPM;
        return FEE_BASE_PPM + ((FEE_START_PPM - FEE_BASE_PPM) * (ANTI_SNIPE_DURATION - elapsed)) / ANTI_SNIPE_DURATION;
    }

    /// @inheritdoc IKingHook
    /// @dev The floor while the throne is empty; otherwise 1.2x the king's payment halved once per
    /// hour since the takeover, never below the floor.
    function currentThronePrice() public view returns (uint256) {
        if (king == address(0)) return THRONE_FLOOR;
        uint256 price = Halving.decay(priceBase, block.timestamp - reignStart, THRONE_HALF_LIFE);
        return price < THRONE_FLOOR ? THRONE_FLOOR : price;
    }

    /// @inheritdoc IKingHook
    /// @dev Timestamp of the next halving of the throne price, or 0 when the price sits at the floor
    /// or the throne is empty.
    function nextHalvingTime() public view returns (uint256 next) {
        if (king == address(0) || currentThronePrice() <= THRONE_FLOOR) return 0;
        // Bounded: the price reaches the floor after at most ~90 halvings of any realistic base.
        next = reignStart + THRONE_HALF_LIFE;
        while (next <= block.timestamp) {
            next += THRONE_HALF_LIFE;
        }
    }

    /// @inheritdoc IKingHook
    /// @dev The pool after the income accrued up to now, which `_accrue` has not necessarily booked.
    function poolSize() public view returns (uint256) {
        return _remainingPool();
    }

    /// @inheritdoc IKingHook
    function incomePerHour() public view returns (uint256) {
        return (_remainingPool() * INCOME_BPS_PER_HOUR) / BPS;
    }

    /// @inheritdoc IKingHook
    /// @dev What `claim()` would pay `account` right now. For the king this includes the income of
    /// the current reign only once it has vested.
    function unclaimedIncome(address account) public view returns (uint256) {
        uint256 amount = pendingIncome[account];
        if (account != address(0) && account == king && _vested()) amount += _reignUnbooked();
        return amount;
    }

    /// @inheritdoc IKingHook
    /// @dev Gross income of the current reign: claimed, claimable, and still vesting.
    function kingReignEarnings() public view returns (uint256) {
        if (king == address(0)) return 0;
        return _reigns[_reigns.length - 1].earned + (pool - _remainingPool());
    }

    /// @inheritdoc IKingHook
    /// @dev Income of the current reign that is earned but not claimable yet.
    function kingVestingIncome() public view returns (uint256) {
        if (king == address(0) || _vested()) return 0;
        return _reignUnbooked();
    }

    /// @inheritdoc IKingHook
    function reignCount() public view returns (uint256) {
        return _reigns.length;
    }

    /// @inheritdoc IKingHook
    function getReign(uint256 index) public view returns (Reign memory reign) {
        reign = _reigns[index];
        if (reign.end < 1) reign.earned = kingReignEarnings();
    }

    /// @inheritdoc IKingHook
    function getReigns(uint256 offset, uint256 limit) external view returns (Reign[] memory page) {
        uint256 total = _reigns.length;
        if (offset >= total) return page;
        uint256 count = total - offset;
        if (count > limit) count = limit;
        page = new Reign[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = getReign(offset + i);
        }
    }

    /// @inheritdoc IKingHook
    function throne() external view returns (ThroneView memory v) {
        v.king = king;
        v.reignStart = reignStart;
        v.requiredBalance = requiredBalance;
        v.kingBalance = king == address(0) ? 0 : token.balanceOf(king);
        v.thronePrice = currentThronePrice();
        v.nextHalving = nextHalvingTime();
        v.poolSize = poolSize();
        v.incomePerHour = incomePerHour();
        v.kingUnclaimed = unclaimedIncome(king);
        v.kingVesting = kingVestingIncome();
        v.vestsAt = king == address(0) ? 0 : reignStart + INCOME_VESTING;
        v.kingReignEarnings = kingReignEarnings();
        v.feeRate = feeRate();
        v.launchTime = launchTime;
        v.gameStart = gameStart();
        v.gameOpen = gameOpen();
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    /// @dev Fee for the two cases where ETH is the specified amount. Exact-input buy: `rate` of the
    /// ETH paid. Exact-output sell: the fee such that `rate` of the gross ETH the pool pays out
    /// (requested output plus fee) is taken, i.e. `out * rate / (1 - rate)`.
    function _specifiedFee(SwapParams calldata params) internal view returns (uint256) {
        uint256 rate = feeRate();
        uint256 amount = _abs(params.amountSpecified);
        if (params.zeroForOne) return (amount * rate) / PPM;
        return (amount * rate) / (PPM - rate);
    }

    /// @dev Splits a fee 92/8 between the throne pool and the team wallet.
    function _book(address sender, bool isBuy, uint256 ethGross, uint256 fee) internal {
        uint256 toTeam = (fee * TEAM_SHARE_BPS) / BPS;
        uint256 toPool = fee - toTeam;
        pool += toPool;
        pendingIncome[TEAM_WALLET] += toTeam;
        emit FeeCollected(sender, isBuy, ethGross, fee, toPool, toTeam);
    }

    /// @dev The throne game on a buy. Only swaps routed through the hook's own router carry a buyer
    /// identity the hook can trust; every other router's hookData is ignored, so such buys pay the
    /// fee but cannot take the throne.
    function _onBuy(address sender, bytes calldata hookData, uint256 ethGross, uint256 kingOut) internal {
        if (sender != address(router) || hookData.length < 64) return;
        (address buyer, bool mustTake) = abi.decode(hookData, (address, bool));
        if (buyer == address(0)) return;

        bool open = gameOpen();
        uint256 price = currentThronePrice();
        if (!open || ethGross < price) {
            if (mustTake) revert ThroneNotTaken(ethGross, price, open);
            return;
        }
        if (king != address(0)) _endReign(EndReason.Dethroned);
        _startReign(buyer, ethGross, kingOut, price);
    }

    /// @dev The throne game on a sell: a sell by the king through the official router dethrones him
    /// at once, whatever the amount. Sells by anyone else never touch the throne.
    function _onSell(address sender, bytes calldata hookData) internal {
        if (sender != address(router) || hookData.length < 64 || king == address(0)) return;
        (address seller,) = abi.decode(hookData, (address, bool));
        if (seller == king) _endReign(EndReason.Sold);
    }

    /// @dev Holding rule, checked on every swap: a king whose balance dropped below the required
    /// amount (a sell through a third-party router, a transfer) loses the throne.
    function _enforceHolding() internal {
        if (king == address(0)) return;
        if (token.balanceOf(king) < requiredBalance) _endReign(EndReason.Balance);
    }

    function _startReign(address buyer, uint256 paid, uint256 kingOut, uint256 priceBeaten) internal {
        king = buyer;
        reignStart = uint64(block.timestamp);
        lastAccrual = uint64(block.timestamp);
        requiredBalance = kingOut;
        takeoverPaid = paid;
        priceBase = (paid * THRONE_PREMIUM_BPS) / BPS;
        _reigns.push(
            Reign({
                king: buyer,
                start: uint64(block.timestamp),
                end: 0,
                paid: paid,
                required: kingOut,
                earned: 0,
                forfeited: 0,
                reason: EndReason.None
            })
        );
        emit ThroneTaken(buyer, _reigns.length - 1, paid, kingOut, priceBeaten);
    }

    /// @dev Must run after `_accrue()` so the ending reign is credited up to now. Income still
    /// vesting is kept when somebody else took the throne and forfeited to the pool otherwise.
    function _endReign(EndReason reason) internal {
        uint256 index = _reigns.length - 1;
        Reign storage reign = _reigns[index];
        uint256 vesting = provisionalIncome;
        if (vesting > 0) {
            provisionalIncome = 0;
            if (reason == EndReason.Dethroned) {
                pendingIncome[king] += vesting;
                emit IncomeVested(king, index, vesting);
            } else {
                pool += vesting;
                reign.earned -= vesting;
                reign.forfeited = vesting;
                emit IncomeForfeited(king, index, vesting);
            }
        }
        reign.end = uint64(block.timestamp);
        reign.reason = reason;
        emit ThroneVacated(king, index, reason, reign.earned);
        king = address(0);
        reignStart = 0;
        requiredBalance = 0;
        takeoverPaid = 0;
        priceBase = 0;
    }

    /// @dev Pool left after the king's income since `lastAccrual`: 98% per hour, compounded by the
    /// second. Path-independent, so how often it is booked changes nothing.
    function _remainingPool() internal view returns (uint256) {
        if (king == address(0) || block.timestamp <= lastAccrual) return pool;
        uint256 elapsed = block.timestamp - lastAccrual;
        return Halving.decay(pool, elapsed * INCOME_LOG2_PER_HOUR, INCOME_DEN);
    }

    /// @dev Books the income accrued since the last accrual to the king.
    function _accrue() internal {
        if (king == address(0) || block.timestamp <= lastAccrual) {
            lastAccrual = uint64(block.timestamp);
            return;
        }
        uint256 remaining = _remainingPool();
        uint256 earned = pool - remaining;
        pool = remaining;
        lastAccrual = uint64(block.timestamp);
        uint256 index = _reigns.length - 1;
        if (earned > 0) {
            provisionalIncome += earned;
            _reigns[index].earned += earned;
            emit IncomeAccrued(king, earned, remaining);
        }
        uint256 vesting = provisionalIncome;
        if (vesting > 0 && _vested()) {
            provisionalIncome = 0;
            pendingIncome[king] += vesting;
            emit IncomeVested(king, index, vesting);
        }
    }

    /// @dev True once the current reign is old enough for its income to be kept.
    function _vested() internal view returns (bool) {
        return block.timestamp - reignStart >= INCOME_VESTING;
    }

    /// @dev Income of the current reign not yet in `pendingIncome`: vesting plus not yet booked.
    function _reignUnbooked() internal view returns (uint256) {
        return provisionalIncome + (pool - _remainingPool());
    }

    /// @dev Sends ETH held as PoolManager claims. Runs under the reentrancy guard of `claim()`.
    function _payout(address to, uint256 amount) internal {
        bytes memory result = poolManager.unlock(abi.encode(to, amount));
        if (abi.decode(result, (uint256)) != amount) revert PayoutMismatch();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
