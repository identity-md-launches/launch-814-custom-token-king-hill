# Vendored dependencies

Committed as ordinary files (no git submodules) so the project builds with no network.

| Library | Source | Commit |
|---|---|---|
| forge-std | https://github.com/foundry-rs/forge-std | 0258fe875e1d8e207c1eb7175e542ea32356773c |
| v4-core | https://github.com/Uniswap/v4-core | 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 |
| solmate | https://github.com/transmissions11/solmate | 4b47a19038b798b4a33d9749d25e570443520647 (v4-core's pin) |
| openzeppelin-contracts | https://github.com/OpenZeppelin/openzeppelin-contracts | c64a1edb67b6e3f4a15cca8909c9482ad33a02b0 (v5.4.0) |

Only the `src`/`contracts` trees and licences are kept. Nothing was modified.
