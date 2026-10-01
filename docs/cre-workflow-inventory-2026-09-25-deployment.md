# CRE workflow inventory — Arbitrum deployment dated 25 September 2026

Reviewed 30 September 2026. Scope: the user's supplied 40-contract deployment, one USDC lending strategy, seven lending adapters, two warm adapters, and a claim-settlement upkeep. This is an architectural inventory, not an activation or deployed-bytecode audit.

## Evidence and limitations

- Address identity comes from the supplied deployment list. Explorer requests for the three upkeep contracts failed during this review; live bytecode, current roles, configuration, and automation registrations were not independently verified.
- Function behavior below comes from local source. The core, strategy, and periphery repositories contain uncommitted changes. Local function availability and behavior must be matched to deployed bytecode before execution.
- `readiness-20260928/activation/review-plan.json` and its README provide a later historical snapshot for these addresses: core paused, strategy not registered/allowlisted, warm-NAV refresh interval 600 seconds, Euler capacity zero, and fee shares not configured as AUTO_HARVEST. These are dated observations, not assertions about today's chain state.
- The prepared `multyr-core` and `multyr-strategy` CRE configurations point to the OLD upkeep addresses `0x8672921E03c9995AE1Dbe234A7a08C327163883e` and `0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550`. They are not ready for the supplied deployment. Receiver addresses and write gas limits remain zero.
- Neither an AutomationReceiver nor FeeCollectorUpkeep appears in the supplied 40 contracts. ClaimSettlementUpkeep DOES appear. The revised local FeeCollectorUpkeep is not evidence of a deployed fee automation contract.

## Primary workflow groups

These are six possible deployed programs, not a requirement to purchase six slots. Operations can share a workflow, and one workflow can process multiple contracts or adapter batches within tested execution limits. Module functions execute through the core/strategy vault's routing unless explicitly noted; do not target standalone delegatecall modules.

| ID | Group and correct target | Operations | Trigger/cadence design | Coverage/status |
|---|---|---|---|---|
| W1 | Core maintenance: VaultUpkeep `0x0196b1fd654fcC5A61fe6E9431b39Be88BB32FFE` | `checkUpkeep` / `performUpkeep`: close nonempty eligible epochs; fund older closed epochs; reconcile pending exits; crystallize performance fees; rebalance hot/warm reserves; deploy/realize strategy capital; conditional inter-strategy rebalance | User preference: weekly. Seven-day queue duration governs eligibility, not all core maintenance. A weekly single-action invocation is insufficient for timely close → fund → claim and continuous reserve maintenance. Use bounded follow-up runs or split fast maintenance from weekly epoch policy. | Upkeep is in supplied deployment. CRE template exists for old address. Core target is `0x70c8F05fC599e96D1BB9ce6e9dc3e1d72A9A3d01`. |
| W2 | Lending maintenance: StrategyUpkeep `0xA01Aa76C782569691Aaf6A0790124Bd3E5Ff3ee6` | Aave rate push; configured APY snapshots; external TVL/capacity refresh; eligible harvest; idle deployment; prepare and execute bounded rebalance steps | User preference: daily. Daily APY eligibility can consume each single-action run and starve other jobs. Multi-step plans also have expiry/cooldowns. A daily decision cycle needs timely continuation runs and independent cache freshness checks. | Upkeep is deployed; CRE template points to old address. Strategy vault is `0xCC4A4A4CbB5e041ffE6CAc44D6F7F84B6F6cAEf1`. No need for a harvest workflow per adapter. |
| W3 | Claim payouts: ClaimSettlementUpkeep `0xD8CE7eA661A7E818337ad87E7bb87b56871da14E` | Scan funded epochs, call `keeperSettleClaims`, pay recorded owners, advance cursor, retry failed claims | Start after epoch funding, then bounded catch-up batches plus periodic fallback. A funding event alone does not drain a large backlog. Local defaults: 20 claims, 200 scan probes per upkeep; actual deployed settings need confirmation. | Upkeep is in supplied deployment; no corresponding prepared CRE folder found. User self-claim remains possible. Settlement batches and ordinary self-claim are different functions. |
| W4 | Fee distribution and queued collection: FeeCollector `0x7976b59B66580e6340aC06Cf750e5C654DAa4B9a` | `distribute(coreShareToken)` and relevant underlying tokens; `harvestQueued(coreShareToken)` when pending claims become claimable or require cleanup after another keeper paid them | User preference: weekly distribution. Queue cleanup should follow funded/paid claims with fallback checks. Read balances, share mode, allowlists, minima, pause and claim readiness before writes. | No FeeCollectorUpkeep in supplied list. Can use a purpose-built CRE handler against permissionless collector methods, or separately deploy the revised upkeep. AUTO_HARVEST must be configured if that route is intended. One workflow can cover both actions and multiple tokens. |
| W5 | Lending liquidity observations: strategy vault | `pokeLiquidityBatch(start,end)` refreshes liquidity cache and eligible stability observations | Prior runbook proposes every 5 minutes; this is a starting proposal, not verified necessity. Set cadence from actual liquidity TTL, position sizes and failure margin. Process the current enabled adapter list in gas-bounded batches. | Not called by StrategyUpkeep's APY branch. One or several workflow slots depending on batching; seven adapters do not automatically mean seven slots. Receiver needs appropriate strategy KEEPER_ROLE for direct calls. |
| W6 | Warm-NAV freshness: BufferManager `0xeC5aa85dA559943420e1464F6bE5Ec44aCe157e1` | Read `warmNavState`, call permissionless `refreshWarmNav()` when needed, verify timestamp and validity | Freshness-based with margin, e.g. a 5-minute check against the historical 600-second refresh interval, after confirming actual thresholds. May share the W5 data-maintenance program or sufficiently frequent W1. | Source includes stale-NAV eligibility in buffer rebalance and automatic refresh on deposit/mint. Dedicated background refresh is useful for predictable readiness and user gas, not an unconditional separate-slot requirement. Failed adapter observations must surface as invalid NAV. |

## Conditional operations — combine with primary groups where appropriate

| Operation | Contract/function and permission | When it belongs in automation | Suggested grouping |
|---|---|---|---|
| Position accounting reconciliation | Strategy vault `shouldSyncPositionAssets`, `drift`, `syncPositionAssets()` / `syncPositionAsset(adapter)`; explicit methods require PARAM_ROLE. There is also a keeper-gated `syncPositionAssets(bool)` delegatecall path; verify selector routing. | Persistent drift or periods without paths that internally synchronize. Rebalance planning and idle deployment already synchronize in local source; avoid redundant writes. | W2/W5; monitor first. |
| Venus interest accrual | Venus adapter `accrueVenusInterest()` is permissionless | Before critical NAV-dependent operations where stored exchange-rate freshness matters. Check success and ordering; do not infer freshness solely from APY refresh. | W2/W5 preflight. |
| Morpho cached NAV | Morpho adapter `refreshNavCache()` is onlyVault; snapshots and several trading paths refresh internally | Only if cache maintenance is missing from configured normal paths. An external CRE receiver cannot directly bypass onlyVault. A supported strategy forwarding path is required. | W2 data maintenance, if necessary. |
| Dolomite rate-provider updates | `DolomiteSupplyRateProvider.setSupplyRatePerSecond(market,rate)` is onlyOwner; rate is WAD per second | Only when the adapter's active market/type actually consumes this optional provider. Need approved source, units, bounds, update policy, and authorized write architecture. Not included in existing APY upkeep. | Conditional rate-feed job; no automatic owner grant. |
| Adapter APY target coverage | Aave provider plus Morpho/Dolomite/Fluid snapshot functions and other configured targets | Verify the deployed pokeTargets and PARAM_ROLE grants; a deployed adapter is not automatically a configured target. Check each timestamp/failure, not only overall lastPokeTs. | W2, no slot per adapter. |
| Risk-score refresh | Strategy `setRiskScore(adapter,bps)` requires PARAM_ROLE | Only with an approved methodology and update cadence; monitor lastRiskScoreUpdateTs and configured staleness behavior. No autonomous risk policy currently established by this inventory. | Policy/data job or W5. |
| Regime updates | Strategy `setRegime(uint8)` requires KEEPER_ROLE | If a defined policy should switch stable/volatile/stress state. These influence behavior; do not invent a decision rule. | Approved policy job. |
| Registry metadata propagation | ProtocolRegistry governance updates; adapters expose `refreshFromRegistry()` on supported adapter types with parameter permissions | After approved market/cap/risk metadata changes, rather than an unconditional timer | Governance change-follow-up. |
| Strategy health status | StrategyHealthRegistry `setStrategyState` / `batchSetStrategyState`, owner or guardian; guardian cannot restore OK | Approved emergency policy or human decision. Read-only monitoring needs no such powers. | Optional safety-response workflow. |
| Last-known strategy NAV | StrategyHealthRegistry `updateLastKnownNAV`, authorized caller | Only if independent cache maintenance is justified; router already updates NAV in normal capital flows. Never supply an invented valuation. | Monitoring/W2 conditional. |
| Stalled plan cancellation | Strategy `cancelRebalancePlan()`, KEEPER_ROLE | A plan is stale/stuck and an explicit recovery policy permits cancellation; monitor plan age, progress and failure count | W2 recovery branch. |
| Emergency exits/sweeps | Router `withdrawAllToCore` is owner-only; strategy emergency operations require their specific roles; warm-adapter sweeps are controller-only | Incident handling, not routine yield maintenance. Compatibility and forwarding permissions must be verified; prior readiness notes flag emergency withdrawAll compatibility as unresolved. | Explicitly authorized recovery workflow, normally operator-driven. |
| Mature governance/recovery execution | GlobalConfig/AdminModule staged actions and RecoveryGate `execute` / `executeApproverChange` | Execute an already-approved exact proposal after delay and before expiry, subject to role, digest, veto and approval checks | Optional proposal executor; not an always-needed slot. |

## Monitoring (one logical group; CRE optional)

Monitor all primary workflow results and underlying state transitions; successful report delivery or transaction status alone may hide caught downstream failures. Cover funded/unfunded epoch age, claim backlog and retries, idle capital, stuck plans, per-adapter cache age, NAV drift, oracle freshness/depeg/sequencer dependencies where configured, roles and allowlists, pauses, workflow balances/billing, gas failures and parameter/registry/recovery changes. Source has failure events and some catch paths; aggregate success flags alone are inadequate.

A shared external monitoring service costs no CRE slot. If implemented in CRE, provision one or more workflows after measuring read-call limits, subscriptions and runtime across all 40 contracts; do not assume one run can individually query everything.

PriceOracleMiddleware reads external oracle feeds. No Multyr workflow should fabricate prices or rewrite feed timestamps; maintaining the upstream Chainlink feed is not our own keeper job.

## One-time setup and non-recurring contracts

Strategy allowlist execution, registration, caps, Euler capacity, fee share mode, permissions, sealing/freezing, and unpause readiness are setup/governance operations. Deployment factories and bootstrappers do not need recurring workflows just because they have addresses. Core and strategy modules share vault storage and are invoked through their vaults. User deposits/withdrawal requests are user transactions, not required CRE workflows. There is one strategy, so inter-strategy reallocation may currently have no useful work even though core supports it.

No rewards/Merkle distributor, fixed-maturity module/upkeep, safety-overflow module, external rebalance guard, or cross-chain bridge is established by this 40-address list. Do not budget their recurring workflows without additional deployment/configuration evidence. Old-vault claim migration is separate scope.

## Slot budget and implementation plan

Practical candidate layout: W1 core, W2 lending, W3 claims, W4 fees, and W5 combined lending-liquidity/warm-NAV data maintenance = **five workflow slots**, assuming tests establish that batching and capability limits permit this combination. Separating W6 yields **six**. CRE-based monitoring could add **one or more**; policy-specific or gas-driven splits add further slots. This is a proposed layout, not a count of active workflows or a guaranteed maximum.

At the user's quoted $30/slot/month: five slots = $1,800/year; six = $2,160; seven = $2,520. Execution at $0.0009/billed second and gas are additional credit consumption. Readiness-driven frequent maintenance and backlog continuation runs must be included; a weekly/daily business schedule alone is not a complete usage forecast. For example, one continuously running 5-minute data workflow adds 105,120 invocations/year, before claim catch-up and retries. Runtime remains unmeasured.

Before implementation: reconcile source against deployed code; read enabled lists, routed selectors, role grants, TTLs/cooldowns and fee mode; replace old targets in a reviewed configuration; fit worst-funded-state gas and read/write limits; benchmark idle and active paths; test failure isolation and catch-up; verify receiver workflow identity/allowlists and actual downstream caller permissions. No contract, CRE configuration, role, schedule or live state was changed by this review.

## Source references

- `multyr-core/src/automation/VaultUpkeep.sol` — core action selection/execution.
- `multyr-core/src/automation/ClaimSettlementUpkeep.sol` — scanning, batching, cursor and retries.
- `multyr-core/src/core/modules/EpochedQueueModule.sol` — epoch state and owner-directed payout.
- `multyr-core/src/core/modules/BufferManager.sol` and `ERC4626Module.sol` — background and automatic NAV refresh.
- `multyr-core/src/core/modules/FeeCollector.sol` and `multyr-periphery/src/periphery/automation/FeeCollectorUpkeep.sol` — fee distribution/queued cleanup; local upkeep is modified and absent from supplied deployment list.
- `multyr-strategies/src/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol` — priority selection and APY/TVL branch.
- Strategy controller modules: `StrategyParamsModule`, `StrategyAdapterOpsModule`, `StrategyRebalancePlanModule`, `StrategyScoringModule`, `StrategySettingsModule`.
- Strategy lending adapters and `adapters/rates/{AaveLiquidityRateProvider,DolomiteSupplyRateProvider}.sol`.
- `readiness-20260928/activation/README.md` and `review-plan.json` — historical deployment-specific checks.

## All 40 supplied contracts

The mapping below assigns operational coverage, not one CRE slot per row.

| # | Contract | Address | Workflow coverage |
|---|---|---|---|
| 1 | AaveV3WarmAdapter_USDC | `0x03d18504Fe39007cebc8d288CB5734826D13dB5d` | W1/W6: reserve investment and warm NAV; controller-only operations, no separate keeper slot. |
| 2 | AdminModule | `0xa5DCdFE5EADefc996AfafCE1CB14eCf17710721a` | Approved setup/parameter changes through core; monitoring. No recurring slot. |
| 3 | BufferManager | `0xeC5aa85dA559943420e1464F6bE5Ec44aCe157e1` | W1 reserve rebalance; W6 warm NAV freshness. |
| 4 | ERC4626Module | `0x99FA9D0eB86Ca2a2e8D3A32b7568cF9521c81f84` | User deposit/withdraw paths; automatic NAV refresh; no separate CRE slot. |
| 5 | FeeCollector | `0x7976b59B66580e6340aC06Cf750e5C654DAa4B9a` | W4 fee distribution and queued collection. |
| 6 | GlobalConfig | `0x04BA2Be680710B3Fae236bbFe18A5890A3829f98` | Approved delayed configuration and strategy allowlist changes; monitoring. |
| 7 | StrategyHealthRegistry | `0x76C1f6c2AA37500E462543eCF28a52838A91eCf0` | Monitoring; conditional approved health/NAV updates. |
| 8 | LiquidityOpsModule | `0x282194B96c3F6ebBE3933bfF0eFb60CdEca95838` | W1 capital deployment/recall/rebalance, through core. |
| 9 | MorphoVaultWarmAdapter_USDC | `0x456F5f72882434CB13735e46381907010BEA1d80` | W1/W6 reserve and NAV coverage. Local source filename MorphoBlueWarmAdapter_USDC.sol; deployed label differs, verify source match. |
| 10 | PriceOracleMiddleware | `0x775B60e355A66b45D8d89b2DDe8D806d48e3C958` | Monitoring of feed freshness/validity; no Multyr price-publishing job. |
| 11 | EpochedQueueModule | `0x97a61f826352C93add598eD4e8d0A3a5F7D481B5` | W1 close/fund/reconcile; W3 funded claim payouts, through core. |
| 12 | RecoveryGate | `0x93043838B62Ba89ae09Be499baF25Fb96e969De8` | Approved delayed recovery/proposal execution and monitoring; no normal maintenance timer. |
| 13 | SelectorRegistry | `0xa91E4900bFE244515EaFd7e5Ba7c75dE197AB93a` | Routing setup/recovery and monitoring; no recurring slot. |
| 14 | StrategyRouter | `0x9E3C383092bd98Ce6b821Db5dD51fC5A9ccb231E` | W1 capital movements; health NAV updates; conditional approved emergency recovery. |
| 15 | SystemSealer | `0xC8De5fCde3e6a75c56AE16182f2032fb074d65B4` | One-time seal/freeze operations and monitoring; no recurring slot. |
| 16 | VaultUpkeep | `0x0196b1fd654fcC5A61fe6E9431b39Be88BB32FFE` | W1 main entry point. |
| 17 | CoreVault | `0x70c8F05fC599e96D1BB9ce6e9dc3e1d72A9A3d01` | W1/W3 routed core operations; user transactions; W4 fee share token. |
| 18 | VaultFactory | `0xa762B044C216c699A0bB1d0B7eA169a1716EB62d` | Vault deployment/setup; no recurring slot. |
| 19 | AaveV3USDCAdapter | `0x8b2Ca25cE2670D1e37037AD3b1fFb06B7Df793fe` | W2 strategy operations/rate coverage; W5 liquidity; no per-adapter slot requirement. |
| 20 | AaveLiquidityRateProvider | `0x6f9b6A062d0C1bcb92B3b0385868a132BfBe2923` | W2 Aave rate updates if configured and authorized. |
| 21 | AdapterFactory | `0x3FEe7E69b6836b69bb964e4959063B60F66A1982` | Adapter deployment/setup; no recurring slot. |
| 22 | StrategyAdapterOpsModule | `0x2901a188B2EeeE1D08B9CAA9731c982e72CA3fbe` | W2 internal adapter operations and sync via strategy; no direct module workflow. |
| 23 | StrategyAllocCalcModule | `0x37A1b4bf8CE2f74718ca298A7AA3a71F16b543cE` | W2 allocation computation, consumes W5 cache; no independent scheduled computation needed. |
| 24 | StrategyBootstrapper | `0xaF26a2eBC5b87be97A325C573A78B5A50e8A18f9` | Initial strategy/adapter wiring; no recurring slot. |
| 25 | CometUsdcMultiMarketAdapter | `0x96d5F520e1b1E046aB4417867d63FCcc59467432` | W2 operations; W5 liquidity; optional approved registry metadata refresh. |
| 26 | DolomiteUsdcMultiMarketAdapter | `0x2aa571DA63893C265bB1F0d43DF1070ce691a303` | W2 operations/APY snapshots; W5 liquidity; conditional rate provider and metadata refresh. |
| 27 | DolomiteSupplyRateProvider | `0x333141aB6950306e61B462242C66D4fc0A9C544D` | Conditional owner-authorized rate feed only if actively used. |
| 28 | EulerUsdcMultiMarketAdapter | `0x01e380438C013211A4f27A80cE316E0144cF1233` | W2 operations; W5 liquidity; finite capacity/configuration readiness and optional metadata refresh. |
| 29 | FluidUsdcMultiMarketAdapter | `0xc0FD5677823c8dB31E87C0B7384fcF580987C4c7` | W2 operations/APY snapshots if configured; W5 liquidity. |
| 30 | MorphoUsdcMultiMarketAdapter | `0x9493400E0c861774f4e264492E658805B58F8Ba2` | W2 operations/APY snapshots/cached NAV; W5 liquidity; optional metadata refresh. |
| 31 | StrategyParamsModule | `0x37E2777453Db321813cC454B1D4F53aEd90B7f96` | W5 liquidity/TVL/position maintenance through strategy; W2 already covers configured TVL pokes. |
| 32 | ProtocolRegistry | `0x35C60279Ef3d8D0E904f094c094654AB23DCEE6f` | Governance-approved market/cap/risk metadata; monitor and conditionally propagate updates. |
| 33 | StrategyRebalanceGateModule | `0xB6359AaF920B6879f54B1fa490Ea2d8F0a4BfFd1` | W2 internal eligibility checks; no standalone recurring slot. |
| 34 | StrategyRebalancePlanModule | `0x6f06351DE9c6C0575C40BA5EaE881fB1E2d38Ea9` | W2 prepare/execute; conditional cancellation through strategy. |
| 35 | StrategyScoringModule | `0xD163A33FA5DA94109eFeC3eC65e7a252b415156A` | W2 scoring/deploy-idle/sync; no independent keeper per scoring function. |
| 36 | StrategySettingsModule | `0xc2cfC76C3a03d2D3A71065Fa64D6e2281cf1bD3c` | Approved settings/risk/regime/emergency policy operations through strategy. |
| 37 | UsdcMultiLendingVault | `0xCC4A4A4CbB5e041ffE6CAc44D6F7F84B6F6cAEf1` | W2/W5 main strategy target and delegatecall router. |
| 38 | StrategyUpkeep | `0xA01Aa76C782569691Aaf6A0790124Bd3E5Ff3ee6` | W2 main entry point. |
| 39 | ClaimSettlementUpkeep | `0xD8CE7eA661A7E818337ad87E7bb87b56871da14E` | W3 main entry point; exists in this deployment. |
| 40 | VenusUsdcMultiMarketAdapter | `0xC9c1c7257Ab5161c4E77C10a26544b0B11d3419b` | W2 operations; W5 liquidity; conditional interest accrual before NAV-sensitive operations. |
