# KING — King of the Hill on Uniswap v4

A fixed-supply ERC-20 (`KING`) paired with native ETH in a Uniswap v4 pool whose hook runs a
"King of the Hill" throne game funded by an ETH trading fee. Contracts and tests only; no
frontend lives in this repository.

| Piece | File | Role |
|---|---|---|
| Token | `src/KingToken.sol` | Plain ERC-20, 1,000,000,000 × 10^18 minted to the deployer, nothing else |
| Hook | `src/KingHook.sol` | Fee, throne pool, throne game, payouts, views |
| Router | `src/KingRouter.sol` | Official swap router, deployed by the hook's constructor |
| Views/ABI | `src/interfaces/IKingHook.sol` | Structs, events, errors and the read interface for a website |
| Math | `src/libraries/Halving.sol` | Exact binary exponential decay used by the price and the income |
| Flags | `src/HookFlags.sol` | v4 permission bits, address check and CREATE2 salt mining |
| Manifest | `launch.json` | Factory manifest (`kind: univ4_hook`) |
| Script | `script/Deploy.s.sol` | Reference deployment; its `deploy()` is exercised by tests |
| Review | `docs/REVIEW.md` | Adversarial review of the economics and every contract |

## Chain

The brief says "the chain selected for this launch" without naming it, and no `network.json` was
supplied. The code is chain-agnostic (it uses `block.timestamp` only, never `block.number`, and
takes the PoolManager as a constructor argument). The fork rehearsal and the bot analysis assume
**Base (chain id 8453)**, whose PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b` was
checked with `cast code` on 2026-10-06. That address is only used by the optional fork test; the
deployer supplies the real `$poolManager`.

## The token

`KingToken` is OpenZeppelin's `ERC20` with a constructor that mints exactly `10^27` minor units
(1,000,000,000 KING, 18 decimals) to `msg.sender`. No owner, no mint, no burn, no pause, no
blocklist, no transfer fee, no proxy. The brief asked nothing of the token beyond this; every
rule of the game, including the trading fee, lives in the hook.

## The pool

* `currency0` = native ETH (`address(0)`), `currency1` = KING, LP fee 3000 (0.3%), tick spacing 60.
* Initial price: 1e8 KING per ETH, so 1e9 KING is a **10 ETH market cap**.
  `sqrtPriceX96 = sqrt(1e8) · 2^96 = 792281625142643375935439503360000` (tick 184216).
* Launch liquidity: 90% of supply (900,000,000 KING) single-sided, 0% to the requester. A KING-only
  position must sit entirely below the current tick, e.g. `[-887220, 184200]`; the tests and the
  fork rehearsal seed exactly that range. The factory owns the position and its LP fees.
* The hook accepts exactly one pool: ETH/KING at an LP fee of 500, 3000 or 10000. Anything else,
  including the dynamic-fee flag, is refused in `beforeInitialize`, and a second initialization is
  refused too. The factory deploys the token, then the hook, then initializes the pool in one
  transaction, so nobody can open the pool before the hook has code.

## The fee

Every swap pays a fee **in ETH**, on the settled ETH side of the trade:

| Swap | Specified amount | Where the fee is taken | Formula |
|---|---|---|---|
| Buy, exact input | ETH in | `beforeSwap`, as a hook delta on the specified ETH: the pool swaps `in − fee` | `fee = in · r` |
| Buy, exact output | KING out | `afterSwap`, as a hook delta on the unspecified ETH: the buyer pays `poolEth + fee` | `fee = poolEth · r / (1 − r)` |
| Sell, exact input | KING in | `afterSwap`, as a hook delta on the unspecified ETH: the seller receives `out − fee` | `fee = out · r` |
| Sell, exact output | ETH out | `beforeSwap`, as a hook delta on the specified ETH: the pool pays `out + fee` | `fee = out · r / (1 − r)` |

In every case the fee is `r` of the **gross** ETH that changes hands (what the buyer pays in
total, or what the pool pays out in total). `r` starts at **25%** when the pool is initialized and
falls linearly to **2.5%** over **30 minutes**, then stays there forever.

Split: **92%** to the throne pool, **8%** credited to the team wallet
`0x39E3414e7a43DE41675e9bEC52F7C9F6ae489CB6`, which pulls it with `claim()` like any king.
Nothing else can move money out of the throne pool.

### How the fee is held

The hook never asks the PoolManager to transfer ETH during a swap. It mints itself an ERC-6909
claim for the fee (`poolManager.mint(hook, 0, fee)`) inside `afterSwap`; the claim is backed by the
swapper's own settlement, so the first buy on a fresh PoolManager with a token-only pool works
(tested in `test_firstBuyOnManagerHoldingNoEthSucceeds` and on the Base fork). Payouts burn claims
and `take` ETH inside a PoolManager unlock the hook itself opens. Consequences:

* The PoolManager's ETH balance always covers the hook's claims (invariant-tested).
* A recipient that cannot receive ETH (a contract without `receive`) only breaks **its own**
  `claim()`; it can never halt a swap or anybody else's claim. This holds for the team wallet too.

### Partial fills

For the two cases charged in `beforeSwap` the fee is computed on the specified amount. If the pool
could not fill that amount (price limit reached) the hook reverts with `PartialFill` rather than
overcharge. With the launch liquidity reaching the minimum tick, an exact-input buy never partially
fills; an exact-output sell larger than the pool's ETH reverts (tested).

## The throne

* **Opens** when the anti-snipe period ends (`gameStart = launchTime + 30 min`). Before that the
  throne is empty, fees only fill the pool, and a must-take buy reverts.
* **Takeover**: one buy through `KingRouter` whose ETH amount, fee included, is at least
  `currentThronePrice()` makes the buyer king immediately. Several small buys never add up. Exact
  input and exact output both count (`paid = poolEth + fee` for exact output).
* **Price**: `max(0.01 ETH, 1.2 · paid · 2^(−hoursSinceTakeover))`. Exactly half at each full hour
  (`Halving` applies whole halvings as shifts). Empty throne: 0.01 ETH. `nextHalvingTime()` tells
  when it next halves, 0 at the floor.
* **Income**: while there is a king the pool pays `2%` of itself per hour, compounded per second:
  `pool(t) = pool(t0) · 0.98^((t − t0)/3600)`, the difference credited to the king. It is
  path-independent, so how often the accrual is booked changes nothing. `incomePerHour()` is 2% of
  the current pool. The king claims any time, also after losing the throne.
* **Holding rule**: the king must keep at least the KING his takeover delivered
  (`requiredBalance`). Any sell by the king through `KingRouter` empties the throne at once,
  whatever the amount. Every swap also checks `balanceOf(king) >= requiredBalance` in `beforeSwap`,
  and the permissionless `dethrone()` does the same; both stop the income at that moment. Sells by
  anyone else never touch the throne.
* **Same king again**: a buy by the sitting king that meets the price is a new reign (new price
  base, new required balance, new history entry).
* **Must-take flag**: `KingRouter.buyExactIn/buyExactOut(..., mustTake = true, ...)` reverts the
  whole swap (no fee, no tokens, nothing) if the buy would not take the throne.

### Income vesting: the defence against throne farming

See the analysis below. The income earned in the first **5 minutes** of a reign vests only when
the reign is 5 minutes old (then everything vests at once and the king is paid per second as
usual) or when **somebody else** dethrones him by a takeover. A king who ends his own reign
earlier, by selling or by letting his balance drop below the requirement, forfeits that income
back to the pool (`Reign.forfeited`, event `IncomeForfeited`). `unclaimedIncome(king)` shows what
is claimable now; `kingVestingIncome()` shows what is earned but not yet claimable; `throne()`
carries both and `vestsAt`.

## Identifying the real buyer

Inside a hook `msg.sender` is the PoolManager and the `sender` argument is the router, never the
user. The options and their trade-offs:

| Approach | Problem |
|---|---|
| `sender` (the router) | A shared router (Universal Router) would be "the buyer" for everyone. |
| `tx.origin` | Forbidden by the security reference: a phishing vector, and wrong for smart wallets, 4337 bundlers and Safes, where `tx.origin` is a relayer. |
| hookData from any router | Any contract can name any address. Harmless to the pool but lets a griefer crown a stranger, and the hook cannot know whether that address received the tokens. |
| **hookData from a router the hook owns** (chosen) | The hook deploys `KingRouter` in its constructor and trusts hookData only when `sender == router`. The router writes `msg.sender` into hookData and always delivers the output to `msg.sender`, so the buyer named is the wallet that holds the tokens, which the holding rule needs. |

Swaps through any other router (Uniswap app, aggregators) pay the fee like everyone else but
cannot take the throne, and hookData they carry is ignored (tested). The website should route
through `hook.router()`.

A sell by the king through a third-party router cannot be attributed during that swap, because such
routers pull the tokens **after** the hook ran. The balance check catches it at the next swap by
anyone or at a `dethrone()` call, and the throne price is recomputed after that dethrone inside
the same swap, so the next buyer takes an empty throne at the floor. Through `KingRouter` the
dethrone is immediate.

## Bot farming: what we saw and what defends against it

* **Take-and-dump skimming.** Take the throne at the floor, hold one block, sell, repeat. The
  income of one 2-second Base block is `pool · 2% · 2 / 3600`; the round trip costs two fees (about
  5% of 0.01 ETH). It is profitable only for a pool above ~45 ETH on Base (~7.5 ETH on a 12-second
  chain) and would keep the throne permanently occupied by a bot at the floor. **Defence**: the
  5-minute income vesting above. A bot that exits by itself inside 5 minutes earns nothing, and a
  bot that holds 5 minutes is a player like any other, exposed to the 1.2× outbid rule.
* **Sandwiching / front-running a takeover.** On a public mempool a bot can front-run a takeover
  with a slightly larger buy. The victim then either buys tokens without the throne or, with the
  **must-take flag**, reverts and pays no fee. The front-runner now holds the throne at 1.2× what it
  paid, so it cannot squat for free. On Base there is no public mempool (the sequencer orders by
  arrival, with Flashblocks pre-confirmations), so this needs sequencer-side insight.
* **Sequencer ordering / latency races.** After a vacancy the price is the floor by specification,
  so the first buy to reach the sequencer wins it; a latency bot will usually win that race. The
  win is cheap, not valuable: the next player takes it for 1.2 × 0.01 ETH and the bot's income
  of a few seconds is below the vesting threshold. Competition is in ETH size, not latency.
* **Block stuffing.** Nothing in the game is settled per block or at a deadline; price and income
  are continuous in `block.timestamp`, so stuffing buys nothing. Sequencer timestamp drift is a
  few seconds and affects income by `2% · drift / 3600`.
* **Flash loans.** A takeover must be held across time to earn and a sell dethrones at once;
  inside one transaction no income exists.
* **Self-dethrone to reset the price.** Only hurts the king who does it: the throne empties and
  anyone may take it at the floor.

## Views for the website

All on `KingHook` (see `IKingHook`):
`king()`, `reignStart()`, `requiredBalance()`, `takeoverPaid()`, `currentThronePrice()`,
`nextHalvingTime()`, `poolSize()`, `incomePerHour()`, `unclaimedIncome(wallet)`,
`kingReignEarnings()`, `kingVestingIncome()`, `pendingIncome(wallet)`, `feeRate()`,
`gameOpen()`, `gameStart()`, `launchTime()`, `reignCount()`, `getReign(i)`,
`getReigns(offset, limit)` (past kings with start, end, paid, required, earned, forfeited,
reason) and `throne()` which packs the live state into one struct. `router()` returns the
official router; `poolKey()` the pool.

## Hook configuration (Wizard record)

```json
{
  "hook": "BaseHook",
  "name": "KingHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": true,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

The hook implements `IHooks` directly on v4-core (no v4-periphery dependency) with an
`onlyPoolManager` modifier on every enabled callback; unused callbacks revert
`HookNotImplemented`. `beforeSwapReturnDelta` is used only to take the ETH fee from a specified
ETH amount (never to no-op a swap); `afterSwapReturnDelta` only to take the ETH fee from an
unspecified ETH amount. Transient storage is OpenZeppelin's `ReentrancyGuardTransient`
(Cancun). Address flags: `0x20CC` (`HookFlags.KING_HOOK_FLAGS`). Access control: none, by design.

## Deployment parameters

* Compiler `solc 0.8.26`, `evm_version = cancun`, optimizer 200 runs, `via_ir = false`,
  `bytecode_hash = "none"`, `cbor_metadata = false`, no `ffi`, no fs permissions.
* Hook constructor: `(IPoolManager poolManager, address token)`, written `["$poolManager", "$token"]`
  in `launch.json`. The constructor requires both addresses to have code and deploys `KingRouter`.
* The hook address must carry flags `0x20CC`; `HookFlags.mine(deployer, flags, creationCode, n)`
  finds a CREATE2 salt (the deployer is whoever executes CREATE2).
* Pool: ETH/KING, fee 3000, tick spacing 60, `sqrtPriceX96 = 792281625142643375935439503360000`.
* Liquidity: 900,000,000 KING in a range whose upper tick is at most the initial tick (184216),
  e.g. `[-887220, 184200]`.
* `script/Deploy.s.sol`: `run()` reads `POOL_MANAGER` from the environment and calls
  `deploy(poolManager, create2Deployer)`, which the tests call directly. It is a rehearsal aid;
  the factory performs the launch.

## Operational responsibilities

* **Nobody can pause, upgrade, or change a parameter.** There is no owner. Deploy only after an
  independent adversarial review (see `docs/REVIEW.md` for the first pass and its open items).
* **Team wallet** must call `claim()` on the hook to receive its 8%. If that wallet is a contract
  it must accept plain ETH transfers.
* **Website** should use `hook.router()` for buys and sells (`buyExactIn`, `buyExactOut`,
  `sellExactIn`, `sellExactOut`, all with slippage and deadline parameters) so that takeovers and
  the must-take flag work, and should warn that a sell through any other venue drops the throne at
  the next interaction.
* **Monitoring**: `ThroneTaken`, `ThroneVacated`, `IncomeVested`, `IncomeForfeited`, `Claimed`,
  `FeeCollected`. Anyone may call `dethrone()` when the king's balance falls short; a keeper is
  optional because every swap does the same check.
* **Explorer verification** (`forge verify-contract`) is the deployer's step; verify the token, the
  hook and `hook.router()`.

## Tests

```
forge build
forge test
forge fmt --check
```

* `test/KingToken.t.sol` — supply, transfer, no admin surface, opcode scan.
* `test/Halving.t.sol` — exactness at half-lives, 2^(−½), the 0.98-per-hour constant, fuzzing.
* `test/KingHook.Fee.t.sol` — anti-snipe decay, ETH fee on all four paths, settled-delta
  computation, 92/8 split (fuzzed), fresh-manager buy, rejecting recipients.
* `test/KingHook.Throne.t.sol` — opening, takeover at/below price, 1.2×, hourly halving to the
  floor, per-second 2%/h income, path independence, claims during and after a reign, holding rule
  through both routers, `dethrone()` success and refusals, must-take, vesting, history, views.
* `test/KingHook.Security.t.sol` — flags, opcode scan, caller checks, initialization rules,
  reentrancy (claim, swap and dethrone during a payout), foreign hookData, no admin surface,
  partial fill, lifecycle solvency.
* `test/KingHook.Invariant.t.sol` — random play: claims back the pool and every credit, the
  manager holds the ETH, the hook and router hold nothing, throne state consistent.
* `test/Deploy.t.sol` — the script's `deploy()` on a fresh PoolManager.
* `test/fork/KingHookFork.t.sol` — launch rehearsal on a **Base mainnet fork** against the live
  PoolManager. It skips (never passes silently) when no RPC is reachable, so the offline verifier
  reports it as skipped; with network access it runs and passed on 2026-10-06.

The floor suite in `.imd/reads/protected` was also run against the hook's and token's creation
code (10/10 pass). Slither (installed locally) reports only `block.timestamp` comparisons on
`src/`, all intended: the game is defined in time. Fuzz runs: 256; invariant runs 24 × depth 48.

## Assumptions and limitations

* The launch chain is assumed to be Base; nothing in the code depends on it.
* The LP fee tier is 3000; the hook also accepts 500 and 10000 in case the factory chooses another.
* Timestamps come from the sequencer; drift of seconds changes income by parts per million.
* The income formula is "2% of the pool per hour, compounded per second" (`0.98^(hours)`), the
  path-independent reading of "credited every second".
* "A single buy" is one swap; the brief's amount is the fee-inclusive ETH the buyer pays.
* The vesting rule is an addition the brief did not specify; it is the requested defence.
* Takeovers are only possible through `KingRouter`; third-party routers pay the fee only.
* The `Halving` library needs `value < 2^192`; ETH amounts are far below that.
