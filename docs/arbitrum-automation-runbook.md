# Arbitrum automation and deployed-system test plan

Prepared 2026-09-15 for the **40 addresses in your supplied deployment list**, captured in
[`arbitrum-deployment.json`](../script/automation/arbitrum-deployment.json).
Your document reports Arbiscan verification; this session has not independently verified current bytecode,
wiring, ownership, balances or scheduler registration. Both public RPC endpoints attempted returned HTTP 403.
Historical broadcast files include other deployments and forks; they are not the target list.

## What to set up

There is no one-job-per-contract requirement. Delegate modules execute through their vault,
and factories/bootstrap contracts are deployment infrastructure. For this deployment, provision:

| Job | Target | Work | Starting cadence; validate on a fork |
| --- | --- | --- | --- |
| Core maintenance | Existing `VaultUpkeep` `0x8672921E03c9995AE1Dbe234A7a08C327163883e` | Epoch close/fund, pending-exit reconciliation, crystallization, buffer rebalance, inter-strategy rebalance, deploy/realize | CUSTOM check every minute; contract gates actual work |
| Lending maintenance | Existing `StrategyUpkeep` `0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550` | Aave rates, adapter APY snapshots, external TVL/capacity, idle deployment, harvest, prepare/execute rebalance steps | CUSTOM every minute; inspect nonzero `pokeInterval` |
| Liquidity observations | Strategy `0x2ca30120C828Fc136d348234f7e68116572DD83E` | `pokeLiquidityBatch(start,end)` refreshes liquidity and stability observations | CRON every 5 minutes as an initial test setting; one enabled adapter per batch; fit all batches inside actual cache TTL |
| Fee distribution | Deploy `FeeCollectorUpkeep` for `0x668E07AFf65a84595F43493333068EB7cF07d774` | Distribute registered share/underlying tokens | CUSTOM every minute; distribution interval is separate governance configuration |
| Queued fee collection | FeeCollector, **if AUTO_HARVEST enabled** | `harvestQueued(vault)` after at least one pending claim becomes claimable | Conditional check after epoch funding, plus periodic catch-up; **missing from FeeCollectorUpkeep** |
| Operational monitoring | All 40 contracts plus scheduler | Wiring, roles, pauses, cache age, outstanding epochs, progress, failures, funds/gas | Every minute for liveness; daily configuration reconciliation; event alerts |

With seven enabled adapters, single-adapter liquidity batches mean **7 liquidity workflows + 2 existing CUSTOM workflows + 1 new fee CUSTOM workflow** (10 execution workflows), plus a conditional fee-claim worker and monitoring. Batch count depends on the live enabled list and measured gas; seven deployed adapters does not prove seven enabled adapters.

**Do not register new legacy Automation upkeeps.** Chainlink's current documentation gives sunset dates of
June 30, 2026 for v1.x and July 31, 2026 for v2.1 (testnets June 24). Use CRE and its official Automation
Migration template. Sources: [Automation service notice](https://docs.chain.link/chainlink-automation),
[TypeScript migration guide](https://docs.chain.link/cre/reference/cla-migration-ts),
[official template](https://github.com/smartcontractkit/cre-templates/tree/main/starter-templates/automation-migration).

## Important gaps and preconditions

1. **APY/TVL pokes do not refresh liquidity.** `LendingStrategyUpkeep._performPokeAPY()` calls
   `pokeExternalTVL()` but never `pokeLiquidityBatch()`. See
   [StrategyParamsModule](../../multyr-strategies/src/strategies/usdc-lending/controller/StrategyParamsModule.sol).
   Batch ranges index the **enabled adapter list**, not necessarily deployment order. Reconcile membership
   and regenerate ranges when adapters change. Gas depends on funded positions: the source notes Morpho can
   cost around 3.15M gas alone; measure against current CRE read/write limits, including receiver overhead.
2. **Authorize actual callers.** BufferManager's keeper must be the existing VaultUpkeep. The existing
   StrategyUpkeep needs strategy `KEEPER_ROLE`; Aave rate provider and configured snapshot targets need
   the relevant `PARAM_ROLE` grants. Direct liquidity jobs call through a CRE receiver, which itself needs
   strategy `KEEPER_ROLE`. Do not grant these roles to the CRE forwarder: the receiver is the immediate caller.
3. **Avoid starvation.** A zero `pokeInterval` makes APY continuously eligible and can starve strategy work.
   Current deployment code sets one day, but read the deployed value. Check per-adapter cache timestamps,
   not just `lastPokeTs`: caught failures can still advance the overall timestamp. Assess the one-day
   interval against each actual freshness bound; do not assume deployment defaults are sufficient.
4. **Successful transaction is not successful maintenance.** Core emits `UpkeepPerformed(...,success)`;
   strategy emits `UpkeepErrored`, `SnapshotPokeFailed`, `ExternalTVLPokeFailed`; fee upkeep emits
   `DistributionFailed`. Aave rate push failures are caught silently. Assert underlying state progress.
5. **Fee upkeep does not finish AUTO_HARVEST queues.** Inspect pending claim coordinates, identify funded
   claimable epochs, simulate `harvestQueued(vault)` and only submit if it succeeds. If none can settle,
   it reverts. Test partial settlement; monitor the pending list's gas growth. A blind CRON call would burn
   gas or fail when no claims are ready, so the provided generic CRON generator is not a complete worker for this job.
6. **Fee distribution readiness is weaker than the collector's full rules.** Upkeep checks interval and
   nonzero balance, but the collector additionally checks pause, token configuration, minima and share mode.
   Its failed attempt advances the retry timestamp. Configure the share token before ownership handoff;
   monitor failures and balances, not only schedule delivery.
7. **Additional data maintenance is conditional.** Strategy `syncPositionAssets()` / `syncPositionAsset()`
   are PARAM_ROLE operations; inspect drift and existing internal synchronization before adding a job.
   DolomiteSupplyRateProvider's `setSupplyRatePerSecond(market,rate)` is owner-only and not populated by
   StrategyUpkeep. Determine whether the adapter actually uses this provider/override and define a validated
   rate source, units and bounds before automating updates. Do not invent rates or give a generic bridge ownership.
8. **Safety monitoring is not automatic emergency policy.** Existing
   [safety_adapter_monitor.py](../../multyr-strategies/script/keepers/safety_adapter_monitor.py) is a starting
   point. Cover oracle freshness/depeg/sequencer outages, protocol liquidity, NAV drift, blocked adapters,
   stuck plans and health registry state. Governance/guardian decides pause, disable or recovery actions
   unless a bounded, explicitly authorized policy is implemented.

## Contracts covered by each test layer

| Deployed components (40 total) | Required coverage |
| --- | --- |
| RootTimelock (1) | Proposer/executor/canceller roles, delay, schedule/execute/cancel, ownership, unauthorized calls |
| VaultFactory, GlobalConfig, SelectorRegistry, SystemSealer, RecoveryGate (5) | Configuration and selector wiring, one-time sealing/bootstrap restrictions, ownership transfer, pause/recovery paths; no recurring deployment jobs |
| CoreVault, EpochedQueueModule, AdminModule, ERC4626Module, LiquidityOpsModule (5) | Test through CoreVault: deposit/mint/withdraw/redeem, previews/fees, queued withdrawal, claim, pause, lifecycle/access controls |
| BufferManager, StrategyRouter, two warm adapters, VaultUpkeep (5) | Hot/warm targets, deploy/recall, cooldowns, reserve shortfalls, queued fund waterfall, losses and stalled-funding backoff |
| FeeCollector, PriceOracleMiddleware, StrategyHealthRegistry (3) | Fee routing/share modes/queued harvest, oracle validation and stale data, health gating and authorized state updates |
| AdapterFactory, StrategyBootstrapper, ProtocolRegistry (3) | Registered markets/protocols, allowed dependencies, bootstrap closed, no unauthorized additions |
| StrategyParamsModule, StrategyScoringModule, StrategyAdapterOpsModule, StrategyRebalanceGateModule, StrategySettingsModule, StrategyAllocCalcModule, StrategyRebalancePlanModule (7) | Routed selectors and roles through strategy, caps/scoring/eligibility, gas/slippage/cooldowns, plan execution and recovery |
| UsdcMultiLendingVault, StrategyUpkeep (2) | End-to-end capital accounting, idle deployment, harvesting, rebalance plan progress, recall, freshness and liveness |
| Aave, Morpho, Comet, Euler, Dolomite, Fluid, Venus lending adapters (7) | Each funded adapter: deposit/withdraw, APY/TVL/liquidity, rewards if supported, protocol-specific failures and withdrawal limits |
| AaveLiquidityRateProvider, DolomiteSupplyRateProvider (2) | Units, configured callers/source, rate updates, adapter consumption and stale/fallback behavior |

**Not in your 40-contract list:** PeripheryUpkeepAdapterV2, OpsCollectorV2, FeeDistributorV2, EpochPayout,
FeeCollectorUpkeep, FixedMaturityVaultUpkeep, IncentivesEngine, StrategyScorer and ExecutionMemory.
Treat them as additional deployment scope only if live configuration points to them.

If the rewards periphery is subsequently deployed: add the shared SPLIT/FUND upkeep, an indexed reward
calculation job, validated Merkle root generation/publication (`publishRoot` is owner-only), epoch advancement
(`advanceEpoch` is owner-only), solvency checks and claimant proof tests. The SPLIT/FUND adapter does not
publish roots, advance reward epochs or claim rewards for users.

If FM vaults are subsequently deployed: the current FM checker schedules funding failure, maturity marking,
and queue close/fund. Despite its header, it does **not** schedule start/activate/recall/close, and it returns
false while matured capital remains withdrawable. Those transitions require a separate authorized process.

## Setup code

### 1. Verify the exact deployment list

From multyr-periphery, using Python 3 and a working RPC (no private key required):

```sh
export ARBITRUM_RPC_URL='https://YOUR_ARBITRUM_RPC'
python3 script/automation/arbitrum_inventory.py \
  --manifest script/automation/arbitrum-deployment.json \
  --output /tmp/multyr-arbitrum-live.json
```

The checker pins a block, checks chain ID, and distinguishes missing code from RPC failure. Code existence
alone does not prove deployed/source equivalence or correct wiring. Compare runtime/proxy implementations
to verified sources and query all relevant state before enabling jobs. Modules must be invoked through
their vault/strategy for delegated operations.

Read-only preflight examples (Foundry `cast`):

```sh
cast call 0x8672921E03c9995AE1Dbe234A7a08C327163883e 'checkUpkeep(bytes)(bool,bytes)' 0x --rpc-url "$ARBITRUM_RPC_URL"
cast call 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550 'checkUpkeep(bytes)(bool,bytes)' 0x --rpc-url "$ARBITRUM_RPC_URL"
cast call 0x8eCE4bB8CAd975902F221E961215aa0CB6a3e5a5 'keeper()(address)' --rpc-url "$ARBITRUM_RPC_URL"
cast call 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550 'pokeInterval()(uint64)' --rpc-url "$ARBITRUM_RPC_URL"
cast call 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550 'getPokeTargets()(address[])' --rpc-url "$ARBITRUM_RPC_URL"
cast call 0x2ca30120C828Fc136d348234f7e68116572DD83E 'hasRole(bytes32,address)(bool)' "$(cast keccak KEEPER_ROLE)" 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550 --rpc-url "$ARBITRUM_RPC_URL"
```

Also verify actual core/router/strategy links, enabled adapters, ownership/admin roles, seal state,
asset/decimals, oracle sources, fee destinations/share mode, pause flags and all per-adapter cache ages.
The historical manifest says PRE-SEAL; that is not evidence of the current state.

### 2. Initialize the official CRE project and bridge

Install the [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation) and Bun, log in, and
confirm deployment access. The prepared project already includes local CLI/Bun tools under
`multyr-chainlink/.tools`; see [current setup status](../multyr-chainlink/SETUP-STATUS.md).
The following initialization command is only for a fresh project, not the existing prepared directory:

```sh
cre init --template=automation-migration-ts --project-name multyr-chainlink --workflow-name my-workflow
```

Use the template's `AutomationReceiver.sol`, not a newly invented generic execution contract.
Deploy on Arbitrum with the current **CRE KeystoneForwarder** from the
[forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts).
Confirm it has code and is for production Arbitrum. Set expected author plus workflow name (or exact workflow ID),
allow only required target/selector pairs, configure consumer gas, and transfer receiver ownership to the
intended governance address. Prefer one receiver per workflow/security boundary, especially for role-bearing
liquidity jobs. A shared receiver's single expected workflow name/ID cannot simultaneously match different jobs.

Example deployment command from the initialized project's `contracts/evm` directory, after reviewing its source:

```sh
forge create src/AutomationReceiver.sol:AutomationReceiver \
  --constructor-args "$CRE_FORWARDER" --rpc-url "$ARBITRUM_RPC_URL" --account "$DEPLOYER_ACCOUNT" --broadcast
```

`--broadcast` sends a real transaction. No deployment or role-grant commands were executed in this session.

### 3. Generate workflow configuration

The supplied [configure_cre.py](../script/automation/configure_cre.py) clones the initialized official
workflow into independent job folders. In this repository it can use the existing `multyr-core`
workflow as its source; that folder names the vault workflow, not the repository. The prepared
`multyr-core` job already exists, so skip the first generation command below and configure it
using [SETUP-STATUS.md](../multyr-chainlink/SETUP-STATUS.md). It refuses overwrites, requires real nonzero addresses and an
explicit gas budget, and does not submit transactions. It uses the official template's CUSTOM/CRON schema.

The prepared `multyr-strategy` job now also already exists (see
[STRATEGY-SETUP-STATUS.md](../multyr-chainlink/STRATEGY-SETUP-STATUS.md)), so skip its generation command
below too until you are ready to regenerate it with a real receiver/gas.

```sh
python3 script/automation/configure_cre.py --project ./multyr-chainlink --name multyr-core \
  --receiver "$CORE_RECEIVER" --target 0x8672921E03c9995AE1Dbe234A7a08C327163883e --gas "$CORE_GAS"
python3 script/automation/configure_cre.py --project ./multyr-chainlink --name multyr-strategy \
  --receiver "$STRATEGY_RECEIVER" --target 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550 --gas "$STRATEGY_GAS"
python3 script/automation/configure_cre.py --project ./multyr-chainlink --name multyr-liquidity-0 \
  --receiver "$LIQUIDITY_RECEIVER" --target 0x2ca30120C828Fc136d348234f7e68116572DD83E \
  --gas "$LIQUIDITY_GAS" --schedule '0 */5 * * * *' \
  --function 'pokeLiquidityBatch(uint256,uint256)' --args '[0,1]'
```

Repeat liquidity jobs for each confirmed enabled range, preferably staggered. Do not use an unmeasured
500k gas default: include receiver/report overhead and worst funded-state gas. Verify current CRE limits;
split work or change implementation if a single action exceeds them. Both generated configuration targets
use **mainnet Arbitrum**; `test-settings` names a configuration, not a testnet.

For each receiver, the owner must execute reviewed setup transactions:

```sh
# Example for CORE_RECEIVER; repeat with each job's own target, selector and identity.
cast send "$CORE_RECEIVER" 'setCallAllowed(address,bytes4,bool)' \
  0x8672921E03c9995AE1Dbe234A7a08C327163883e "$(cast sig 'performUpkeep(bytes)')" true \
  --rpc-url "$ARBITRUM_RPC_URL" --account "$DEPLOYER_ACCOUNT"
cast send "$CORE_RECEIVER" 'setExpectedAuthor(address)' "$WORKFLOW_AUTHOR" \
  --rpc-url "$ARBITRUM_RPC_URL" --account "$DEPLOYER_ACCOUNT"
cast send "$CORE_RECEIVER" 'setExpectedWorkflowName(string)' multyr-core-production \
  --rpc-url "$ARBITRUM_RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

For liquidity authorize selector `pokeLiquidityBatch(uint256,uint256)` on the **strategy**, and have
the strategy role admin grant its `KEEPER_ROLE` to that receiver. Under timelock ownership, encode the
call and schedule/execute through the timelock; an EOA `cast send` cannot bypass ownership. Do not grant
PARAM_ROLE or ownership for routine liquidity refreshes. The new receivers do not replace the existing
upkeep contracts in BufferManager/strategy role wiring.

The current receiver also supports `setConsumerGasLimit(address,bytes4,uint256)` and optional
`setBlockNumberCheck(address,bytes4,bool,uint256)`. Test stale/finalized-report behavior before enabling
monotonic checks. The current exact-ID setter is `setExpectedWorkflowId(bytes32)`; older prose examples
show a string, so use the ABI of the template version you actually deploy.

For the fee job, use the existing
[DeployFeeCollectorUpkeep.s.sol](../script/DeployFeeCollectorUpkeep.s.sol):
set FEE_COLLECTOR_ADDRESS to the supplied collector, VAULT_ADDRESS to the supplied CoreVault,
DISTRIBUTE_INTERVAL to the chosen seconds, TIMELOCK_ADDRESS to the confirmed governance owner.
Resolve periphery dependencies, dry-run on a fork, then deploy. Generate a CUSTOM workflow with the
resulting upkeep address. Register every intended token; the script adds only the vault share token.

### 4. Simulate, then activate

Within the CRE project, install dependencies in each generated job (`bun install`). Configure project RPCs
and workflow account settings using the official template. Simulate each job:

```sh
cre workflow simulate multyr-core --target=test-settings
cre workflow simulate multyr-strategy --target=test-settings
cre workflow simulate multyr-liquidity-0 --target=test-settings
# After fork validation, receiver authorization and measured gas checks:
cre workflow deploy multyr-core --target=production-settings
```

Repeat for every configured job. Simulation without broadcast is the first step; broadcast-enabled simulation
can write to mainnet. Production identity checks must match production workflow identity; use separate
simulation receivers if identities differ. Observe at least one needed and one no-work execution, verify
events AND state deltas, and then retire duplicate legacy schedulers if any exist.

## Deployed-system acceptance matrix

Automation runs maintenance; it does not create users, deposits, profits or every failure state.
Run adverse scenarios on a pinned fork of these exact deployed addresses. Existing fresh-deployment/mock tests
are regression coverage, not proof that the live installation is fully configured.

| Scenario | Assertions |
| --- | --- |
| No work | Both CUSTOM checks false when appropriate; no repeated chargeable no-op/failure loop |
| Deposit/mint | 6-decimal asset math, preview vs actual, min amounts/caps, fee destinations and share accounting |
| Core deploy → strategy deploy | Core hot/warm targets, routed funds, strategy idle reduction, each enabled adapter position/cap, conserved assets |
| Observation refresh | Aave rate updated; configured snapshots progress; TVL/capacity and liquidity timestamps advance for every adapter; failures remain visible |
| Harvest | Actual protocol rewards available, swap min-out/oracle/allowance, cooldown and profitability gates, post-harvest accounting |
| Rebalance | Prepare and every execution step, final plan cleared, realized amounts/slippage/caps, partial liquidity, expired/stuck/cancelled plan and another strategy not starved |
| Instant exit | Withdraw/redeem limits, hot then warm/strategy liquidity, fee math and correct receiver |
| Queued exit | Nonempty epoch closes once ready, locked PPS, partial funding, oldest outstanding cursor, fully funded claim, double claim rejected |
| Fee AUTO_HARVEST | Instant and queued paths, multiple outstanding epochs, funded claim harvested while another remains pending, minimum/dust and full-list deferral |
| Failure/backoff | Protocol revert and no liquidity, epoch stall yields priority, core failure backoff/recovery, pending reconciliation eventually drains |
| Security/control | Unauthorized roles, module direct calls, selector/wiring tampering, pause/unpause, timelock delay, bootstrap/seal replay |
| Oracle/adapters | Stale/missing data, depeg, sequencer outage where supported, adapter loss/zero liquidity, cash-vs-position divergence, disabled adapter with remaining position |
| Scheduler | Wrong author/name/ID/forwarder/selector rejected; stale/duplicate reports; insufficient gas/funds, RPC outage, task isolation, recovery and alert delivery |
| Long run | Every relevant opcode reached or justified as inapplicable; no claim/plan/cache starvation; worst funded gas fits limits; indexed accounting reconciles at finality |

For each case save chain ID, fork block/hash, source revision/runtime identity, pre/post state, transaction
hashes, decoded events, gas and assertion results. Track coverage per adapter and operation, not just a
single successful deposit. User claims and reward proofs remain user actions unless a separate relayer is designed.

## Existing tests and verification in this session

- Local setup-tool checks passed: CUSTOM and CRON configuration, unique workflow identity, refusal to
  overwrite an existing workflow, and exact 40-address offline inventory. These checks do not compile or execute the CRE SDK.
- Core `test/integration/Upkeep_Integration.t.sol`: **1 passed**.
- Core `test/unit/core/FeeCollectorHarvestQueue.t.sol`: **5 passed**.
- Strategies: `test/strategies/usdc-lending/LendingStrategyUpkeep.t.sol`, `UpkeepLiveness.t.sol`,
  `MultiStepRebalance.t.sol`, and `fork/ShadowDeploymentLifecycle.fork.t.sol` are relevant. Attempted upkeep
  run was blocked by sibling-repository cache write permissions; no passing claim is made.
- Periphery: `test/unit/periphery/PeripheryUpkeepAdapterV2.t.sol`, `FeeCollectorUpkeep.t.sol`,
  `FeeDistributorV2.t.sol`, `EpochPayout.t.sol`. Attempted upkeep run hit missing dependencies/remappings.
- At the initial inventory stage, CRE CLI/Bun simulation, receiver deployment, role grants, live RPC state verification, complete deployed-fork
  scenario tests, queued-fee conditional worker and alert delivery are **not completed**.

Subsequent VaultUpkeep setup verified live wiring, compiled the workflow, passed 54 receiver tests and
a due-action Arbitrum fork test; see [current status](../multyr-chainlink/SETUP-STATUS.md).

A later session added the mirrored `StrategyUpkeep` receiver deploy script, fork test, and `multyr-strategy`
CRE workflow folder (see [STRATEGY-SETUP-STATUS.md](../multyr-chainlink/STRATEGY-SETUP-STATUS.md)) but,
unlike the VaultUpkeep session, that session's environment could reach neither this machine's local
Foundry/CRE toolchain nor any external RPC or package-download host it tried (`foundry.paradigm.xyz`,
`github.com`, `arb1.arbitrum.io` were all blocked by its own egress policy). It verified the two new files
only with a standalone `solc 0.8.26` compile against the real, unmodified receiver and vendored OpenZeppelin
sources (zero errors) — it did **not** run `forge test`, did **not** query live chain state, and did **not**
find/pin a fork block with due StrategyUpkeep work. Treat `multyr-strategy` as unverified scaffolding, one
step behind `multyr-core`'s current state, until `forge test` is actually run against it locally.

This is a source-grounded job inventory and setup kit, not a claim that all 40 deployed contracts have passed
end-to-end tests. No onchain transactions or scheduler activations were made.
