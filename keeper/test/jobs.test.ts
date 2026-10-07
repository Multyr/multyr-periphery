import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import {
  encodeAbiParameters,
  encodeEventTopics,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { bufferManagerAbi, feeCollectorAbi, strategyVaultAbi, vaultUpkeepAbi } from "../src/abis.ts";
import type { SendResult, WriteRequest } from "../src/chain.ts";
import type {
  FeeCollectorJobConfig,
  LiquidityJobConfig,
  UpkeepJobConfig,
  WarmNavJobConfig,
} from "../src/config.ts";
import { DueGate } from "../src/gate.ts";
import { FeeCollectorJob } from "../src/jobs/feeCollector.ts";
import { LiquidityJob } from "../src/jobs/liquidity.ts";
import type { JobContext } from "../src/jobs/types.ts";
import { UpkeepJob } from "../src/jobs/upkeep.ts";
import { WarmNavJob } from "../src/jobs/warmNav.ts";

// Job tick() behaviour against a scripted chain: which txs are sent, when the
// follow-up loop stops, and which receipt events become alerts.

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const TARGET = A(0xaa);

// --- alert capture (alerts are error-level JSON lines with an `alert` key on stderr) ---

let alerts: string[] = [];
let origWrite: typeof process.stderr.write;
beforeEach(() => {
  alerts = [];
  origWrite = process.stderr.write;
  process.stderr.write = ((chunk: string) => {
    try {
      const line = JSON.parse(String(chunk));
      if (line.alert) alerts.push(line.alert);
    } catch {}
    return true;
  }) as typeof process.stderr.write;
});
afterEach(() => {
  process.stderr.write = origWrite;
});

// --- fake chain ---

function eventLog(abi: Abi, eventName: string, args: Record<string, unknown>, address: Address = TARGET) {
  const ev = (abi as any[]).find((x) => x.type === "event" && x.name === eventName);
  const topics = encodeEventTopics({ abi, eventName, args } as any);
  const nonIndexed = ev.inputs.filter((i: any) => !i.indexed);
  const data = encodeAbiParameters(nonIndexed, nonIndexed.map((i: any) => args[i.name]));
  return { address, topics, data, blockNumber: 1n, logIndex: 0, transactionIndex: 0, removed: false } as any;
}

function receipt(logs: any[] = []): TransactionReceipt {
  return { transactionHash: `0x${"ab".repeat(32)}`, logs, status: "success" } as unknown as TransactionReceipt;
}

interface FakeOpts {
  now?: number;
  reads: (fn: string, args: readonly unknown[]) => unknown;
  writes?: (req: WriteRequest, n: number) => SendResult;
  simulate?: (req: WriteRequest) => { ok: true; request: unknown } | { ok: false; reason: string };
  multicall?: (contracts: { functionName: string; args?: readonly unknown[] }[]) => unknown[];
}

function fakeCtx(o: FakeOpts, instance: "primary" | "secondary" = "primary", stateless = true) {
  const sent: WriteRequest[] = [];
  const chain = {
    from: A(1),
    dryRun: false,
    now: async () => o.now ?? 1_000_000,
    read: async (_a: Address, _abi: Abi, fn: string, args: readonly unknown[] = []) => o.reads(fn, args),
    simulate: async (req: WriteRequest) => (o.simulate ? o.simulate(req) : { ok: true as const, request: {} }),
    write: async (req: WriteRequest) => {
      sent.push(req);
      return o.writes ? o.writes(req, sent.length) : ({ status: "mined", receipt: receipt() } as SendResult);
    },
    pub: { multicall: async ({ contracts }: any) => o.multicall!(contracts) },
  };
  const ctx = { chain, cfg: {} as any, gate: new DueGate(instance, stateless) } as unknown as JobContext;
  return { ctx, sent };
}

const vaultData = (op: number, arg = 0n) =>
  encodeAbiParameters([{ type: "uint8" }, { type: "uint256" }], [op, arg]);

const upkeepCfg = (over: Partial<UpkeepJobConfig> = {}): UpkeepJobConfig => ({
  id: "W1",
  type: "upkeep",
  flavor: "vault",
  target: TARGET,
  pollSec: 120,
  maxActionsPerTick: 10,
  secondaryGraceSec: 900,
  ...over,
});

// --- W1-W3 upkeep ---

test("upkeep: follows up while checkUpkeep stays true, then stops", async () => {
  const queue: [boolean, Hex][] = [
    [true, vaultData(1, 5n)], // EPOCH_CLOSE
    [true, vaultData(2, 5n)], // EPOCH_FUND
    [true, vaultData(7)], // RECONCILE
    [false, "0x"],
  ];
  const { ctx, sent } = fakeCtx({ reads: () => queue.shift() });
  const r = await new UpkeepJob(upkeepCfg()).tick(ctx);
  assert.deepEqual(r, { due: true, actions: 3 });
  assert.equal(sent.length, 3);
  assert.deepEqual(sent.map((s) => s.label), ["W1:EPOCH_CLOSE", "W1:EPOCH_FUND", "W1:RECONCILE"]);
});

test("upkeep: bounded by maxActionsPerTick", async () => {
  const { ctx, sent } = fakeCtx({ reads: () => [true, vaultData(3)] });
  const r = await new UpkeepJob(upkeepCfg({ maxActionsPerTick: 4 })).tick(ctx);
  assert.equal(r.actions, 4);
  assert.equal(sent.length, 4);
});

test("upkeep: stops on simulation revert, fee skip and on-chain revert", async () => {
  for (const res of [
    { status: "not-eligible", reason: "Cooldown" },
    { status: "skipped", reason: "fee" },
    { status: "reverted", receipt: receipt() },
  ] as SendResult[]) {
    const { ctx, sent } = fakeCtx({ reads: () => [true, vaultData(3)], writes: () => res });
    const r = await new UpkeepJob(upkeepCfg()).tick(ctx);
    assert.equal(sent.length, 1, res.status);
    assert.equal(r.actions, 0, res.status);
  }
  assert.deepEqual(alerts, ["W1:reverted"]);
});

test("upkeep: inner failure and backoff events become alerts", async () => {
  const logs = [
    eventLog(vaultUpkeepAbi, "UpkeepPerformed", { op: 3, arg: 0n, success: false }),
    eventLog(vaultUpkeepAbi, "UpkeepBackoffEntered", { failures: 3 }),
    eventLog(vaultUpkeepAbi, "UpkeepBackoffEntered", { failures: 3 }, A(0xbad)), // other contract: ignored
  ];
  const queue: [boolean, Hex][] = [[true, vaultData(3)], [false, "0x"]];
  const { ctx } = fakeCtx({ reads: () => queue.shift(), writes: () => ({ status: "mined", receipt: receipt(logs) }) });
  await new UpkeepJob(upkeepCfg()).tick(ctx);
  assert.deepEqual(alerts, ["W1:op-failed:CRYSTALLIZE", "W1:backoff"]);
});

// Found on the Arbitrum fork: the gas estimate starves the try/caught inner
// call, checkUpkeep stays true, and the loop re-sends the same failing op until
// VaultUpkeep's own failure counter puts it into a 30-minute backoff.
test(
  "upkeep: does not re-send an op whose inner call just failed",
  { todo: "bot keeps looping after UpkeepPerformed(success=false); see fork findings" },
  async () => {
    const failed = receipt([eventLog(vaultUpkeepAbi, "UpkeepPerformed", { op: 3, arg: 0n, success: false })]);
    const { ctx, sent } = fakeCtx({
      reads: () => [true, vaultData(3)],
      writes: () => ({ status: "mined", receipt: failed }),
    });
    await new UpkeepJob(upkeepCfg()).tick(ctx);
    assert.equal(sent.length, 1);
  },
);

test("upkeep: secondary defers in run mode, then acts after grace; clears when no longer due", async () => {
  let due = true;
  let now = 10_000;
  const { ctx, sent } = fakeCtx({ reads: () => (due ? [true, vaultData(3)] : [false, "0x"]) }, "secondary", false);
  (ctx.chain as any).now = async () => now;
  const job = new UpkeepJob(upkeepCfg({ maxActionsPerTick: 1 }));

  assert.deepEqual(await job.tick(ctx), { due: true, actions: 0, deferred: true });
  now += 899;
  assert.equal((await job.tick(ctx)).deferred, true);
  now += 1;
  assert.deepEqual(await job.tick(ctx), { due: true, actions: 1 });
  assert.equal(sent.length, 1);

  due = false; // primary cleared it
  await job.tick(ctx);
  due = true;
  assert.equal((await job.tick(ctx)).deferred, true, "grace restarts after the condition clears");
});

test("upkeep: dry-run counts the action but sends nothing further", async () => {
  const { ctx, sent } = fakeCtx({ reads: () => [true, vaultData(3)], writes: () => ({ status: "dry-run" }) });
  assert.deepEqual(await new UpkeepJob(upkeepCfg()).tick(ctx), { due: true, actions: 1 });
  assert.equal(sent.length, 1);
});

// --- W4 fee collector ---

const fcCfg: FeeCollectorJobConfig = {
  id: "W4",
  type: "feeCollector",
  target: TARGET,
  distributeTokens: [A(0xc0), A(0xd0)],
  harvestQueuedTokens: [A(0xc0)],
  distributeWindow: { weekday: 1, hourUtc: 10, durationHours: 6 },
  pollSec: 900,
  secondaryGraceSec: 3600,
};
const MON_1030 = Date.UTC(2026, 9, 12, 10, 30) / 1000;
const TUE_1030 = MON_1030 + 86_400;

test("fee collector: distribute only inside the window; harvestQueued only with pending claims", async () => {
  const reads = (pending: bigint) => (fn: string) => (fn === "paused" ? false : pending);

  let f = fakeCtx({ now: TUE_1030, reads: reads(0n) });
  assert.deepEqual(await new FeeCollectorJob(fcCfg).tick(f.ctx), { due: false, actions: 0, deferred: false });
  assert.equal(f.sent.length, 0);

  f = fakeCtx({ now: TUE_1030, reads: reads(2n) });
  await new FeeCollectorJob(fcCfg).tick(f.ctx);
  assert.deepEqual(f.sent.map((s) => s.functionName), ["harvestQueued"]);

  f = fakeCtx({ now: MON_1030, reads: reads(1n) });
  await new FeeCollectorJob(fcCfg).tick(f.ctx);
  assert.deepEqual(
    f.sent.map((s) => `${s.functionName}:${s.args![0]}`),
    [`harvestQueued:${A(0xc0)}`, `distribute:${A(0xc0)}`, `distribute:${A(0xd0)}`],
  );
});

test("fee collector: ineligible token is skipped without a tx; paused skips everything", async () => {
  let f = fakeCtx({
    now: MON_1030,
    reads: (fn) => (fn === "paused" ? false : 0n),
    simulate: (req) => (req.args![0] === A(0xc0) ? { ok: false, reason: "no balance" } : { ok: true, request: {} }),
  });
  const r = await new FeeCollectorJob(fcCfg).tick(f.ctx);
  assert.deepEqual(f.sent.map((s) => s.args![0]), [A(0xd0)]);
  assert.equal(r.actions, 1);

  f = fakeCtx({ now: MON_1030, reads: (fn) => (fn === "paused" ? true : 5n) });
  assert.deepEqual(await new FeeCollectorJob(fcCfg).tick(f.ctx), { due: false, actions: 0 });
  assert.equal(f.sent.length, 0);
});

test("fee collector: secondary uses the window start as dueSince", async () => {
  const reads = (fn: string) => (fn === "paused" ? false : 0n);
  let f = fakeCtx({ now: MON_1030, reads }, "secondary", true); // 30 min into window < 1h grace
  assert.equal((await new FeeCollectorJob(fcCfg).tick(f.ctx)).deferred, true);
  assert.equal(f.sent.length, 0);
  f = fakeCtx({ now: MON_1030 + 3600, reads }, "secondary", true);
  await new FeeCollectorJob(fcCfg).tick(f.ctx);
  assert.equal(f.sent.length, 2);
});

test("fee collector: HarvestDeferred becomes an alert", async () => {
  const logs = [eventLog(feeCollectorAbi, "HarvestDeferred", { token: A(0xc0), shares: 5n, reason: "cooldown" })];
  const f = fakeCtx({
    now: TUE_1030,
    reads: (fn) => (fn === "paused" ? false : 1n),
    writes: () => ({ status: "mined", receipt: receipt(logs) }),
  });
  await new FeeCollectorJob(fcCfg).tick(f.ctx);
  assert.deepEqual(alerts, [`W4:deferred:${A(0xc0)}`]);
});

// --- W5 liquidity ---

const liqCfg: LiquidityJobConfig = {
  id: "W5",
  type: "liquidity",
  strategyVault: TARGET,
  batchSize: 2,
  refreshMarginSec: 300,
  fallbackMaxAgeSec: 3600,
  pollSec: 120,
  secondaryGraceSec: 600,
};

function liqChain(ts: number[], extra: Partial<FakeOpts> = {}, flags?: { enabled: boolean; q: boolean }[]) {
  const adapters = ts.map((_, i) => A(0x100 + i));
  return {
    now: 10_000,
    reads: (fn: string) => (fn === "adapterCount" ? BigInt(ts.length) : 0), // staleness 0 → fallback
    multicall: (contracts: { functionName: string; args?: readonly unknown[] }[]) =>
      contracts.map((c) => {
        if (c.functionName === "adapters") return adapters[Number(c.args![0])];
        const i = adapters.indexOf(c.args![0] as Address);
        if (c.functionName === "enabled") return flags?.[i].enabled ?? true;
        if (c.functionName === "quarantined") return flags?.[i].q ?? false;
        return BigInt(ts[i]);
      }),
    ...extra,
  };
}

test("liquidity: pokes only stale batches, indexed over enabled non-quarantined adapters", async () => {
  // 5 adapters, #1 disabled → enabled list [0,2,3,4]; stale: #0 and #4 → batches [0,2) and [2,4)
  const ts = [5000, 5000, 9999, 9999, 5000];
  const flags = ts.map((_, i) => ({ enabled: i !== 1, q: false }));
  const f = fakeCtx(liqChain(ts, {}, flags));
  const r = await new LiquidityJob(liqCfg).tick(f.ctx);
  assert.equal(r.actions, 2);
  assert.deepEqual(f.sent.map((s) => s.args), [[0n, 2n], [2n, 4n]]);

  const fresh = fakeCtx(liqChain([9999, 9999]));
  assert.deepEqual(await new LiquidityJob(liqCfg).tick(fresh.ctx), { due: false, actions: 0 });
});

test("liquidity: missing KEEPER_ROLE alerts and stops; AdapterCallFailed alerts", async () => {
  let f = fakeCtx(liqChain([0, 0, 0, 0], { writes: () => ({ status: "not-eligible", reason: "Unauthorized" }) }));
  await new LiquidityJob(liqCfg).tick(f.ctx);
  assert.equal(f.sent.length, 1);
  assert.deepEqual(alerts, ["W5:sim-revert"]);

  alerts = [];
  const logs = [
    eventLog(strategyVaultAbi, "AdapterCallFailed", { adapter: A(0x100), selector: "0x12345678", timestamp: 1n, data: "0x" }),
  ];
  f = fakeCtx(liqChain([0, 9999], { writes: () => ({ status: "mined", receipt: receipt(logs) }) }));
  await new LiquidityJob(liqCfg).tick(f.ctx);
  assert.deepEqual(alerts, [`W5:adapter-failed:${A(0x100)}`]);
});

// --- W6 warm NAV ---

const navCfg: WarmNavJobConfig = {
  id: "W6",
  type: "warmNav",
  bufferManager: TARGET,
  refreshMarginSec: 120,
  pollSec: 60,
  secondaryGraceSec: 180,
};
const navReads = (ts: number, valid: boolean) => (fn: string) =>
  fn === "warmNavState" ? [1n, ts, valid] : 600; // navRefreshInterval

test("warm NAV: refresh when due, not before; INVALID result alerts", async () => {
  let f = fakeCtx({ now: 10_000, reads: navReads(9_600, true) });
  assert.deepEqual(await new WarmNavJob(navCfg).tick(f.ctx), { due: false, actions: 0 });

  f = fakeCtx({ now: 10_000, reads: navReads(9_400, true) });
  assert.deepEqual(await new WarmNavJob(navCfg).tick(f.ctx), { due: true, actions: 1 });
  assert.deepEqual(alerts, []);

  const logs = [
    eventLog(bufferManagerAbi, "WarmNavAdapterFailed", { adapter: A(7), success: false, data: "0x" }),
    eventLog(bufferManagerAbi, "WarmNavCacheUpdated", { warmNav: 0n, timestamp: 10_000, valid: false }),
  ];
  f = fakeCtx({ now: 10_000, reads: navReads(9_900, false), writes: () => ({ status: "mined", receipt: receipt(logs) }) });
  await new WarmNavJob(navCfg).tick(f.ctx);
  assert.deepEqual(alerts, ["W6:invalid"]);
});

test("warm NAV: secondary waits grace from the on-chain due time", async () => {
  // due at 9_400 + 600 - 120 = 9_880
  let f = fakeCtx({ now: 10_000, reads: navReads(9_400, true) }, "secondary", true);
  assert.equal((await new WarmNavJob(navCfg).tick(f.ctx)).deferred, true);
  f = fakeCtx({ now: 10_060, reads: navReads(9_400, true) }, "secondary", true);
  assert.equal((await new WarmNavJob(navCfg).tick(f.ctx)).actions, 1);
});
