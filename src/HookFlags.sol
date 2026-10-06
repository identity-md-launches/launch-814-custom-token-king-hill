// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookFlags
/// @notice The permission bits Uniswap v4 encodes in a hook's address, and helpers to read them.
/// @dev Mirrors `Hooks.sol` from v4-core. A hook can only be called for the callbacks whose bit is
/// set in its own address, so the deployer mines a CREATE2 salt until the address carries exactly
/// the flags `getHookPermissions()` declares. `KingHook.FLAGS` is the value this project is mined for.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask of every permission bit.
    uint160 internal constant ALL = (1 << 14) - 1;

    /// @notice The bits `KingHook` declares: beforeInitialize, beforeSwap, afterSwap and both swap
    /// return-delta permissions (0x20CC).
    uint160 internal constant KING_HOOK_FLAGS =
        BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURN_DELTA | AFTER_SWAP_RETURN_DELTA;

    /// @notice The permission bits carried by `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook`'s address carries exactly `flags` (ignoring bits outside the mask).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }

    /// @notice Mines a CREATE2 salt such that `deployer` deploying `creationCode` lands on an address
    /// carrying exactly `flags`. Reverts if none is found within `maxIterations` attempts.
    /// @dev Hashes in a fixed buffer so a long search does not grow memory.
    function mine(address deployer, uint160 flags, bytes memory creationCode, uint256 maxIterations)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        // 0xff ++ deployer (20) ++ salt (32) ++ initCodeHash (32) = 85 bytes; the salt sits at offset 21.
        bytes memory buffer = abi.encodePacked(bytes1(0xff), deployer, bytes32(0), initCodeHash);
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            bytes32 digest;
            assembly ("memory-safe") {
                mstore(add(buffer, 0x35), salt)
                digest := keccak256(add(buffer, 0x20), 85)
            }
            hook = address(uint160(uint256(digest)));
            if (matches(hook, flags)) return (hook, salt);
        }
        revert("HookFlags: no salt found");
    }
}
