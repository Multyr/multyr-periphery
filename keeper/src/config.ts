import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { getAddress, type Address } from "viem";

// Chain config (addresses, cadences) lives in a JSON file per chain and is
// public. Everything that differs between the primary and secondary bot
// (instance role, RPC, signer, alerting) comes from the environment.

export type Instance = "primary" | "secondary";

interface JobBase {
  id: string;
  /** How often the job's on-chain condition is evaluated (eth_call only, no gas). */
  pollSec: number;
  /** Secondary only: how long a condition must stay due before the secondary acts. */
  secondaryGraceSec: number;
  enabled?: boolean;
}

export interface UpkeepJobConfig extends JobBase {
  type: "upkeep";
  /** Selects event decoding; on-chain semantics are identical (check → perform). */
  flavor: "vault" | "strategy" | "claims";
  target: Address;
  /** Bounded follow-up: max performUpkeep txs per tick while checkUpkeep stays true. */
  maxActionsPerTick: number;
}

export interface FeeCollectorJobConfig extends JobBase {
  type: "feeCollector";
  target: Address;
  /** Tokens to call distribute(token) on, inside the distribution window. */
  distributeTokens: Address[];
  /** AUTO_HARVEST share tokens to call harvestQueued(token) on whenever claims are ready. */
  harvestQueuedTokens: Address[];
  /** Weekly window, UTC. distribute() is only attempted inside it. */
  distributeWindow: { weekday: number; hourUtc: number; durationHours: number };
}

export interface LiquidityJobConfig extends JobBase {
  type: "liquidity";
  strategyVault: Address;
  /** Enabled-adapter indices per pokeLiquidityBatch tx (gas bound). */
  batchSize: number;
  /** Refresh this many seconds before liquidityStalenessSeconds expires. */
  refreshMarginSec: number;
  /** Used only if the vault reports liquidityStalenessSeconds() == 0. */
  fallbackMaxAgeSec: number;
}

export interface WarmNavJobConfig extends JobBase {
  type: "warmNav";
  bufferManager: Address;
  /** Refresh this many seconds before navRefreshInterval expires. */
  refreshMarginSec: number;
}

export type JobConfig = UpkeepJobConfig | FeeCollectorJobConfig | LiquidityJobConfig | WarmNavJobConfig;

export interface ChainConfig {
  network: string;
  chainId: number;
  /** Hard cap; a tx is not sent while the network base fee is above it. */
  maxFeePerGasGwei: number;
  txReceiptTimeoutSec: number;
  minKeeperBalanceEth: number;
  /** Reference addresses used by preflight cross-checks. */
  addresses: Record<string, Address>;
  jobs: JobConfig[];
}

export interface RuntimeEnv {
  instance: Instance;
  rpcUrls: string[];
  signer: "local" | "aws-kms" | "gcp-kms" | "none";
  privateKey?: `0x${string}`;
  awsKmsKeyId?: string;
  gcpKmsKeyName?: string;
  alertWebhookUrl?: string;
  port?: number;
  jobFilter?: Set<string>;
}

export interface Config {
  chain: ChainConfig;
  env: RuntimeEnv;
}

function fail(msg: string): never {
  throw new Error(`config: ${msg}`);
}

function num(v: unknown, path: string, min = 0): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v < min) fail(`${path} must be a number >= ${min}`);
  return v;
}

function addr(v: unknown, path: string): Address {
  if (typeof v !== "string") fail(`${path} must be an address`);
  try {
    return getAddress(v);
  } catch {
    fail(`${path} is not a valid address: ${v}`);
  }
}

function addrList(v: unknown, path: string): Address[] {
  if (!Array.isArray(v)) fail(`${path} must be an array of addresses`);
  return v.map((x, i) => addr(x, `${path}[${i}]`));
}

export function parseChainConfig(raw: any): ChainConfig {
  const seen = new Set<string>();
  const jobs: JobConfig[] = (raw.jobs ?? []).map((j: any, i: number): JobConfig => {
    const p = `jobs[${i}]`;
    if (typeof j.id !== "string" || !j.id) fail(`${p}.id required`);
    if (seen.has(j.id)) fail(`duplicate job id ${j.id}`);
    seen.add(j.id);
    const base = {
      id: j.id,
      pollSec: num(j.pollSec, `${p}.pollSec`, 10),
      secondaryGraceSec: num(j.secondaryGraceSec, `${p}.secondaryGraceSec`),
      enabled: j.enabled !== false,
    };
    switch (j.type) {
      case "upkeep":
        if (!["vault", "strategy", "claims"].includes(j.flavor)) fail(`${p}.flavor must be vault|strategy|claims`);
        return {
          ...base,
          type: "upkeep",
          flavor: j.flavor,
          target: addr(j.target, `${p}.target`),
          maxActionsPerTick: num(j.maxActionsPerTick, `${p}.maxActionsPerTick`, 1),
        };
      case "feeCollector": {
        const w = j.distributeWindow ?? {};
        return {
          ...base,
          type: "feeCollector",
          target: addr(j.target, `${p}.target`),
          distributeTokens: addrList(j.distributeTokens ?? [], `${p}.distributeTokens`),
          harvestQueuedTokens: addrList(j.harvestQueuedTokens ?? [], `${p}.harvestQueuedTokens`),
          distributeWindow: {
            weekday: num(w.weekday, `${p}.distributeWindow.weekday`),
            hourUtc: num(w.hourUtc, `${p}.distributeWindow.hourUtc`),
            durationHours: num(w.durationHours, `${p}.distributeWindow.durationHours`, 1),
          },
        };
      }
      case "liquidity":
        return {
          ...base,
          type: "liquidity",
          strategyVault: addr(j.strategyVault, `${p}.strategyVault`),
          batchSize: num(j.batchSize, `${p}.batchSize`, 1),
          refreshMarginSec: num(j.refreshMarginSec, `${p}.refreshMarginSec`),
          fallbackMaxAgeSec: num(j.fallbackMaxAgeSec, `${p}.fallbackMaxAgeSec`, 60),
        };
      case "warmNav":
        return {
          ...base,
          type: "warmNav",
          bufferManager: addr(j.bufferManager, `${p}.bufferManager`),
          refreshMarginSec: num(j.refreshMarginSec, `${p}.refreshMarginSec`),
        };
      default:
        fail(`${p}.type unknown: ${j.type}`);
    }
  });

  const addresses: Record<string, Address> = {};
  for (const [k, v] of Object.entries(raw.addresses ?? {})) addresses[k] = addr(v, `addresses.${k}`);

  return {
    network: String(raw.network ?? fail("network required")),
    chainId: num(raw.chainId, "chainId", 1),
    maxFeePerGasGwei: num(raw.maxFeePerGasGwei, "maxFeePerGasGwei"),
    txReceiptTimeoutSec: num(raw.txReceiptTimeoutSec, "txReceiptTimeoutSec", 10),
    minKeeperBalanceEth: num(raw.minKeeperBalanceEth, "minKeeperBalanceEth"),
    addresses,
    jobs,
  };
}

export function parseEnv(env: NodeJS.ProcessEnv, requireSigner: boolean): RuntimeEnv {
  const instance = env.KEEPER_INSTANCE;
  if (instance !== "primary" && instance !== "secondary") fail("KEEPER_INSTANCE must be primary|secondary");

  const rpcUrls = (env.RPC_URLS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (rpcUrls.length === 0) fail("RPC_URLS required (comma-separated; first is preferred)");

  const signer = (env.SIGNER ?? (requireSigner ? "" : "none")) as RuntimeEnv["signer"];
  if (!["local", "aws-kms", "gcp-kms", "none"].includes(signer)) fail("SIGNER must be local|aws-kms|gcp-kms");
  if (requireSigner && signer === "none") fail("SIGNER required for modes that send transactions");
  if (signer === "local" && !/^0x[0-9a-fA-F]{64}$/.test(env.KEEPER_PRIVATE_KEY ?? ""))
    fail("KEEPER_PRIVATE_KEY (0x-prefixed, 32 bytes) required for SIGNER=local");
  if (signer === "aws-kms" && !env.AWS_KMS_KEY_ID) fail("AWS_KMS_KEY_ID required for SIGNER=aws-kms");
  if (signer === "gcp-kms" && !env.GCP_KMS_KEY_NAME) fail("GCP_KMS_KEY_NAME required for SIGNER=gcp-kms");

  return {
    instance,
    rpcUrls,
    signer,
    privateKey: env.KEEPER_PRIVATE_KEY as `0x${string}` | undefined,
    awsKmsKeyId: env.AWS_KMS_KEY_ID,
    gcpKmsKeyName: env.GCP_KMS_KEY_NAME,
    alertWebhookUrl: env.ALERT_WEBHOOK_URL || undefined,
    port: env.PORT ? Number(env.PORT) : undefined,
    jobFilter: env.JOBS ? new Set(env.JOBS.split(",").map((s) => s.trim()).filter(Boolean)) : undefined,
  };
}

export function loadConfig(requireSigner: boolean): Config {
  const path = resolve(process.env.KEEPER_CONFIG ?? new URL("../config/arbitrum-one.json", import.meta.url).pathname);
  const chain = parseChainConfig(JSON.parse(readFileSync(path, "utf8")));
  const env = parseEnv(process.env, requireSigner);
  if (env.jobFilter) {
    for (const id of env.jobFilter) if (!chain.jobs.some((j) => j.id === id)) fail(`JOBS references unknown job ${id}`);
  }
  return { chain, env };
}
