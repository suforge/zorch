# Zorch

**An open-source, immutable memecoin launchpad on Robinhood Chain.**

Every trade's 1% fee buys back the platform token **$ZORCH** and burns it — on-chain,
verifiable, with no admin and no off switch. Same buyback-burn engine that works on this
chain, made fully open and unruggable.

> ⚠️ **Status: work in progress · testnet only · unaudited.** Do not use with mainnet funds.

## How it works

- **Launch** — one click deploys a plain ERC-20 with 100% of supply seeded into a
  *single-sided*, permanently-locked Uniswap v3 position. Zero ETH required, tradeable from
  the first block, no migration.
- **No rug, structurally** — the LP can never be withdrawn (there is no `decreaseLiquidity`
  path in the locker), and launched tokens are plain ERC-20s with no tax, no blacklist and
  no mint after deploy — so they physically cannot be honeypots.
- **Flywheel** — a flat 1% swap fee accrues inside the locked LP. A permissionless crank
  sweeps it, market-buys $ZORCH and burns it to `0xdead`. Anyone can trigger the crank for a
  small tip; no one can turn it off.
- **Open & immutable** — every contract is public, ownerless and non-upgradeable. Bug fixes
  ship as a new factory *version*, never as an upgrade to a live one.

## Contracts

| Contract | Purpose | Status |
|---|---|---|
| `FairLaunchToken` | Plain fixed-supply ERC-20 (no owner / mint / hook / tax) — the launched coin and $ZORCH | ✅ |
| `LaunchFactory` | One-click single-sided launch + locked LP + flat launch fee | ✅ |
| `LpLocker` | Holds LP position NFTs forever; permissionless fee `collect()` only | ✅ |
| `BuybackBurner` | Permissionless crank: buy $ZORCH with collected fees and burn | WIP |

Supporting: `libraries/TickMath.sol` (vendored Uniswap subset), `interfaces/UniV3.sol`
(minimal), `RHAddresses.sol` (Robinhood Chain, chainId 4663, Uniswap v3 + WETH).

## Build & test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge install foundry-rs/forge-std   # the only dependency (tests)
forge build
forge test                           # unit tests
forge test --fork-url rh             # fork tests against Robinhood Chain
```

The core contracts are intentionally dependency-free so each can be audited in isolation.

## License

MIT. Forks welcome — for a public good, being forked is success.
