// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title KingToken ($KING)
/// @notice The launch token of the King of the Hill game: a plain, fixed-supply ERC-20.
/// @dev Exactly 1,000,000,000 tokens (10^27 minor units, 18 decimals) are minted to the deployer in
/// the constructor, which the launch factory requires. There is no owner, no mint, no burn, no pause,
/// no blocklist, no transfer fee and no upgrade path: every rule of the game, including the trading
/// fee, lives in the Uniswap v4 hook (`KingHook`), never in the token.
contract KingToken is ERC20 {
    /// @notice The whole supply, minted once.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("KING", "KING") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
