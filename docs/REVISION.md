# Revision verification and independent review

This revision addresses the eight findings in `.imd-responses.json`. It preserves the accepted
fee math, pool configuration, permission flags, deployment interface, token and vendored libraries.
Only the router, game accounting, related interface/comments, regression tests and documentation
changed. No network transaction was sent and no dependency was installed.

## Reproduction and disposition

All three supplied proofs reproduced on the starting tree (five failing tests):

| Finding | Starting result | Revised result |
|---|---|---|
| `012d0ed81c4a…` partial sell / sweep | 12,130,392.259397390618555071 KING stranded; later caller swept it | Seller receives the exact unused input; router retains zero order residue; subsequent seller receives only their own refund |
| `b624f33c1fa3…` early vesting bypass | Both self-retake and two-wallet relay vested 516,291,093,330,768 wei prematurely | Both unmodified proof tests pass; early end always forfeits |
| `13824b5abec2…` claim by non-holder | Non-holder claimed 262,614,226,791,682,425 wei after six hours | Unmodified proof passes; no quiet-period income paid |

The partial-fill **defect is fixed, but its proof is disputed**. The proof is internally
incompatible with its proposed refund fix:

* The first test asserts the seller's balance is zero after the swap. A refund must make it
  nonzero. It now fails there with the correct refund of 12,130,392.259397390618555071 KING.
* The second test requires `stuck > 0` as a precondition. A successful fix leaves `stuck == 0`.
  It now fails on that precondition before attempting the alleged sweep.
* Reverting partial fills would also fail the proof's unguarded swap calls.

Neither supplied proof nor its scratch copy was edited. Copies were run under `test/scratch/`
and then removed from test discovery; the original pinned inputs remain unchanged. The two
contradictory tests are not included as passing project tests. Delivered regressions in
`test/KingHook.Revision.t.sol` instead assert actual partial execution, seller/manager token
conservation, zero router residue, actual input in `Swapped`, and no sweep by a later seller.
They also test donated-token isolation and the exact-output maximum input cap.

The advisory findings were reproduced before implementation: both incorrect sell labels,
self-retake requirement shrinkage, silently ignored foreign must-take, a rejecting exact-output
refund wallet, and the 154,905-unit split-decay discrepancy. The first three received targeted
code fixes; the last two received documentation corrections and regression coverage.

## Accounting decisions

Every short reign forfeits its provisional income, even when a rival or the same wallet buys
the throne. Five minutes is a minimum exposure period, not protection from every profitable bot
strategy. Genuine early-outbid kings forfeit too; the boundary at exactly five minutes still vests
when holdings remain sufficient.

A balance failure is processed before accrual. Previously booked vested credits are preserved;
provisional credits return to the pool. The unbooked interval since `lastAccrual` never leaves the
pool, but is recorded in `Reign.forfeited` and the forfeiture event. Thus history records the
potential income denied, without minting, burning or double-counting money. The exact invariant
remains `manager claims == pool + provisionalIncome + sum(pendingIncome)`.

For official sells, `prepareSell` verifies holdings before temporary router escrow, accrues valid
income and ends a valid king's reign as `Sold`. Only the immutable router can call it; the payout
guard rejects it during a claim. Failed approvals, swaps and slippage checks revert the entire
checkpoint. A formerly deficient king cannot use a dust sell to vest a quiet interval. Both token
pulls still use `safeTransferFrom(msg.sender, address(this), ...)` before PoolManager unlock; no
callback can select an allowance owner.

A claim that discovers a deficient king and owes its caller nothing returns without payment so
the dethrone persists. Other zero-credit claims retain `NothingToClaim`. Views suppress forfeitable
income; `poolSize` projects the return of provisional credits for a currently deficient king.

## Independent review

A separate review agent examined every project contract and the revised economics independently
of the implementing agent. It checked the partial-fill proof, refund ownership, exact-output caps,
checkpoint authentication and rollback, reentrancy, forfeiture accounting, self-retakes and views.
It independently ran all 21 revision tests, including 256 early-takeover fuzz cases, successfully.
The final documentation was separately checked against the code. No blocking issue was identified
in this bounded revision. This is an independent agent review within the assignment, not a claim
of a professional external audit or approval to deploy.

The review prompted explicit disclosure of remaining limits: a plain ERC-20 cannot reveal exits
followed by restoration between observations, nor attribute a surplus sell through an arbitrary
router. A five-minute reign can still be profitable, and sequencer censorship or ordering can
protect it. These limitations are recorded in README; the revision does not replace the accepted
plain-token and trusted-router design.

## Validation

The manifest was parsed and checked against the exact field shape and values supplied in the
assignment, including constructor placeholders, all permission names, native-ETH currency,
fee/tick spacing, token metadata and `10000 * 2^96` initial price. Only its explanatory notes changed.
No separate factory JSON-schema file was supplied, so a run against an external factory schema
is not claimed.

Slither is unavailable in this workspace; historical results in REVIEW are identified as such.
The rejected arbitrary-from token pull was not reintroduced. Solidity remains pinned to 0.8.26,
Cancun, with metadata hash disabled. No compiler/configuration or dependency changes were needed.

Final results (2026-10-06): `forge build` and `forge fmt --check` exit successfully; `forge test`
passes **115 tests across 9 suites, with zero failures or skips**, including both live Base fork
tests, 256-case fuzz tests and 24 × 48 invariant calls. The two supplied income proofs separately
pass all three tests; the incompatible partial-fill proof remains disputed as described above.

During validation, Foundry 1.8.3's `missing-events-arithmetic` lint spent over four minutes and
roughly 16 GB on a reason-dependent forfeiture expression. Passing the already-computed forfeiture
into `_endReign` from its balance-failure callers removed the slowdown; valid sell/takeover callers
pass zero. The independent reviewer checked all five call sites and confirmed semantic equivalence.
The normal build now completes promptly. No lint was suppressed or disabled, and `foundry.toml`
is unchanged. Build warnings are not claimed to be a clean static-analysis report.
