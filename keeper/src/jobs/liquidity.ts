import { parseEventLogs, type Address, type Hex } from "viem";
import { strategyVaultAbi } from "../abis.ts";
import type { LiquidityJobConfig } from "../config.ts";
import { alert, log } from "../log.ts";
import { sameAddress, type Job, type JobContext, type PreflightCheck, type TickResult } from "./types.ts";

// W5 — strategy vault pokeLiquidityBatch(start, end).
//
// Routed through the vault's fallback to StrategyParamsModule; requires
// KEEPER_ROLE on the strategy vault for the keeper address itself (this is
// the only workflow that is not behind an upkeep contract or permissionless).
//
// Indices are positions in the *enabled, non-quarantined* adapter list, which
// we reconstruct exactly as _enabledAdapters() does. Rather than a blind
// 5-minute timer, a batch is poked only when one of its adapters' cached
// liquidity is within refreshMarginSec of the vault's own staleness limit.

export interface AdapterState {
  adapter: Address;
  cachedTs: number;
}

/** Batches [start, end) over the enabled list that contain at least one adapter due by `now`. */
export function dueBatches(adapters: AdapterState[], now: number, maxAge: number, margin: number, batchSize: number) {
  const out: { start: number; end: number; dueSince: number }[] = [];
  for (let start = 0; start < adapters.length; start += batchSize) {
    const slice = adapters.slice(start, start + batchSize);
    const dueAts = slice.map((a) => a.cachedTs + maxAge - margin).filter((d) => now >= d);
    if (dueAts.length) out.push({ start, end: start + slice.length, dueSince: Math.min(...dueAts) });
  }
  return out;
}

export class LiquidityJob implements Job {
  readonly id: string;
  readonly pollSec: number;
  private readonly cfg: LiquidityJobConfig;

  constructor(cfg: LiquidityJobConfig) {
    this.cfg = cfg;
    this.id = cfg.id;
    this.pollSec = cfg.pollSec;
  }

  private async enabledAdapters(chain: JobContext["chain"]): Promise<AdapterState[]> {
    const v = this.cfg.strategyVault;
    const n = Number(await chain.read<bigint>(v, strategyVaultAbi, "adapterCount"));
    const all = (await chain.pub.multicall({
      allowFailure: false,
      contracts: Array.from({ length: n }, (_, i) => ({
        address: v,
        abi: strategyVaultAbi,
        functionName: "adapters",
        args: [BigInt(i)],
      })),
    })) as Address[];
    const flags = (await chain.pub.multicall({
      allowFailure: false,
      contracts: all.flatMap((a) => [
        { address: v, abi: strategyVaultAbi, functionName: "enabled", args: [a] },
        { address: v, abi: strategyVaultAbi, functionName: "quarantined", args: [a] },
        { address: v, abi: strategyVaultAbi, functionName: "cachedLiquidityTs", args: [a] },
      ]),
    })) as unknown[];
    const out: AdapterState[] = [];
    all.forEach((adapter, i) => {
      const [on, q, ts] = flags.slice(i * 3, i * 3 + 3) as [boolean, boolean, bigint];
      if (on && !q) out.push({ adapter, cachedTs: Number(ts) });
    });
    return out;
  }

  async tick({ chain, gate }: JobContext): Promise<TickResult> {
    const v = this.cfg.strategyVault;
    const [adapters, staleness, now] = await Promise.all([
      this.enabledAdapters(chain),
      chain.read<number>(v, strategyVaultAbi, "liquidityStalenessSeconds"),
      chain.now(),
    ]);
    const maxAge = staleness > 0 ? staleness : this.cfg.fallbackMaxAgeSec;
    const batches = dueBatches(adapters, now, maxAge, this.cfg.refreshMarginSec, this.cfg.batchSize);
    if (batches.length === 0) {
      gate.clear(this.id);
      return { due: false, actions: 0 };
    }

    let actions = 0;
    for (const b of batches) {
      const decision = gate.shouldAct(`${this.id}:${b.start}`, now, this.cfg.secondaryGraceSec, b.dueSince);
      if (!decision.act) {
        log.info("secondary deferring to primary", { job: this.id, batch: b, waitSec: decision.waitSec });
        return { due: true, actions, deferred: true };
      }
      const res = await chain.write({
        label: `${this.id}:pokeLiquidityBatch`,
        address: v,
        abi: strategyVaultAbi,
        functionName: "pokeLiquidityBatch",
        args: [BigInt(b.start), BigInt(b.end)],
      });
      if (res.status === "mined" || res.status === "dry-run") {
        actions++;
        if (res.status === "mined") {
          const failed = parseEventLogs({ abi: strategyVaultAbi, logs: res.receipt.logs, eventName: "AdapterCallFailed" })
            .filter((l) => sameAddress(l.address, v));
          for (const f of failed) {
            await alert(`${this.id}:adapter-failed:${f.args.adapter}`, `${this.id} adapter observation failed`, {
              adapter: f.args.adapter,
              selector: f.args.selector,
              tx: res.receipt.transactionHash,
            });
          }
        }
      } else if (res.status === "not-eligible") {
        await alert(`${this.id}:sim-revert`, `${this.id} pokeLiquidityBatch simulation reverted (KEEPER_ROLE?)`, {
          reason: res.reason,
          batch: b,
        });
        break;
      } else if (res.status === "reverted") {
        await alert(`${this.id}:reverted`, `${this.id} pokeLiquidityBatch reverted on-chain`, { tx: res.receipt.transactionHash });
        break;
      } else {
        log.warn("pokeLiquidityBatch not sent", { job: this.id, ...res });
        break;
      }
    }
    return { due: true, actions };
  }

  async preflight({ chain }: JobContext): Promise<PreflightCheck[]> {
    const out: PreflightCheck[] = [];
    const v = this.cfg.strategyVault;
    const push = (level: PreflightCheck["level"], check: string, detail?: string) =>
      out.push({ job: this.id, level, check, detail });

    if (!chain.from) {
      push("warn", "keeper KEEPER_ROLE on strategy vault", "no keeper address (set KEEPER_ADDRESS or a signer)");
    } else {
      const role = await chain.read<Hex>(v, strategyVaultAbi, "KEEPER_ROLE");
      const has = await chain.read<boolean>(v, strategyVaultAbi, "hasRole", [role, chain.from]);
      push(has ? "ok" : "fail", "keeper KEEPER_ROLE on strategy vault", `${chain.from}${has ? "" : " — grant required"}`);
    }
    const [adapters, staleness, now] = await Promise.all([
      this.enabledAdapters(chain),
      chain.read<number>(v, strategyVaultAbi, "liquidityStalenessSeconds"),
      chain.now(),
    ]);
    push("info", "enabled adapters", String(adapters.length));
    push(
      staleness > 0 ? "info" : "warn",
      "liquidityStalenessSeconds",
      staleness > 0 ? `${staleness}s` : `0 — using fallbackMaxAgeSec=${this.cfg.fallbackMaxAgeSec}`,
    );
    for (const a of adapters) {
      push("info", `liquidity cache age ${a.adapter}`, a.cachedTs ? `${now - a.cachedTs}s` : "never cached");
    }
    return out;
  }
}
