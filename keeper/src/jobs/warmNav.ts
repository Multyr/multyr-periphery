import { parseEventLogs } from "viem";
import { bufferManagerAbi } from "../abis.ts";
import type { WarmNavJobConfig } from "../config.ts";
import { alert, log } from "../log.ts";
import { sameAddress, type Job, type JobContext, type PreflightCheck, type TickResult } from "./types.ts";

// W6 — BufferManager.refreshWarmNav() (permissionless).
//
// Freshness-based: refresh when the cache is within refreshMarginSec of
// navRefreshInterval, or when it is flagged invalid. A failed adapter
// observation leaves warmNavValid=false on-chain (deposits are rejected); we
// surface that as an alert rather than retrying blindly every poll.

export function warmNavDue(now: number, ts: number, valid: boolean, interval: number, margin: number) {
  const dueAt = ts + interval - margin;
  return { due: !valid || now >= dueAt, dueSince: valid ? dueAt : ts };
}

export class WarmNavJob implements Job {
  readonly id: string;
  readonly pollSec: number;
  private readonly cfg: WarmNavJobConfig;

  constructor(cfg: WarmNavJobConfig) {
    this.cfg = cfg;
    this.id = cfg.id;
    this.pollSec = cfg.pollSec;
  }

  async tick({ chain, gate }: JobContext): Promise<TickResult> {
    const bm = this.cfg.bufferManager;
    const [[, ts, valid], interval, now] = await Promise.all([
      chain.read<[bigint, number, boolean]>(bm, bufferManagerAbi, "warmNavState"),
      chain.read<number>(bm, bufferManagerAbi, "navRefreshInterval"),
      chain.now(),
    ]);
    const { due, dueSince } = warmNavDue(now, Number(ts), valid, interval, this.cfg.refreshMarginSec);
    if (!due) {
      gate.clear(this.id);
      return { due: false, actions: 0 };
    }
    const decision = gate.shouldAct(this.id, now, this.cfg.secondaryGraceSec, dueSince);
    if (!decision.act) {
      log.info("secondary deferring to primary", { job: this.id, ageSec: now - Number(ts), waitSec: decision.waitSec });
      return { due, actions: 0, deferred: true };
    }

    const res = await chain.write({
      label: `${this.id}:refreshWarmNav`,
      address: bm,
      abi: bufferManagerAbi,
      functionName: "refreshWarmNav",
    });
    if (res.status === "dry-run") return { due, actions: 1 };
    if (res.status !== "mined") {
      await alert(`${this.id}:${res.status}`, `${this.id} refreshWarmNav ${res.status}`, {
        reason: "reason" in res ? res.reason : undefined,
        tx: "receipt" in res ? res.receipt.transactionHash : undefined,
      });
      return { due, actions: 0 };
    }

    const logs = parseEventLogs({ abi: bufferManagerAbi, logs: res.receipt.logs }).filter((l) =>
      sameAddress(l.address, bm),
    );
    const failedAdapters = logs.filter((l) => l.eventName === "WarmNavAdapterFailed").map((l: any) => l.args.adapter);
    const updated = logs.find((l) => l.eventName === "WarmNavCacheUpdated") as any;
    if (updated && !updated.args.valid) {
      await alert(`${this.id}:invalid`, `${this.id} warm NAV refreshed but INVALID — deposits blocked`, {
        failedAdapters,
        tx: res.receipt.transactionHash,
      });
    } else {
      log.info("warm NAV refreshed", { job: this.id, nav: updated?.args.warmNav, tx: res.receipt.transactionHash });
    }
    return { due, actions: 1 };
  }

  async preflight({ chain, cfg }: JobContext): Promise<PreflightCheck[]> {
    const bm = this.cfg.bufferManager;
    const [core, [nav, ts, valid], interval, now] = await Promise.all([
      chain.read<string>(bm, bufferManagerAbi, "core"),
      chain.read<[bigint, number, boolean]>(bm, bufferManagerAbi, "warmNavState"),
      chain.read<number>(bm, bufferManagerAbi, "navRefreshInterval"),
      chain.now(),
    ]);
    return [
      {
        job: this.id,
        level: sameAddress(core, cfg.chain.addresses.coreVault) ? "ok" : "fail",
        check: "BufferManager.core() == coreVault",
        detail: core,
      },
      {
        job: this.id,
        level: valid ? "info" : "warn",
        check: "warm NAV state",
        detail: `nav=${nav} age=${now - Number(ts)}s valid=${valid} navRefreshInterval=${interval}s`,
      },
    ];
  }
}
