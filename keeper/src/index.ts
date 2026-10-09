import { getAddress } from "viem";
import { ChainClient } from "./chain.ts";
import { loadConfig } from "./config.ts";
import { DueGate } from "./gate.ts";
import type { JobContext } from "./jobs/types.ts";
import { configureAlerts, log, setLogContext } from "./log.ts";
import { buildJobs, runLoop, runOnce, runPreflight } from "./runner.ts";
import { loadSigner } from "./signers/index.ts";

const USAGE = `usage: node src/index.ts <run|once|check|check-loop|preflight>
  run        long-running loop (container / VM)
  once       evaluate every job once and exit (cron / Cloud Run job / Lambda)
  check      like once, but simulate only — never sends a transaction
  check-loop long-running simulation loop — never loads a signer or sends
  preflight  verify wiring, roles and config against the chain; exit 1 on any FAIL`;

async function main(): Promise<number> {
  const mode = process.argv[2];
  if (!["run", "once", "check", "check-loop", "preflight"].includes(mode ?? "")) {
    console.error(USAGE);
    return 2;
  }
  const sends = mode === "run" || mode === "once";
  const cfg = loadConfig(sends);
  setLogContext({ instance: cfg.env.instance, network: cfg.chain.network, mode });
  configureAlerts(cfg.env.alertWebhookUrl);

  const account = mode === "check-loop" ? undefined : await loadSigner(cfg.env);
  const from = account?.address ?? (process.env.KEEPER_ADDRESS ? getAddress(process.env.KEEPER_ADDRESS) : undefined);
  if (mode === "check-loop" && !from) throw new Error("KEEPER_ADDRESS required for check-loop");
  const chain = new ChainClient(cfg, account, { dryRun: !sends, from });
  const ctx: JobContext = { chain, cfg, gate: new DueGate(cfg.env.instance, mode !== "run" && mode !== "check-loop") };
  const jobs = buildJobs(cfg);
  log.info("keeper starting", { keeper: from, jobs: jobs.map((j) => j.id) });

  if (mode === "preflight") {
    const checks = await runPreflight(jobs, ctx);
    for (const c of checks) {
      console.log(`${c.level.toUpperCase().padEnd(5)} ${c.job.padEnd(3)} ${c.check}${c.detail ? `  — ${c.detail}` : ""}`);
    }
    return checks.some((c) => c.level === "fail") ? 1 : 0;
  }
  if (mode === "run" || mode === "check-loop") {
    await runLoop(jobs, ctx);
    return 0;
  }
  return (await runOnce(jobs, ctx)) ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (e) => {
    log.error("fatal", { error: e instanceof Error ? e.stack : String(e) });
    process.exit(1);
  },
);
