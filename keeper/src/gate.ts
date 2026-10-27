import type { Instance } from "./config.ts";

/**
 * Decides whether this instance should act on a condition that is due.
 *
 * - primary: acts as soon as the condition is due.
 * - secondary: acts only once the condition has been due for `graceSec`,
 *   i.e. the primary had a full window and did not clear it.
 *
 * "Due since" comes from chain state when the job can derive it (e.g. a
 * cache timestamp plus its TTL). Otherwise it is the first time this process
 * observed the condition. In stateless mode (`once`, run from an external
 * scheduler) there is no memory between runs, so the secondary acts on any
 * due condition and the grace comes from offsetting its schedule instead.
 */
export class DueGate {
  private readonly firstSeen = new Map<string, number>();
  readonly instance: Instance;
  readonly stateless: boolean;

  constructor(instance: Instance, stateless: boolean) {
    this.instance = instance;
    this.stateless = stateless;
  }

  shouldAct(key: string, now: number, graceSec: number, dueSince?: number): { act: boolean; waitSec: number } {
    if (this.instance === "primary") return { act: true, waitSec: 0 };
    let since = dueSince;
    if (since === undefined) {
      if (this.stateless) return { act: true, waitSec: 0 };
      if (!this.firstSeen.has(key)) this.firstSeen.set(key, now);
      since = this.firstSeen.get(key)!;
    }
    const waited = now - since;
    return waited >= graceSec ? { act: true, waitSec: 0 } : { act: false, waitSec: graceSec - waited };
  }

  /** Condition no longer due (someone cleared it). */
  clear(key: string): void {
    this.firstSeen.delete(key);
  }
}
