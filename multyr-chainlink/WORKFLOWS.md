# Multyr CRE workflows — September 25 deployment

This suite extends the existing CRE project; it is not a new project scaffold. The older `multyr-core/` and `multyr-strategy/` migration examples and their deployment scripts remain untouched and target a different deployment. Do not use their hardcoded deployment scripts for this suite.

`workflow-catalog.json` records the 40 supplied addresses and each new workflow. Contract addresses are from the user's deployment list, not a fresh live verification. All targets currently use Arbitrum MAINNET, including `simulation-settings`; the latter is not a testnet. No workflow was deployed, activated, funded or granted permissions.

## Included workflows

| Folder under `workflows/` | Initial mode | Trigger(s), UTC | Behavior |
|---|---|---|---|
| multyr-core-v2 | preview | Monday 00:00; optional 10-minute catch-up disabled | Checks NEW VaultUpkeep `0x0196…2FFE`; previews one selected operation. |
| multyr-lending-v2 | preview | Daily 00:00; optional catch-up disabled | Checks NEW StrategyUpkeep `0xA01A…3ee6`; previews one selected operation. |
| multyr-claims | preview | Every 10 minutes | Checks deployed ClaimSettlementUpkeep; existing contract controls batches, cursor, retries and owner-directed payouts. |
| multyr-fees | preview | Weekly share distribution; ten-minute queued cleanup | Separate handlers, one workflow. Direct collector calls with pause/balance/queue guards. In live mode, eth_call preflight checks full target conditions before report submission. |
| multyr-liquidity | preview | Seven staggered handlers every 5 minutes | One enabled-list index per handler. One slot if deployed once, but seven invocations per cycle; remove unused handlers and validate enabled-list indices. |
| multyr-warm-nav | preview | Every 5 minutes | Calls permissionless refreshWarmNav; monitor validity separately. |
| multyr-monitor | preview/read-only | Every 5 minutes | Eleven bounded observations: pauses, warm NAV validity, claim counts, strategy phase/APY timestamp and fees. Structured logs/return values only. |
| multyr-position-sync | disabled, preview-only | Daily review | Position drift and configurable sync proposal. |
| multyr-adapter-accrual | disabled, preview-only | Daily review | Venus accrual / Morpho cache proposals; Morpho onlyVault requires a legitimate strategy forwarding path. |
| multyr-rate-feed | disabled, preview-only | Daily review | Dolomite optional rate-provider proposal; source, market, rate and ownership policy not invented. |
| multyr-risk-policy | disabled, preview-only | Daily review | Risk-score and regime proposals; no automatic risk model. |
| multyr-registry-sync | disabled, preview-only | Daily review | Adapter metadata refresh after approved registry changes. |
| multyr-health-policy | disabled, preview-only | Daily review | Health-state proposal; owner/guardian policy still required. |
| multyr-plan-recovery | disabled, preview-only | Daily review | Observe phase and preview approved cancellation. |
| multyr-emergency | disabled, preview-only | Daily review | Emergency withdrawal/pull proposals; compatibility and authority must be verified. |
| multyr-governance | disabled, preview-only | Daily review | Recovery/approver execution proposals; exact approvals, digest and timing policy required. |

Sixteen folders are alternatives/candidates, NOT a recommendation to activate sixteen paid slots. Factories, bootstrap contracts, read-only calculation modules, and user-initiated deposits do not get dummy workflows. Optional proposals with disabled actions and zero/example arguments are NOT executable policy implementations. Policy kind rejects `mode: live` in code; developing approved bounded execution policies is separate work requiring the missing policy inputs.

Weekly means Monday 00:00 UTC, a selected wall-clock anchor, not seven days from deployment. Core and strategy catch-up handlers are supplied but disabled so the requested cadence is not silently changed. A weekly core run only selects one operation. A daily lending run can repeatedly select APY and starve harvest/rebalance. Review catch-up before launch; a multi-step rebalance can expire between daily runs. Fee cleanup is deliberately independent of weekly distribution. Claim polling, liquidity and NAV cadences are proposed defaults, not confirmed production requirements.

## Shared engine and write boundary

`suite/engine.ts` contains testable planning and guards; `suite/runtime.ts` supplies CRE cron handlers, finalized EVM reads, signed report delivery and read-budget enforcement. Inputs use decimal strings for integers. Each invocation pins a finalized block and spends at most 15 EVM reads (including header and write preflight). One invocation sends at most one report. No loop assumes an earlier write is immediately visible in finalized state.

- **disabled:** no capability calls from the handler. Do not deploy unused workflows: slots/triggers still cost money.
- **preview:** reads/guards and calldata output only; no report generation or write submission. This does NOT prove the proposed transaction succeeds, particularly when role-bearing calls have no receiver yet.
- **live:** requires `deploymentVerified: true`, a nonzero receiver and measured positive gas budget (at most the current 10M EVM quota). The target call is simulated with the receiver as caller before sending. This flag is an operator attestation, not an automated bytecode check.
- **policy-preview:** cannot run live. Enable individual actions only after replacing example inputs to review their calldata.
- **monitor:** reads only in every mode. Logs are not email/Slack alerts; connect external log ingestion and alert delivery separately. Timestamp observations require external freshness thresholds; this is baseline telemetry, not complete 40-contract monitoring.

Reports encode `(target, finalizedBlockNumber, calldata)` for the existing AutomationReceiver. Configure forwarder and workflow identity, exact target/selector allowlists, consumer gas guards, ownership and block staleness settings before use. Direct strategy calls need receiver KEEPER_ROLE (or other exact role); calls via existing upkeep retain that upkeep's downstream roles. Never grant a generic workflow owner/guardian powers merely to satisfy a template.

Off-chain guards/preflight are not atomic with final delivery. Targets must enforce safety at execution, and sensitive policy actions need on-chain proposal identity/expiry protections. Report transaction success is logged as `report-delivered-verify-target-events`: the receiver/upkeeps can catch failures, so underlying events and state progress must be checked independently. An uncertain report submission aborts execution; read/preflight failures are explicitly reported. Next scheduled execution rechecks chain state.

The fee workflow uses existing permissionless collector functions, not an undeployed FeeCollectorUpkeep. Verify deployed AUTO_HARVEST semantics and queued cleanup behavior before live use. Very large fee queues require an appropriate gas plan or contract changes; the handler does not make an unbounded collector loop cheap.

## Local validation

Install the root locked dependencies with `npm ci` (or the corresponding Bun install). During development this checkout can reuse the existing `multyr-core/node_modules` through an ignored root symlink. Dependencies and lockfile are copied from the existing migration project; no secrets are required for these checks.

```sh
cd multyr-periphery/multyr-chainlink
bun run typecheck
bun run test
bun run validate
```

Run CRE simulation from this project root after ensuring CLI/Bun are on PATH:

```sh
cre workflow simulate workflows/multyr-claims --target simulation-settings --non-interactive --trigger-index 0
```

Do not add `--broadcast`. Simulation still needs working RPC/CRE service access. For multi-trigger workflows choose the intended enabled handler index. Production and simulation configs start as identical non-broadcast previews; edit them independently as appropriate. CRE deployment remains separate from compilation and tests.

## Activation prerequisites

1. Match local ABI/function behavior to these deployed contracts; resolve paused/registration/Euler-cap readiness separately.
2. Verify each target's roles, fee mode, enabled-list membership, freshness bounds and cooldowns. Trim unsupported actions/handlers.
3. Decide actual cadences and catch-up policies. Benchmark no-work, successful, failed, and worst-funded-state paths.
4. Provision and configure receiver(s) with correct identities, exact allowlists and measured gas; verify permissions at immediate callers.
5. Test live-equivalent behavior on a fork and CRE simulation, including duplicate triggers, stale checks, queue failures and partial claim batches.
6. Configure independent receipt/state monitoring. Only then consider enabling mode live and activating selected workflows.

See `../docs/cre-workflow-inventory-2026-09-25-deployment.md` for the full contract mapping and conditional workflow rationale.

## Verification performed

- TypeScript compilation of every new entry point and the shared runtime passes.
- 13 engine tests cover disabled/preview behavior, no-work decisions, malformed responses, write prerequisites, one-write bounds, trigger isolation, guard failures, simulation failures, uncertain delivery, policy-write rejection, monitoring and exact large integers.
- All 32 production/simulation configs validate, with targets checked against the 40-address inventory.
- The shared workflow runtime compiled to WASM through the `multyr-claims` entry point using the installed CRE SDK/Javy toolchain; all entry points delegate to that same runtime.
- A non-broadcast CRE simulation of the disabled governance workflow was attempted but stopped before execution: CLI credential refresh could not resolve `login.chain.link`. No end-to-end CRE simulation, live RPC validation, gas benchmark, or mainnet transaction was completed. This suite is not production-validated.
