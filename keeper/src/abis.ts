import { parseAbi } from "viem";

// Minimal ABIs, copied from the Arbiscan/Sourcify-verified sources of the
// 2026-09-25 Arbitrum One deployment. Only what the keeper reads or calls.

/** Chainlink-compatible upkeep surface shared by VaultUpkeep, StrategyUpkeep, ClaimSettlementUpkeep. */
export const automationAbi = parseAbi([
  "function checkUpkeep(bytes checkData) view returns (bool upkeepNeeded, bytes performData)",
  "function performUpkeep(bytes performData)",
]);

/** W1 — VaultUpkeep (src/automation/VaultUpkeep.sol). */
export const vaultUpkeepAbi = parseAbi([
  "function checkUpkeep(bytes checkData) view returns (bool upkeepNeeded, bytes performData)",
  "function performUpkeep(bytes performData)",
  "function getCore() view returns (address)",
  "function consecutiveFailures() view returns (uint8)",
  "function failureThreshold() view returns (uint8)",
  "function lastFailureTs() view returns (uint64)",
  "function failureBackoffSeconds() view returns (uint32)",
  "event UpkeepPerformed(uint8 op, uint256 arg, bool success)",
  "event UpkeepBackoffEntered(uint8 failures)",
]);

/** VaultUpkeep `Op` enum, index-aligned with the contract. */
export const VAULT_OPS = [
  "NONE",
  "EPOCH_CLOSE",
  "EPOCH_FUND",
  "CRYSTALLIZE",
  "REBALANCE",
  "DEPLOY",
  "REALIZE",
  "RECONCILE",
  "STRATEGY_REBALANCE",
] as const;

/** W2 — StrategyUpkeep (LendingStrategyUpkeep.sol). */
export const strategyUpkeepAbi = parseAbi([
  "function checkUpkeep(bytes checkData) view returns (bool upkeepNeeded, bytes performData)",
  "function performUpkeep(bytes performData)",
  "function strategiesLength() view returns (uint256)",
  "function getStrategy(uint256 index) view returns (address)",
  "function enabled(address) view returns (bool)",
  "function getPokeTargets() view returns (address[])",
  "function lastPokeTs() view returns (uint64)",
  "function pokeInterval() view returns (uint64)",
  "event UpkeepPerformed(uint8 indexed op, address indexed strategy, uint256 timestamp)",
  "event UpkeepErrored(uint8 indexed op, address indexed strategy, bytes reason)",
  "event SnapshotPokeFailed(address indexed target, bytes reason)",
  "event ExternalTVLPokeFailed(address indexed strategy, bytes reason)",
  "event ExternalCallFailed(address indexed target, bytes4 indexed selector, uint256 timestamp, bytes data)",
]);

/** StrategyUpkeep opcodes, keyed by value. */
export const STRATEGY_OPS: Record<number, string> = {
  1: "HARVEST",
  2: "REBALANCE",
  3: "POKE_APY",
  4: "DEPLOY_IDLE",
  5: "PREPARE_REBALANCE",
  6: "EXECUTE_REBALANCE_STEP",
};

/** W3 — ClaimSettlementUpkeep. performUpkeep ignores performData and rescans on-chain. */
export const claimUpkeepAbi = parseAbi([
  "function checkUpkeep(bytes checkData) view returns (bool upkeepNeeded, bytes performData)",
  "function performUpkeep(bytes performData)",
  "function target() view returns (address)",
  "function maxClaimsPerUpkeep() view returns (uint256)",
  "function maxScanPerUpkeep() view returns (uint256)",
  "event UpkeepPerformed(uint256 indexed epochId, uint256 claimCount, uint256 totalSettled, bool success)",
  "event ClaimSettlementFailed(uint256 indexed epochId, uint256 indexed claimId, uint256 retryAt)",
]);

/** W4 — FeeCollector (src/core/modules/FeeCollector.sol). Both writes are permissionless. */
export const feeCollectorAbi = parseAbi([
  "function distribute(address token)",
  "function harvestQueued(address token)",
  "function paused() view returns (bool)",
  "function shareConfigs(address) view returns (bool isSet, uint8 mode, address underlying)",
  "function pendingHarvestClaimCount(address token) view returns (uint256)",
  "function pendingHarvestShares(address) view returns (uint256)",
  "function allowlistEnabled() view returns (bool)",
  "function allowedToken(address) view returns (bool)",
  "function minDistribution(address) view returns (uint256)",
  "event Distributed(address indexed token, uint256 total, uint256 toTreasury, uint256 toOps, uint256 toSafetyReserve)",
  "event Harvested(address indexed shareToken, address indexed underlying, uint256 sharesIn, uint256 assetsOut)",
  "event HarvestQueued(address indexed token, uint256 shares)",
  "event HarvestDeferred(address indexed token, uint256 shares, string reason)",
  "event HarvestSettled(address indexed token, address indexed underlying, uint256 sharesRedeemed, uint256 underlyingOut)",
  "event HarvestClaimNotReady(address indexed token, uint256 epochId, uint256 claimId)",
  "event HarvestDustBurned(address indexed token, uint256 shares)",
]);

export const SHARE_MODES = ["SPLIT_SHARES", "HOLD_TO_TREASURY", "AUTO_HARVEST"] as const;

/** W5 — strategy vault (UsdcLendingStrategy + StrategyParamsModule via fallback routing). */
export const strategyVaultAbi = parseAbi([
  "function pokeLiquidityBatch(uint256 start, uint256 end)",
  "function adapterCount() view returns (uint256)",
  "function adapters(uint256) view returns (address)",
  "function enabled(address) view returns (bool)",
  "function quarantined(address) view returns (bool)",
  "function cachedLiquidityTs(address) view returns (uint64)",
  "function liquidityStalenessSeconds() view returns (uint32)",
  "function KEEPER_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function paused() view returns (bool)",
  "event AdapterCallFailed(address indexed adapter, bytes4 indexed selector, uint256 timestamp, bytes data)",
]);

/** W6 — BufferManager. refreshWarmNav() is permissionless. */
export const bufferManagerAbi = parseAbi([
  "function warmNavState() view returns (uint256 nav, uint40 ts, bool valid)",
  "function navRefreshInterval() view returns (uint32)",
  "function refreshWarmNav()",
  "function core() view returns (address)",
  "event WarmNavCacheUpdated(uint256 warmNav, uint40 timestamp, bool valid)",
  "event WarmNavAdapterFailed(address indexed adapter, bool success, bytes data)",
]);
