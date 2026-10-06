# Adversarial review: KING launch (token, hook, router, math)

**Scope.** `src/KingToken.sol`, `src/KingHook.sol`, `src/KingRouter.sol`, `src/HookFlags.sol`,
`src/libraries/Halving.sol`, `src/interfaces/IKingHook.sol`, `launch.json`, and the economics of
the throne game as specified in the brief.

**Original review method.** A second pass written against the finished code, with the `uniswap-v4-security` and
`eth-security` references as checklists: every callback traced through v4-core's `Hooks` and
`PoolManager` code, every ETH path traced to the settlement that backs it, each brief requirement
mapped to a test, then an attacker's walk through the game. Slither ran on `src/` with the
project's compiler. **This is a structured self-review by the same contributor, not the
independent contributor audit the launch policy requires before funds are at stake**; its open
items are listed at the end for that reviewer. The separate revision review and proof results are
recorded in `docs/REVISION.md`; the resolutions below reflect the corrected implementation.

Severity scale: Critical / High / Medium / Low / Informational. "Resolved" means a code change and
a test exist; "Accepted" means documented and left as is.

---

## 1. Findings

### 1.1 Resolved during the review

| # | Severity | Finding | Resolution |
|---|---|---|---|
| R1 | High | **Take-and-dump skimming.** A bot takes the throne at the floor, holds one block, sells, repeats. The income of one block is `pool · 2% · blockTime / 3600`; the cost is two fees on 0.01 ETH. Profitable above ~45 ETH of pool on Base, ~7.5 ETH on a 12 s chain, and it keeps the throne squatted. | Income of the first 5 minutes of a reign vests only if the reign lasts 5 minutes with adequate holdings; every earlier end, including self-retakes and cooperating takeovers, forfeits it to the pool. `test_takeAndDumpWithinFiveMinutesForfeitsTheIncome`, `test_transferAndDethroneWithinFiveMinutesForfeitsTheIncome`, `test_incomeVestsAfterFiveMinutes`, `test_beingOutbidWithinFiveMinutesForfeitsTheIncome`. |
| R2 | High (static analysis) | Earlier attempt's router pulled tokens with `transferFrom(user, …)` where `user` came from callback data (`arbitrary-send-erc20`). | The router pulls from `msg.sender` **before** unlocking and settles from its own balance; the callback decodes the user only to name the recipient of `take`. The original review recorded Slither no longer reporting it; the revision preserves that design and has not rerun Slither. |
| R3 | Medium | Fee minted as a claim must be matched by the hook delta the PoolManager accounts **after** `afterSwap` returns. If the sign or amount disagreed the unlock would revert `CurrencyNotSettled` for every swap. | Traced through `Hooks.afterSwap`/`PoolManager.swap`: `hookDelta` is `+fee` on ETH, `mint` makes the hook `−fee`, net zero. Exercised by every swap test and on the live Base PoolManager (`test_fork_feesAndThroneOnTheLiveManager`). |
| R4 | Medium | Partial fills: for the two `beforeSwap`-charged cases the fee is computed on the specified amount; a swap stopped at the price limit would be overcharged. | `PartialFill` revert; `test_exactOutputSellBeyondPoolEthReverts`. |
| R5 | Medium | Payout reentrancy: `take` sends ETH to the claimer, who could re-enter `claim`, `dethrone`, or a swap while the hook's own unlock is open. | `claim`/`dethrone` are `nonReentrant` (transient); both swap callbacks revert `PayoutInProgress` while the guard is set; `unlockCallback` requires the guard to be set and the caller to be the PoolManager. Three reentrancy tests. Credits are zeroed before the unlock. |
| R6 | Medium | A king who sells through a third-party router keeps earning until noticed. | Every swap, `claim()` and permissionless `dethrone()` checks holdings before crediting or vesting income. A short balance forfeits the unverified interval and provisional credits; vested pending credits survive; the throne price is recomputed in `afterSwap` after that dethrone so the next buyer takes an empty throne at the floor, not the stale price. `test_kingSellThroughAnotherRouterIsCaughtByTheHoldingRule`. The observation limits and conservative loss of unverified income are documented. |
| R7 | Low | `HookFlags.mine` allocated on every iteration; a long search ran out of memory in a test. | Hashes in a fixed buffer. |
| R8 | Low | `nextHalvingTime` used `%` on a timestamp (slither `weak-prng`) and the router refunded ETH with a raw `call` to `msg.sender` (slither `arbitrary-send-eth`). | Bounded loop; the router settles all of `msg.value` and lets the PoolManager `take` the surplus back to the user. Both detectors were silent in the original run; no fresh Slither result is claimed. |

### 1.2 Accepted (documented, no change)

| # | Severity | Observation | Why accepted |
|---|---|---|---|
| A1 | Medium | **Floor races after a vacancy.** The brief fixes the empty-throne price at 0.01 ETH, cheap relative to a large pool; latency bots will win the first buy after every vacancy. | By specification. The win is worth little: the price becomes 0.012 ETH, the income of a few seconds does not vest, and any player outbids at once. Noted as a parameter the requester may want to revisit (a floor tied to pool size). |
| A2 | Low | Third-party routers cannot take the throne. | Chosen identification model; the alternative (trusting any router's hookData) lets anyone crown anyone. Documented for the website. |
| A3 | Low | Timestamp dependence everywhere (18 slither `timestamp` lows). | The game is defined in time; sequencer timestamps influence income and the five-minute vesting boundary; ordering/censorship remain risks. No randomness is derived. |
| A4 | Low | If liquidity is exhausted, ETH-specified swaps revert `PartialFill`; other swaps can partially fill. Exact-input sell refunds now cover that outcome. | The factory's liquidity reaches the minimum tick; a drained pool is not a launch state. |
| A5 | Informational | The king can transfer tokens beyond `requiredBalance` freely and keep the throne. | Matches the brief ("at least the KING tokens bought in the takeover"). |
| A6 | Informational | A sitting king can start a new reign by buying at the price. | Revised: required balance is max(previous requirement, new buy's tokens); a short old reign forfeits income and the new reign starts a fresh vesting clock. Buying principal is resellable, so only fees/impact/gas are a cost. |

### 1.3 Not found

No path by which: a swap can be made to revert for everyone (no loops over users, no transfer to a
fixed recipient inside a swap, no dependency on the manager's ETH balance); anyone other than
`claim()` of a credited balance moves ETH out of the hook's claims; a completed order strands user ETH or KING in the hook or router (unsolicited deposits are excluded); a callback runs for a caller other than the PoolManager; a second pool attaches to the hook;
the token supply changes; a proxy, `delegatecall` or `selfdestruct` exists in deployed code (opcode
scans in tests).

---

## 2. Contract-by-contract notes

### `KingToken`
OpenZeppelin `ERC20`, constructor mints `10^27` to `msg.sender`, nothing else. Passes the floor
suite (`Token.protected.t.sol`: supply to deployer, policy supply, decimals, no admin selector
mints, exact transfer, opcode scan).

### `KingHook`
* **Permissions**: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta,
  afterSwapReturnDelta (`0x20CC`). `getHookPermissions()` agrees with the address (floor suite +
  `test_permissionsMatchTheMinedAddress`). Every enabled callback is `onlyPoolManager`; the seven
  unused ones revert.
* **beforeInitialize**: one pool only, ETH as `currency0`, the launch token as `currency1`, LP fee
  in {500, 3000, 10000}; records `launchTime`. A fee it refuses cannot launch; all three listed
  tiers are tested to initialize.
* **beforeSwap**: order is holding rule → accrue → fee. Official sells first call authenticated
  `prepareSell` before escrow, checking holdings, accruing and recording `Sold`; The fee for ETH-specified swaps is returned
  as `toBeforeSwapDelta(+fee, 0)`; v4 reduces the swap by it and the sign check in
  `Hooks.beforeSwap` (`HookDeltaExceedsSwapAmount`) cannot trigger since `fee < amount` for `r ≤ 25%`.
  No LP fee override (returns 0), so the pool's fee tier is untouched.
* **afterSwap**: fee for ETH-unspecified swaps from the settled delta (`poolEth · r / (1 − r)` so the
  gross ratio is `r`); 92/8 booking; throne logic; `mint` last (checks-effects-interactions).
  Gas (measured from traces): `beforeSwap` 12k–20k, about 99k when it dethrones a king;
  `afterSwap` 30k–80k for an ordinary swap (fee booking plus the claim mint) and 180k–215k on a
  takeover (new reign record, previous reign closed). The takeover case exceeds the reference's
  indicative 100k budget for `afterSwap`; it is a one-off per takeover and stays under the 300k
  ceiling given for callbacks with external calls.
* **Delta accounting**: the swapper's delta is `swapDelta − hookDelta` in both cases, so the
  trader always pays or receives exactly the gross amount minus/plus the fee; verified by balance
  assertions in the four fee tests, not only by hook state.
* **Accounting invariant**: `claims == pool + provisionalIncome + Σ pendingIncome` and
  `manager.balance ≥ claims` (invariant suite, 24 runs × 48 calls, plus the lifecycle test).
  Fixed-point rounding can favour the king when remaining-pool value rounds down; conservation
  is exact because earnings are computed as the difference. Unverified accrual stays in the pool.
* **Payout**: `unlock` → `burn` → `take`. The return value is checked. A rejecting recipient reverts
  only its own claim.
* **Views** are pure functions of state and time; `getReign` of the running reign reports the
  live earnings.

### `KingRouter`
* Deployed by the hook, so its address is an immutable the hook trusts; no owner.
* Exact-in buy: `msg.value` fully consumed (hook guarantees no partial fill). Exact-out buy:
  settles all `msg.value`, takes the surplus back to the user through the PoolManager (no raw ETH
  send in the router). Sells: authenticated pre-sell checkpoint then tokens pulled from `msg.sender`; both modes
  refund only that order's unconsumed input. Exact-input partial fills report actual input in the
  event; exact-output caps cannot be subsidized by preexisting router balances. Slippage and deadline on every function; zero amounts refused.
* `unlockCallback` requires the PoolManager as caller and the router's own guard to be set.
* Output always goes to `msg.sender`, which is what makes the hook's holding rule meaningful.

### `Halving`
`value · 2^(−num/den)`: whole halvings by shift (exact up to integer truncation), fraction by
64 binary digits. The error depends on value: a conservative per-call absolute bound is
`128 * value / 2^64 + 65` smallest units. Constants/shifts lower the value while exponent
truncation can raise it. Thus rounding is not universally downward, and rounding down a remaining
pool credits the difference to the king. Path independence holds only within this rounding error. Tested at boundaries, at 2^(−½) and 2^(−¼), for the
0.98-per-hour constant, for path independence and by fuzzing for monotonicity and bounds.

### `HookFlags`
Mirror of v4-core's flag bits; `matches`/`flagsOf` are what the floor suite expects; `mine` is used
by the fixture, the script and the fork test.

---

## 3. Economics

* **Inflow**: 2.3% of gross swap ETH volume (92% of 2.5%) after the first 30 minutes; the launch
  window contributes up to 23%. **Outflow**: 2% of the pool per hour to the king, i.e. 38.4% per
  day compounded. The pool therefore tracks recent volume: with `V` ETH of daily volume it settles
  near `0.023 · V / 0.384 ≈ 0.06 · V`. Without volume the pool halves every ~34.7 hours. The king's
  income is a share of recent trading, not a yield; the website should present it as such.
* **Throne pricing**: the price is in ETH paid, fee included, so it cannot be moved by trading the
  pool's price; it only moves by takeovers (×1.2) and time (÷2 per hour). A rational bidder pays
  up to the income he expects before being outbid; the ×1.2 rule makes outbidding wars converge
  geometrically and the halving keeps a stale throne contestable.
* **Who loses to a bot**: nobody directly. Every takeover is a token purchase the buyer keeps, so
  the only costs in the game are fees (which refill the pool) and price impact. The vesting rule
  blocks sub-five-minute relay exits; profitable five-minute farming and between-observation
  exit/restore remain possible. It is a minimum-exposure defence, not a profitability guarantee.
* **Team share**: 8% of fees, pull-only, no other privilege.
* **The requester's share**: 0%; all 90% of supply is launch liquidity, 10% stays with the factory
  as its policy dictates.

---

## 4. Open items for the independent reviewer

1. Review the choice of a 5-minute vesting window: shorter weakens the defence, longer punishes
   honest kings outbid early (every short reign now forfeits provisional income).
2. Consider whether the 0.01 ETH floor should scale with the pool (brief fixes it; see A1).
3. Confirm the factory's liquidity range sits entirely at or below tick 184216 so that it is
   KING-only; otherwise the factory must supply ETH.
4. Fork rehearsal on the actual launch chain if it is not Base; the hook is chain-agnostic but the
   PoolManager version should be exercised once (the Base fork test is the template).
5. Explorer verification of the token, hook and `hook.router()` after deployment.
