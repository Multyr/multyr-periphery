import { createServer, type Server } from "node:http";
import { formatEther, parseEther } from "viem";
import type { Config, JobConfig } from "./config.ts";
import { FeeCollectorJob } from "./jobs/feeCollector.ts";
import { LiquidityJob } from "./jobs/liquidity.ts";
import type { Job, JobContext, PreflightCheck } from "./jobs/types.ts";
import { UpkeepJob } from "./jobs/upkeep.ts";
import { WarmNavJob } from "./jobs/warmNav.ts";
import { alert, log } from "./log.ts";

export function buildJobs(cfg: Config): Job[] {
  return cfg.chain.jobs
    .filter((j) => j.enabled !== false && (!cfg.env.jobFilter || cfg.env.jobFilter.has(j.id)))
    .map((j: JobConfig): Job => {
      switch (j.type) {
        case "upkeep":
          return new UpkeepJob(j);
        case "feeCollector":
          return new FeeCollectorJob(j);
        case "liquidity":
          return new LiquidityJob(j);
        case "warmNav":
          return new WarmNavJob(j);
      }
    });
}

async function runJob(job: Job, ctx: JobContext): Promise<boolean> {
  const started = Date.now();
  try {
    const r = await job.tick(ctx);
    log[r.actions > 0 ? "info" : "debug"]("job tick", { job: job.id, ...r, ms: Date.now() - started });
    return true;
  } catch (e) {
    await alert(`${job.id}:exception`, `${job.id} tick threw`, { error: e instanceof Error ? e.message : String(e) });
    return false;
  }
}

async function checkBalance(ctx: JobContext): Promise<void> {
  if (!ctx.chain.from || ctx.chain.dryRun) return;
  const bal = await ctx.chain.pub.getBalance({ address: ctx.chain.from });
  const min = parseEther(String(ctx.cfg.chain.minKeeperBalanceEth));
  if (bal < min) {
    await alert("balance", `keeper balance low: ${formatEther(bal)} ETH`, { address: ctx.chain.from });
  }
}

/** Run every job once. Used by `once` (external scheduler) and `check` (dry run). */
export async function runOnce(jobs: Job[], ctx: JobContext): Promise<boolean> {
  await checkBalance(ctx);
  let ok = true;
  for (const job of jobs) ok = (await runJob(job, ctx)) && ok;
  return ok;
}

/**
 * Long-running loop. Jobs execute sequentially from one signer, so there is
 * never more than one in-flight tx per keeper address (no nonce races).
 */
export async function runLoop(jobs: Job[], ctx: JobContext): Promise<void> {
  const next = new Map(jobs.map((j) => [j.id, 0]));
  let stopping = false;
  let lastLoop = Date.now();
  let lastBalanceCheck = 0;
  const minPoll = Math.min(...jobs.map((j) => j.pollSec));

  const stop = (sig: string) => {
    log.info("shutdown requested; finishing current job", { sig });
    stopping = true;
  };
  process.once("SIGTERM", () => stop("SIGTERM"));
  process.once("SIGINT", () => stop("SIGINT"));

  let server: Server | undefined;
  if (ctx.cfg.env.port) {
    server = createServer((_req, res) => {
      const staleMs = Date.now() - lastLoop;
      const healthy = staleMs < Math.max(minPoll, 30) * 3000;
      res.writeHead(healthy ? 200 : 503, { "content-type": "application/json" });
      res.end(JSON.stringify({ healthy, lastLoopAgoMs: staleMs, instance: ctx.gate.instance }));
    }).listen(ctx.cfg.env.port);
  }

  while (!stopping) {
    lastLoop = Date.now();
    if (lastLoop - lastBalanceCheck > 10 * 60_000) {
      lastBalanceCheck = lastLoop;
      await checkBalance(ctx).catch((e) => log.warn("balance check failed", { error: String(e) }));
    }
    for (const job of jobs) {
      if (stopping) break;
      if (Date.now() < next.get(job.id)!) continue;
      await runJob(job, ctx);
      next.set(job.id, Date.now() + job.pollSec * 1000);
    }
    const wake = Math.min(...next.values()) - Date.now();
    await new Promise((r) => setTimeout(r, Math.max(1000, Math.min(wake, 15_000))));
  }
  server?.close();
}

export async function runPreflight(jobs: Job[], ctx: JobContext): Promise<PreflightCheck[]> {
  const out: PreflightCheck[] = [];
  const chainId = await ctx.chain.pub.getChainId();
  out.push({
    job: "-",
    level: chainId === ctx.cfg.chain.chainId ? "ok" : "fail",
    check: "RPC chainId matches config",
    detail: `${chainId}`,
  });
  for (const [name, address] of Object.entries(ctx.cfg.chain.addresses)) {
    const code = await ctx.chain.pub.getCode({ address });
    out.push({ job: "-", level: code && code !== "0x" ? "ok" : "fail", check: `code at ${name}`, detail: address });
  }
  if (ctx.chain.from) {
    const bal = await ctx.chain.pub.getBalance({ address: ctx.chain.from });
    const min = parseEther(String(ctx.cfg.chain.minKeeperBalanceEth));
    out.push({
      job: "-",
      level: bal >= min ? "ok" : "warn",
      check: "keeper ETH balance",
      detail: `${ctx.chain.from} ${formatEther(bal)} ETH`,
    });
  }
  for (const job of jobs) {
    try {
      out.push(...(await job.preflight(ctx)));
    } catch (e) {
      out.push({ job: job.id, level: "fail", check: "preflight threw", detail: e instanceof Error ? e.message : String(e) });
    }
  }
  return out;
}
