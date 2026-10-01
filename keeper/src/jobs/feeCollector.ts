import { parseEventLogs, type Address, type TransactionReceipt } from "viem";
import { feeCollectorAbi, SHARE_MODES } from "../abis.ts";
import type { FeeCollectorJobConfig } from "../config.ts";
import { alert, log } from "../log.ts";
import { sameAddress, type Job, type JobContext, type PreflightCheck, type TickResult } from "./types.ts";

// W4 — FeeCollector.distribute(token) and harvestQueued(token).
//
// No FeeCollectorUpkeep is deployed, but both methods are permissionless and
// revert when there is nothing to do ("no balance", "below min", "not
// allowed", "no claim ready", paused). Simulation is therefore an exact
// eligibility check and a duplicate call from the other bot simply fails
// simulation — no on-chain side effects, no gas.
//
// distribute() runs inside a weekly UTC window (user preference: weekly);
// harvestQueued() runs whenever a queued AUTO_HARVEST claim becomes ready.

const WEEK = 7 * 86_400;

/** Start of the most recent window and whether `now` is inside it. */
export function distributeWindow(now: number, w: FeeCollectorJobConfig["distributeWindow"]) {
  // 1970-01-01 was a Thursday (weekday 4).
  const weekStartSunday = now - ((((Math.floor(now / 86_400) + 4) % 7) * 86_400) + (now % 86_400));
  let start = weekStartSunday + w.weekday * 86_400 + w.hourUtc * 3_600;
  if (start > now) start -= WEEK;
  return { start, inside: now < start + w.durationHours * 3_600 };
}

export class FeeCollectorJob implements Job {
  readonly id: string;
  readonly pollSec: number;
  private readonly cfg: FeeCollectorJobConfig;

  constructor(cfg: FeeCollectorJobConfig) {
    this.cfg = cfg;
    this.id = cfg.id;
    this.pollSec = cfg.pollSec;
  }

  async tick({ chain, gate }: JobContext): Promise<TickResult> {
    const { target, secondaryGraceSec } = this.cfg;
    if (await chain.read<boolean>(target, feeCollectorAbi, "paused")) {
      log.info("fee collector paused; skipping", { job: this.id });
      return { due: false, actions: 0 };
    }
    const now = await chain.now();
    let due = false;
    let actions = 0;
    let deferred = false;

    // harvestQueued first: it drains settled claims and distributes the underlying.
    for (const token of this.cfg.harvestQueuedTokens) {
      const pending = await chain.read<bigint>(target, feeCollectorAbi, "pendingHarvestClaimCount", [token]);
      const key = `${this.id}:harvestQueued:${token}`;
      if (pending === 0n) {
        gate.clear(key);
        continue;
      }
      const r = await this.attempt(chain, gate, key, now, secondaryGraceSec, undefined, "harvestQueued", token);
      due ||= r.due;
      actions += r.actions;
      deferred ||= !!r.deferred;
    }

    const win = distributeWindow(now, this.cfg.distributeWindow);
    if (win.inside) {
      for (const token of this.cfg.distributeTokens) {
        const key = `${this.id}:distribute:${token}`;
        const r = await this.attempt(chain, gate, key, now, secondaryGraceSec, win.start, "distribute", token);
        due ||= r.due;
        actions += r.actions;
        deferred ||= !!r.deferred;
      }
    }
    return { due, actions, deferred };
  }

  private async attempt(
    chain: JobContext["chain"],
    gate: JobContext["gate"],
    key: string,
    now: number,
    grace: number,
    dueSince: number | undefined,
    fn: "distribute" | "harvestQueued",
    token: Address,
  ): Promise<TickResult> {
    const req = { label: `${this.id}:${fn}`, address: this.cfg.target, abi: feeCollectorAbi, functionName: fn, args: [token] };
    const sim = await chain.simulate(req);
    if (!sim.ok) {
      gate.clear(key);
      log.debug("not eligible", { job: this.id, fn, token, reason: sim.reason });
      return { due: false, actions: 0 };
    }
    const decision = gate.shouldAct(key, now, grace, dueSince);
    if (!decision.act) {
      log.info("secondary deferring to primary", { job: this.id, fn, token, waitSec: decision.waitSec });
      return { due: true, actions: 0, deferred: true };
    }
    const res = await chain.write(req);
    if (res.status === "mined") {
      await this.inspectReceipt(res.receipt, fn, token);
      return { due: true, actions: 1 };
    }
    if (res.status === "dry-run") return { due: true, actions: 1 };
    if (res.status === "reverted") {
      await alert(`${this.id}:${fn}:reverted`, `${this.id} ${fn} reverted on-chain`, { token, tx: res.receipt.transactionHash });
    } else {
      log.warn(`${fn} not sent`, { job: this.id, token, ...res });
    }
    return { due: true, actions: 0 };
  }

  private async inspectReceipt(receipt: TransactionReceipt, fn: string, token: Address): Promise<void> {
    const tx = receipt.transactionHash;
    const logs = parseEventLogs({ abi: feeCollectorAbi, logs: receipt.logs }).filter((l) =>
      sameAddress(l.address, this.cfg.target),
    );
    for (const l of logs as any[]) {
      if (l.eventName === "HarvestDeferred") {
        await alert(`${this.id}:deferred:${token}`, `${this.id} harvest deferred: ${l.args.reason}`, { token, tx });
      } else {
        log.info(`fee collector ${l.eventName}`, { job: this.id, fn, ...l.args, tx });
      }
    }
  }

  async preflight({ chain }: JobContext): Promise<PreflightCheck[]> {
    const out: PreflightCheck[] = [];
    const t = this.cfg.target;
    const push = (level: PreflightCheck["level"], check: string, detail?: string) =>
      out.push({ job: this.id, level, check, detail });

    push((await chain.read<boolean>(t, feeCollectorAbi, "paused")) ? "warn" : "ok", "FeeCollector not paused");
    const allowlist = await chain.read<boolean>(t, feeCollectorAbi, "allowlistEnabled");
    for (const token of new Set([...this.cfg.distributeTokens, ...this.cfg.harvestQueuedTokens])) {
      const [isSet, mode] = await chain.read<[boolean, number, Address]>(t, feeCollectorAbi, "shareConfigs", [token]);
      const modeName = isSet ? SHARE_MODES[mode] : "unset (auto-detect)";
      if (allowlist && !(await chain.read<boolean>(t, feeCollectorAbi, "allowedToken", [token]))) {
        push("warn", `token ${token} allowed`, "allowlist enabled and token not allowed — distribute() will always revert");
      }
      if (this.cfg.harvestQueuedTokens.includes(token)) {
        push(
          isSet && SHARE_MODES[mode] === "AUTO_HARVEST" ? "ok" : "warn",
          `harvestQueued token ${token} is AUTO_HARVEST`,
          `mode=${modeName}; harvestQueued() reverts unless AUTO_HARVEST is configured`,
        );
      } else {
        push("info", `distribute token ${token} share mode`, modeName);
      }
    }
    const now = await chain.now();
    const win = distributeWindow(now, this.cfg.distributeWindow);
    push("info", "distribution window", `last start ${new Date(win.start * 1000).toISOString()}, inside=${win.inside}`);
    return out;
  }
}
