import type { Address } from "viem";
import type { ChainClient } from "../chain.ts";
import type { Config } from "../config.ts";
import type { DueGate } from "../gate.ts";

export interface JobContext {
  chain: ChainClient;
  cfg: Config;
  gate: DueGate;
}

export interface TickResult {
  /** On-chain condition was due during this tick. */
  due: boolean;
  /** Transactions mined (or would have been, in dry-run). */
  actions: number;
  /** Secondary held back waiting for the primary. */
  deferred?: boolean;
}

export type CheckLevel = "ok" | "info" | "warn" | "fail";

export interface PreflightCheck {
  job: string;
  level: CheckLevel;
  check: string;
  detail?: string;
}

export interface Job {
  readonly id: string;
  readonly pollSec: number;
  tick(ctx: JobContext): Promise<TickResult>;
  preflight(ctx: JobContext): Promise<PreflightCheck[]>;
}

export function sameAddress(a?: Address | string, b?: Address | string): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}
