// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Halving
/// @notice Exact-at-boundary exponential decay: `value * 2^(-num/den)`.
/// @dev Used for the throne price (half-life 1 hour) and for the throne pool's continuous 2%-per-hour
/// payout (expressed as a base-2 exponent so one routine serves both). Whole halvings are applied with
/// a right shift, so the result is exact at every multiple of the half-life. The fractional part is
/// applied with 64 binary digits: `2^(-f)` for `f` in `[0, 1)` is the product of the constants
/// `2^(-1/2^k)` for every set bit `k` of `f`, each stored as a Q64 fixed-point number (`x * 2^64`).
/// Every multiplication is followed by a shift, so the only division is the one producing the
/// fractional exponent. Constants and shifts round values down; exponent truncation can round the
/// result up. A conservative absolute error bound is `128 * value / 2^64 + 65` smallest units per
/// call, not a fixed wei bound. Rounding the remaining pool down increases the king's income.
library Halving {
    /// @dev `den` must be non-zero and below 2^192 (every caller passes a constant); `value` must be
    /// below 2^192 so that `value * constant` cannot overflow. ETH amounts are far below that bound.
    error HalvingOverflow();

    /// @notice Approximates `value * 2^(-num/den)` using Q64 constants and truncated shifts.
    /// @param value The amount to decay.
    /// @param num Exponent numerator (elapsed time scaled by the decay rate).
    /// @param den Exponent denominator (the half-life in the same units).
    function decay(uint256 value, uint256 num, uint256 den) internal pure returns (uint256) {
        if (value >= 1 << 192 || den >= 1 << 192 || den < 1) revert HalvingOverflow();
        if (value < 1 || num < 1) return value;
        uint256 whole = num / den;
        if (whole >= 256) return 0;
        uint256 rem = num % den;
        uint256 frac = (rem << 64) / den;
        uint256 result = value >> whole;
        if (frac < 1) return result;
        if (frac & (1 << 63) != 0) result = (result * 0xb504f333f9de6484) >> 64;
        if (frac & (1 << 62) != 0) result = (result * 0xd744fccad69d6af4) >> 64;
        if (frac & (1 << 61) != 0) result = (result * 0xeac0c6e7dd24392e) >> 64;
        if (frac & (1 << 60) != 0) result = (result * 0xf5257d152486cc2c) >> 64;
        if (frac & (1 << 59) != 0) result = (result * 0xfa83b2db722a033a) >> 64;
        if (frac & (1 << 58) != 0) result = (result * 0xfd3e0c0cf486c174) >> 64;
        if (frac & (1 << 57) != 0) result = (result * 0xfe9e115c7b8f884b) >> 64;
        if (frac & (1 << 56) != 0) result = (result * 0xff4ecb59511ec8a5) >> 64;
        if (frac & (1 << 55) != 0) result = (result * 0xffa756521c8daed1) >> 64;
        if (frac & (1 << 54) != 0) result = (result * 0xffd3a751c0f7e10b) >> 64;
        if (frac & (1 << 53) != 0) result = (result * 0xffe9d2b2f7db2755) >> 64;
        if (frac & (1 << 52) != 0) result = (result * 0xfff4e91bff1b8c3d) >> 64;
        if (frac & (1 << 51) != 0) result = (result * 0xfffa747ea0040664) >> 64;
        if (frac & (1 << 50) != 0) result = (result * 0xfffd3a3b7814eb53) >> 64;
        if (frac & (1 << 49) != 0) result = (result * 0xfffe9d1cc60ddab1) >> 64;
        if (frac & (1 << 48) != 0) result = (result * 0xffff4e8e25879bfa) >> 64;
        if (frac & (1 << 47) != 0) result = (result * 0xffffa7470363f451) >> 64;
        if (frac & (1 << 46) != 0) result = (result * 0xffffd3a37dda0313) >> 64;
        if (frac & (1 << 45) != 0) result = (result * 0xffffe9d1bdf703ae) >> 64;
        if (frac & (1 << 44) != 0) result = (result * 0xfffff4e8debe025e) >> 64;
        if (frac & (1 << 43) != 0) result = (result * 0xfffffa746f4fa150) >> 64;
        if (frac & (1 << 42) != 0) result = (result * 0xfffffd3a37a3f8b0) >> 64;
        if (frac & (1 << 41) != 0) result = (result * 0xfffffe9d1bd1065a) >> 64;
        if (frac & (1 << 40) != 0) result = (result * 0xffffff4e8de845ad) >> 64;
        if (frac & (1 << 39) != 0) result = (result * 0xffffffa746f41376) >> 64;
        if (frac & (1 << 38) != 0) result = (result * 0xffffffd3a37a05e3) >> 64;
        if (frac & (1 << 37) != 0) result = (result * 0xffffffe9d1bd01fb) >> 64;
        if (frac & (1 << 36) != 0) result = (result * 0xfffffff4e8de80c0) >> 64;
        if (frac & (1 << 35) != 0) result = (result * 0xfffffffa746f4050) >> 64;
        if (frac & (1 << 34) != 0) result = (result * 0xfffffffd3a37a024) >> 64;
        if (frac & (1 << 33) != 0) result = (result * 0xfffffffe9d1bd011) >> 64;
        if (frac & (1 << 32) != 0) result = (result * 0xffffffff4e8de808) >> 64;
        if (frac & (1 << 31) != 0) result = (result * 0xffffffffa746f404) >> 64;
        if (frac & (1 << 30) != 0) result = (result * 0xffffffffd3a37a02) >> 64;
        if (frac & (1 << 29) != 0) result = (result * 0xffffffffe9d1bd01) >> 64;
        if (frac & (1 << 28) != 0) result = (result * 0xfffffffff4e8de80) >> 64;
        if (frac & (1 << 27) != 0) result = (result * 0xfffffffffa746f40) >> 64;
        if (frac & (1 << 26) != 0) result = (result * 0xfffffffffd3a37a0) >> 64;
        if (frac & (1 << 25) != 0) result = (result * 0xfffffffffe9d1bd0) >> 64;
        if (frac & (1 << 24) != 0) result = (result * 0xffffffffff4e8de8) >> 64;
        if (frac & (1 << 23) != 0) result = (result * 0xffffffffffa746f4) >> 64;
        if (frac & (1 << 22) != 0) result = (result * 0xffffffffffd3a37a) >> 64;
        if (frac & (1 << 21) != 0) result = (result * 0xffffffffffe9d1bd) >> 64;
        if (frac & (1 << 20) != 0) result = (result * 0xfffffffffff4e8de) >> 64;
        if (frac & (1 << 19) != 0) result = (result * 0xfffffffffffa746f) >> 64;
        if (frac & (1 << 18) != 0) result = (result * 0xfffffffffffd3a37) >> 64;
        if (frac & (1 << 17) != 0) result = (result * 0xfffffffffffe9d1b) >> 64;
        if (frac & (1 << 16) != 0) result = (result * 0xffffffffffff4e8d) >> 64;
        if (frac & (1 << 15) != 0) result = (result * 0xffffffffffffa746) >> 64;
        if (frac & (1 << 14) != 0) result = (result * 0xffffffffffffd3a3) >> 64;
        if (frac & (1 << 13) != 0) result = (result * 0xffffffffffffe9d1) >> 64;
        if (frac & (1 << 12) != 0) result = (result * 0xfffffffffffff4e8) >> 64;
        if (frac & (1 << 11) != 0) result = (result * 0xfffffffffffffa74) >> 64;
        if (frac & (1 << 10) != 0) result = (result * 0xfffffffffffffd3a) >> 64;
        if (frac & (1 << 9) != 0) result = (result * 0xfffffffffffffe9d) >> 64;
        if (frac & (1 << 8) != 0) result = (result * 0xffffffffffffff4e) >> 64;
        if (frac & (1 << 7) != 0) result = (result * 0xffffffffffffffa7) >> 64;
        if (frac & (1 << 6) != 0) result = (result * 0xffffffffffffffd3) >> 64;
        if (frac & (1 << 5) != 0) result = (result * 0xffffffffffffffe9) >> 64;
        if (frac & (1 << 4) != 0) result = (result * 0xfffffffffffffff4) >> 64;
        if (frac & (1 << 3) != 0) result = (result * 0xfffffffffffffffa) >> 64;
        if (frac & (1 << 2) != 0) result = (result * 0xfffffffffffffffd) >> 64;
        if (frac & (1 << 1) != 0) result = (result * 0xfffffffffffffffe) >> 64;
        if (frac & (1 << 0) != 0) result = (result * 0xffffffffffffffff) >> 64;
        return result;
    }
}
