import { decodeAbiParameters, parseEventLogs, type Abi, type Hex, type TransactionReceipt } from "viem";
import {
  claimUpkeepAbi,
  STRATEGY_OPS,
  strategyUpkeepAbi,
  strategyVaultAbi,
  VAULT_OPS,
  vaultUpkeepAbi,
} from "../abis.ts";
import type { UpkeepJobConfig } from "../config.ts";
import { alert, log } from "../log.ts";
import { sameAddress, type Job, type JobContext, type PreflightCheck, type TickResult } from "./types.ts";

// W1 VaultUpkeep, W2 StrategyUpkeep, W3 ClaimSettlementUpkeep.
//
// These contracts already encode every eligibility rule in checkUpkeep and
// their performUpkeep is permissionless, so the bot is a plain
// check → perform loop — the same thing a Chainlink/CRE node does. The one
// addition is bounded follow-up: after a successful action we re-check and
// continue (up to maxActionsPerTick), because each perform is single-action
// and e.g. close → fund → reconcile, or a multi-step rebalance plan, needs
// several consecutive runs.

const ABIS: Record<UpkeepJobConfig["flavor"], Abi> = {
  vault: vaultUpkeepAbi,
  strategy: strategyUpkeepAbi,
  claims: claimUpkeepAbi,
};

export function describePerformData(flavor: UpkeepJobConfig["flavor"], data: Hex): Record<string, unknown> {
  try {
    if (flavor === "vault") {
      // VaultUpkeep._decode accepts a bare 32-byte op or (Op, uint256).
      if ((data.length - 2) / 2 === 32) {
        const [op] = decodeAbiParameters([{ type: "uint8" }], data);
        return { op: VAULT_OPS[op] ?? op };
      }
      const [op, arg] = decodeAbiParameters([{ type: "uint8" }, { type: "uint256" }], data);
      return { op: VAULT_OPS[op] ?? op, arg };
    }
    if (flavor === "strategy") {
      const [op, index] = decodeAbiParameters([{ type: "uint8" }, { type: "uint256" }], data);
      return { op: STRATEGY_OPS[op] ?? op, strategyIndex: index };
    }
    const [epochId, ids, nextEpoch, nextClaim] = decodeAbiParameters(
      [{ type: "uint256" }, { type: "uint256[]" }, { type: "uint256" }, { type: "uint256" }],
      data,
    );
    return { op: "SETTLE_CLAIMS", epochId, claims: ids.length, nextEpoch, nextClaim };
  } catch {
    return { op: "UNDECODED", data };
  }
}

export class UpkeepJob implements Job {
  readonly id: string;
  readonly pollSec: number;
  private readonly cfg: UpkeepJobConfig;
  private readonly abi: Abi;

  constructor(cfg: UpkeepJobConfig) {
    this.cfg = cfg;
    this.id = cfg.id;
    this.pollSec = cfg.pollSec;
    this.abi = ABIS[cfg.flavor];
  }

  async tick({ chain, gate }: JobContext): Promise<TickResult> {
    const { target, maxActionsPerTick, secondaryGraceSec } = this.cfg;
    let actions = 0;
    let due = false;

    for (let i = 0; i < maxActionsPerTick; i++) {
      const [needed, performData] = await chain.read<[boolean, Hex]>(target, this.abi, "checkUpkeep", ["0x"]);
      if (!needed) {
        gate.clear(this.id);
        break;
      }
      due = true;
      const op = describePerformData(this.cfg.flavor, performData);
      const decision = gate.shouldAct(this.id, await chain.now(), secondaryGraceSec);
      if (!decision.act) {
        log.info("secondary deferring to primary", { job: this.id, ...op, waitSec: decision.waitSec });
        return { due, actions, deferred: true };
      }

      const res = await chain.write({
        label: `${this.id}:${op.op}`,
        address: target,
        abi: this.abi,
        functionName: "performUpkeep",
        args: [performData],
      });

      if (res.status === "dry-run") return { due, actions: actions + 1 };
      if (res.status === "not-eligible") {
        // checkUpkeep said yes but perform reverts: an on-chain guard the view
        // does not mirror (e.g. StrategyUpkeep cooldowns). Not ours to override.
        log.warn("performUpkeep simulation reverted", { job: this.id, ...op, reason: res.reason });
        break;
      }
      if (res.status === "skipped") {
        log.warn("performUpkeep skipped", { job: this.id, ...op, reason: res.reason });
        break;
      }
      if (res.status === "reverted") {
        await alert(`${this.id}:reverted`, `${this.id} performUpkeep reverted on-chain`, {
          ...op,
          tx: res.receipt.transactionHash,
        });
        break;
      }
      actions++;
      await this.inspectReceipt(res.receipt, op);
    }
    return { due, actions };
  }

  /** Inner calls are try/caught on-chain; surface their failures from events. */
  private async inspectReceipt(receipt: TransactionReceipt, op: Record<string, unknown>): Promise<void> {
    const logs = parseEventLogs({ abi: this.abi, logs: receipt.logs }).filter((l) =>
      sameAddress(l.address, this.cfg.target),
    );
    const tx = receipt.transactionHash;
    for (const l of logs as any[]) {
      const a = l.args;
      switch (`${this.cfg.flavor}:${l.eventName}`) {
        case "vault:UpkeepPerformed":
          if (!a.success) {
            await alert(`${this.id}:op-failed:${VAULT_OPS[a.op]}`, `${this.id} ${VAULT_OPS[a.op]} inner call failed`, {
              arg: a.arg,
              tx,
            });
          } else log.info("vault op ok", { job: this.id, op: VAULT_OPS[a.op], arg: a.arg, tx });
          break;
        case "vault:UpkeepBackoffEntered":
          await alert(`${this.id}:backoff`, `${this.id} VaultUpkeep entered failure backoff`, { failures: a.failures, tx });
          break;
        case "strategy:UpkeepErrored":
          await alert(`${this.id}:errored:${a.op}`, `${this.id} ${STRATEGY_OPS[a.op] ?? a.op} errored`, {
            strategy: a.strategy,
            reason: a.reason,
            tx,
          });
          break;
        case "strategy:SnapshotPokeFailed":
        case "strategy:ExternalTVLPokeFailed":
        case "strategy:ExternalCallFailed":
          await alert(`${this.id}:${l.eventName}:${a.target ?? a.strategy}`, `${this.id} ${l.eventName}`, {
            ...a,
            tx,
          });
          break;
        case "claims:ClaimSettlementFailed":
          await alert(`${this.id}:claim-failed`, `${this.id} claim settlement failed (retry scheduled on-chain)`, {
            epochId: a.epochId,
            claimId: a.claimId,
            retryAt: a.retryAt,
            tx,
          });
          break;
        case "claims:UpkeepPerformed":
          log.info("claims settled", { job: this.id, epochId: a.epochId, claims: a.claimCount, total: a.totalSettled, tx });
          break;
      }
    }
    log.debug("upkeep receipt inspected", { job: this.id, ...op, events: logs.length });
  }

  async preflight({ chain, cfg }: JobContext): Promise<PreflightCheck[]> {
    const out: PreflightCheck[] = [];
    const push = (level: PreflightCheck["level"], check: string, detail?: string) =>
      out.push({ job: this.id, level, check, detail });
    const t = this.cfg.target;
    const A = cfg.chain.addresses;

    const [needed, data] = await chain.read<[boolean, Hex]>(t, this.abi, "checkUpkeep", ["0x"]);
    push("ok", "checkUpkeep callable", needed ? JSON.stringify(describePerformData(this.cfg.flavor, data), bigintJson) : "nothing due");

    if (this.cfg.flavor === "vault") {
      const core = await chain.read<string>(t, this.abi, "getCore");
      push(sameAddress(core, A.coreVault) ? "ok" : "fail", "VaultUpkeep.getCore() == coreVault", core);
      const [fails, threshold] = await Promise.all([
        chain.read<number>(t, this.abi, "consecutiveFailures"),
        chain.read<number>(t, this.abi, "failureThreshold"),
      ]);
      push(fails >= threshold ? "warn" : "ok", "VaultUpkeep failure backoff", `${fails}/${threshold}`);
    }

    if (this.cfg.flavor === "strategy") {
      const n = await chain.read<bigint>(t, this.abi, "strategiesLength");
      const strategies = await Promise.all(
        Array.from({ length: Number(n) }, (_, i) => chain.read<string>(t, this.abi, "getStrategy", [BigInt(i)])),
      );
      const registered = strategies.some((s) => sameAddress(s, A.strategyVault));
      push(registered ? "ok" : "fail", "strategy vault registered in StrategyUpkeep", strategies.join(",") || "none");
      if (registered) {
        const on = await chain.read<boolean>(t, this.abi, "enabled", [A.strategyVault]);
        push(on ? "ok" : "fail", "strategy vault enabled in StrategyUpkeep");
      }
      const role = await chain.read<Hex>(A.strategyVault, strategyVaultAbi, "KEEPER_ROLE");
      const has = await chain.read<boolean>(A.strategyVault, strategyVaultAbi, "hasRole", [role, t]);
      push(has ? "ok" : "fail", "StrategyUpkeep holds strategy KEEPER_ROLE");

      // A deployed adapter is not automatically a configured poke target.
      const targets = await chain.read<string[]>(t, this.abi, "getPokeTargets");
      const count = await chain.read<bigint>(A.strategyVault, strategyVaultAbi, "adapterCount");
      const adapters = await Promise.all(
        Array.from({ length: Number(count) }, (_, i) =>
          chain.read<string>(A.strategyVault, strategyVaultAbi, "adapters", [BigInt(i)]),
        ),
      );
      const missing = adapters.filter((a) => !targets.some((x) => sameAddress(x, a)));
      push(
        "info",
        "APY poke target coverage",
        `${targets.length} poke targets; adapters not directly poked: ${missing.join(",") || "none"} ` +
          "(Aave is covered by the rate push, not a poke target — confirm the rest are intended)",
      );
      const [last, interval] = await Promise.all([
        chain.read<bigint>(t, this.abi, "lastPokeTs"),
        chain.read<bigint>(t, this.abi, "pokeInterval"),
      ]);
      push("info", "POKE_APY clock", `lastPokeTs=${last} pokeInterval=${interval}s`);
    }

    if (this.cfg.flavor === "claims") {
      const target = await chain.read<string>(t, this.abi, "target");
      push(sameAddress(target, A.coreVault) ? "ok" : "fail", "ClaimSettlementUpkeep.target() == coreVault", target);
      const [c, s] = await Promise.all([
        chain.read<bigint>(t, this.abi, "maxClaimsPerUpkeep"),
        chain.read<bigint>(t, this.abi, "maxScanPerUpkeep"),
      ]);
      push("info", "claim batch sizes (deployed)", `maxClaimsPerUpkeep=${c} maxScanPerUpkeep=${s}`);
    }
    return out;
  }
}

function bigintJson(_k: string, v: unknown) {
  return typeof v === "bigint" ? v.toString() : v;
}
