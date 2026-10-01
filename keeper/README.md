# Multyr keeper

A keeper bot for Multyr automation that is not tied to any one provider. It
covers the six primary workflows (W1–W6) of the Arbitrum One deployment of
2026-09-25.

The bot makes **no allocation or strategy decisions.** It reads on-chain state
and calls the existing keeper entrypoints. All eligibility rules, thresholds,
caps, cooldowns and allocation logic stay enforced on-chain, exactly as they are
under Chainlink Automation or CRE. If both bots are down, the authorized manual
path still works.

```
PRIMARY                               SECONDARY
AWS ECS/Lambda · AWS KMS              GCP Cloud Run · GCP KMS
RPC provider A · keeper address A     RPC provider B · keeper address B
          │                                     │  acts only after the condition
          │                                     │  has been due for the grace window
          └──────────────► Multyr contracts ◄───┘
```

Both instances run the same code and the same image. Only their environment differs.

## Workflow coverage

| ID | Target (Arbitrum One) | Call | Permission needed by bot | Trigger used | If both bots fire |
|---|---|---|---|---|---|
| W1 | VaultUpkeep `0x0196…2FFE` | `checkUpkeep` → `performUpkeep(performData)` | none (permissionless) | poll 120s; on-chain priority, cooldowns and backoff decide | inner call fails and is caught; increments `consecutiveFailures` (see note 1) |
| W2 | StrategyUpkeep `0xA01A…3ee6` | `checkUpkeep` → `performUpkeep(performData)` | none (permissionless) | poll 300s; `pokeInterval` and the strategy's own cooldowns decide | `performUpkeep` re-checks cooldowns and reverts in simulation, so no tx is sent |
| W3 | ClaimSettlementUpkeep `0xD8CE…a14E` | `checkUpkeep` → `performUpkeep` | none (permissionless) | poll 120s, up to 25 batches per tick | ignores caller data, rescans chain state, no-ops if nothing is left |
| W4 | FeeCollector `0x7976…Aa4B9a` | `harvestQueued(token)`, `distribute(token)` | none (permissionless) | `distribute` only in a weekly UTC window (default Mon 10:00, 6h); `harvestQueued` whenever claims are pending | both revert when nothing is left, so the second call fails simulation and no tx is sent |
| W5 | Strategy vault `0xCC4A…AEf1` | `pokeLiquidityBatch(start,end)` | **`KEEPER_ROLE` on the strategy vault, granted to each bot address** | only batches whose cached liquidity is within the margin of expiry | idempotent; costs gas only |
| W6 | BufferManager `0xeC5a…57e1` | `refreshWarmNav()` | none (permissionless) | `warmNavState.ts + navRefreshInterval − margin`, or `valid == false` | idempotent; costs gas only |

How each tick works:

- **Simulation first.** Every write is simulated with an `eth_call` from the keeper address before sending. A revert means "not eligible", and no tx goes out.
- **Bounded follow-ups.** W1–W3 `performUpkeep` does one action per call. After a success the bot re-checks and continues, up to `maxActionsPerTick`. That covers close → fund → reconcile, multi-step rebalance plans, and claim backlogs within one tick, so a daily POKE_APY can no longer starve the other operations.
- **Inner failures become alerts.** Inner calls are wrapped in try/catch on-chain, so a mined tx can still contain a failed operation. The bot decodes the receipt events (`UpkeepPerformed(success=false)`, `UpkeepErrored`, `SnapshotPokeFailed`, `ClaimSettlementFailed`, `AdapterCallFailed`, `WarmNavCacheUpdated(valid=false)`, `HarvestDeferred`) and turns them into alerts.

### Primary / secondary

- **Primary** acts as soon as a condition is due.
- **Secondary** acts only once a condition has been due for longer than that job's `secondaryGraceSec`.
  - W4, W5 and W6 can derive "due since" from chain state (window start, cache timestamp + TTL), so this works even in stateless scheduled runs.
  - W1–W3 have no on-chain timestamp. In `run` mode the secondary remembers when it first saw the condition. In `once` mode it acts on anything due, and you get the grace by **offsetting its schedule** (e.g. primary every 2 min, secondary at :10 past).
- The two bots use separate addresses, so there is no nonce contention between them. Within one bot, jobs run sequentially, so there is at most one in-flight tx.

## Usage

Requires Node ≥ 22.18. TypeScript runs directly through Node's type stripping, with no build step.

```bash
npm install
npm test                 # unit tests
npm run typecheck

# Read-only. A signer is not required: KEEPER_ADDRESS is used for simulation.
KEEPER_INSTANCE=primary RPC_URLS=https://arb1.arbitrum.io/rpc KEEPER_ADDRESS=0x… npm run preflight
KEEPER_INSTANCE=primary RPC_URLS=… KEEPER_ADDRESS=0x… npm run check    # dry run of every job

# Sending
node src/index.ts run    # long-lived loop (container), /healthz on $PORT
node src/index.ts once   # one pass, for cron / Cloud Run job / Lambda
JOBS=W5,W6 node src/index.ts run   # limit to a subset
```

See `deploy/*.env.example` for the primary (AWS KMS), secondary (GCP KMS) and shadow (local key) environments.

- **KMS keys.** AWS key spec `ECC_SECG_P256K1`; GCP algorithm `EC_SIGN_SECP256K1_SHA256`. The private key never leaves the HSM.
- **Logs and alerts.** Logs are one JSON line per event, which CloudWatch and Cloud Logging both parse. `ALERT_WEBHOOK_URL` takes a Slack- or Discord-compatible webhook. Alerts are rate-limited per key for 30 minutes.

**Multichain.** Add `config/<network>.json` with that chain's addresses and run a separate deployment per chain, each with its own RPCs, keys and alert channel. More jobs or vault configurations mean more entries in the `jobs` array, not more billed workflow slots.

## On-chain actions before go-live

1. `KEEPER_ROLE` on the strategy vault for keeper address A and keeper address B. W5 only; everything else is permissionless.
2. Fund both keeper addresses with ETH. The balance alert fires below `minKeeperBalanceEth`.
3. Nothing else changes. No receiver, forwarder or registry contracts are needed, and no Chainlink registration.

## Findings from preflight against the live deployment (2026-10-01)

- **W4.** `shareConfigs(coreVault)` is unset, so `distribute(coreShareToken)` auto-detects ERC-4626 and splits *shares* (`SPLIT_SHARES`). `harvestQueued` cannot work until governance sets `AUTO_HARVEST`. Either set it, or drop the core share token from `harvestQueuedTokens`.
- **W5.** `liquidityStalenessSeconds()` is 0, so the bot falls back to `fallbackMaxAgeSec` (3600s). The prior runbook proposed a 5-minute cadence. Set the on-chain value, or confirm the fallback.
- **W2.** 3 poke targets for 7 adapters. Not directly poked: Aave (covered by the rate push), Comet, Euler and Venus. Confirm those adapters compute APY live. Venus `accrueVenusInterest()` remains a conditional operation.
- **Stale caches.** W1, W2, W5 and W6 are all due right now (CRYSTALLIZE, POKE_APY, all 7 liquidity caches about 6 days old, warm NAV about 67 hours old). Nothing has run since deployment.

### Notes

1. **VaultUpkeep is the one target where a duplicate call has a side effect.** Its `performUpkeep` trusts `performData` without re-checking eligibility. An ineligible op fails inside try/catch and increments `consecutiveFailures`; at 3 failures the upkeep backs off for 30 minutes. This holds for *any* caller, so it is a griefing surface under Chainlink or CRE too. The secondary's grace window keeps the two bots from colliding, but the contract-level fix is to re-validate in `performUpkeep` (e.g. compare against `checkUpkeep`) and to skip the failure counter on mismatch.
2. W2 under-reports one thing: `StrategyUpkeep._performPokeAPY` sets `lastPokeTs` even when individual targets fail. The bot raises those failures as alerts from `SnapshotPokeFailed` and `ExternalTVLPokeFailed`.
