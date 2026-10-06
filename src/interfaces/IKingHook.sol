// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IKingHook
/// @notice Events, errors, data shapes and the read interface of the King of the Hill hook.
/// @dev Everything a website needs is here. All amounts are wei of ETH unless stated otherwise; all
/// times are block timestamps (seconds).
interface IKingHook {
    /// @notice Why a reign ended.
    enum EndReason {
        None, // reign still running
        Dethroned, // somebody paid the throne price
        Sold, // the king sold through the official router
        Balance // the king's balance dropped below the requirement (claim, dethrone or a swap noticed)
    }

    /// @notice One reign, past or current.
    struct Reign {
        address king;
        uint64 start; // timestamp of the takeover
        uint64 end; // 0 while the reign is running
        uint256 paid; // ETH the king paid in the takeover buy, fee included
        uint256 required; // KING to keep; a self-retake also preserves the previous requirement
        uint256 earned; // ETH the king kept from the throne pool during this reign
        uint256 forfeited; // provisional income returned, plus unverified income retained by the pool
        EndReason reason;
    }

    /// @notice Everything about the throne, in one call.
    struct ThroneView {
        address king;
        uint64 reignStart;
        uint256 requiredBalance;
        uint256 kingBalance; // KING currently held by the king (0 when the throne is empty)
        uint256 thronePrice; // ETH a single buy must reach, fee included
        uint256 nextHalving; // timestamp of the next halving of the price, 0 when at the floor or empty
        uint256 poolSize; // ETH in the throne pool right now
        uint256 incomePerHour; // ETH the pool pays the king over the next hour at the current size
        uint256 kingUnclaimed; // ETH the current king can claim right now
        uint256 kingVesting; // ETH earned this reign that becomes claimable at `vestsAt`
        uint256 vestsAt; // timestamp at which the reign's income vests (reignStart + INCOME_VESTING)
        uint256 kingReignEarnings; // ETH earned since the takeover, claimed or not
        uint256 feeRate; // current swap fee in parts per million
        uint64 launchTime;
        uint64 gameStart;
        bool gameOpen;
    }

    event PoolLaunched(uint64 launchTime, uint64 gameStart);
    event FeeCollected(
        address indexed sender, bool isBuy, uint256 ethGross, uint256 fee, uint256 toPool, uint256 toTeam
    );
    event ThroneTaken(
        address indexed king, uint256 indexed reignIndex, uint256 paid, uint256 required, uint256 priceBeaten
    );
    event ThroneVacated(address indexed king, uint256 indexed reignIndex, EndReason reason, uint256 earned);
    event IncomeAccrued(address indexed king, uint256 amount, uint256 poolAfter);
    event IncomeVested(address indexed king, uint256 indexed reignIndex, uint256 amount);
    event IncomeForfeited(address indexed king, uint256 indexed reignIndex, uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    error NotPoolManager();
    error AlreadyInitialized();
    error WrongPool();
    error WrongCurrencies();
    error UnsupportedLpFee(uint24 fee);
    error HookNotImplemented();
    error PartialFill();
    error ThroneNotTaken(uint256 paid, uint256 price, bool gameOpen);
    error NothingToClaim();
    error ThroneEmpty();
    error KingHoldsEnough(uint256 balance, uint256 required);
    error PayoutInProgress();
    error UnexpectedCallback();
    error PayoutMismatch();
    error NotRouter();

    function prepareSell(address seller) external;
    function poolKey() external view returns (PoolKey memory);
    function feeRate() external view returns (uint256);
    function gameOpen() external view returns (bool);
    function currentThronePrice() external view returns (uint256);
    function nextHalvingTime() external view returns (uint256);
    function poolSize() external view returns (uint256);
    function incomePerHour() external view returns (uint256);
    function unclaimedIncome(address account) external view returns (uint256);
    function kingReignEarnings() external view returns (uint256);
    function kingVestingIncome() external view returns (uint256);
    function reignCount() external view returns (uint256);
    function getReign(uint256 index) external view returns (Reign memory);
    function getReigns(uint256 offset, uint256 limit) external view returns (Reign[] memory);
    function throne() external view returns (ThroneView memory);
}
