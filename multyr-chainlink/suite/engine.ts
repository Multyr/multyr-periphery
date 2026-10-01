import { z } from "zod";
import { encodeFunctionData, parseAbiItem, type AbiFunction, type Address, type Hex } from "viem";

export const ZERO = "0x0000000000000000000000000000000000000000";
const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/);
const atom = z.union([z.string(), z.boolean()]); // integers are decimal strings, never floats
const readSchema = z.object({
  target: address, signature: z.string().startsWith("function "),
  args: z.array(atom).default([]),
});
const guardSchema = readSchema.extend({
  index: z.number().int().min(0).default(0),
  op: z.enum(["eq", "gt", "gte", "lt", "lte"]), expected: atom,
});
const actionSchema = readSchema.extend({
  id: z.string(), enabled: z.boolean().default(true),
  guards: z.array(guardSchema).max(8).default([]),
});
export const configSchema = z.object({
  mode: z.enum(["disabled", "preview", "live"]),
  kind: z.enum(["upkeep", "calls", "monitor", "policy-preview"]),
  chainSelectorName: z.string(), receiverAddress: address,
  writeGasLimit: z.string().regex(/^\d+$/),
  deploymentVerified: z.boolean().default(false),
  triggers: z.array(z.object({
    name: z.string(), schedule: z.string(), enabled: z.boolean(),
    actionIds: z.array(z.string()).default([]),
  })).min(1).max(10),
  targetAddress: address.optional(),
  actions: z.array(actionSchema).max(12).default([]),
  observations: z.array(readSchema.extend({
    id: z.string(), expect: atom.optional(), index: z.number().int().min(0).default(0),
  })).max(12).default([]),
  notes: z.array(z.string()).default([]),
});
export type Config = z.infer<typeof configSchema>;
export type Read = z.infer<typeof readSchema>;
export type Entry = { id: string; status: string; detail?: string };
export interface IO {
  read(request: Read): unknown;
  simulate(target: Address, data: Hex): void;
  write(target: Address, data: Hex): string;
}
export function encode(request: Read): Hex {
  const item = parseAbiItem(request.signature) as AbiFunction;
  if (!item || item.type !== "function") throw new Error("Function ABI required");
  // viem accepts integer decimal strings in ABI inputs without lossy Number conversion.
  return encodeFunctionData({ abi: [item], functionName: item.name, args: request.args });
}
export function selected(value: unknown, index: number): unknown {
  if (Array.isArray(value)) {
    if (index >= value.length) throw new Error("Result index out of bounds");
    return value[index];
  }
  if (index !== 0) throw new Error("Scalar result only has index zero");
  return value;
}
export function compare(actual: unknown, op: string, expected: string | boolean): boolean {
  if (op === "eq") return String(actual).toLowerCase() === String(expected).toLowerCase();
  if (!/^-?\d+$/.test(String(actual)) || !/^-?\d+$/.test(String(expected))) {
    throw new Error("Ordered comparisons require integer values");
  }
  const a = BigInt(String(actual)), b = BigInt(String(expected));
  return op === "gt" ? a > b : op === "gte" ? a >= b : op === "lt" ? a < b : a <= b;
}
export function validate(config: Config): void {
  if (new Set(config.triggers.map(t => t.name)).size !== config.triggers.length) throw new Error("Duplicate trigger name");
  if (!config.triggers.some(t => t.enabled)) throw new Error("At least one trigger must be enabled; disable the workflow mode instead");
  if (new Set(config.actions.map(a => a.id)).size !== config.actions.length) throw new Error("Duplicate action ID");
  for (const trigger of config.triggers) {
    for (const id of trigger.actionIds) {
      if (!config.actions.some(a => a.id === id)) throw new Error(`Unknown action ${id}`);
    }
  }
  if (config.kind === "upkeep" && (!config.targetAddress || config.targetAddress === ZERO)) {
    throw new Error("Upkeep target required");
  }
  for (const action of config.actions) {
    encode(action);
    for (const guard of action.guards) encode(guard);
    if (action.enabled && action.target === ZERO) throw new Error("Enabled action target is zero");
  }
  for (const observation of config.observations) encode(observation);
  if (config.kind === "policy-preview" && config.mode === "live") {
    throw new Error("Policy templates are preview-only; implement reviewed on-chain policy before enabling writes");
  }
  if (config.mode === "live" && config.kind !== "monitor") {
    if (!config.deploymentVerified || config.receiverAddress === ZERO || BigInt(config.writeGasLimit) === 0n) {
      throw new Error("Live mode requires verified deployment, receiver and measured positive gas budget");
    }
    if (BigInt(config.writeGasLimit) > 10_000_000n) throw new Error("Gas budget exceeds current 10M transaction quota");
  }
}
const errorText = (e: unknown) => String(e).slice(0, 240);

/** At most one write per invocation. Re-read on the next execution; never assume a write
 * changed finalized state immediately. The receiver and target remain the authorization boundary. */
export function execute(config: Config, triggerName: string, io: IO): Entry[] {
  validate(config);
  const trigger = config.triggers.find(t => t.name === triggerName);
  if (!trigger || !trigger.enabled || config.mode === "disabled") return [{ id: triggerName, status: "disabled" }];
  const results: Entry[] = [];
  const dispatch = (id: string, target: Address, data: Hex): boolean => {
    if (config.mode !== "live") {
      results.push({ id, status: "preview", detail: JSON.stringify({ target, calldata: data }) });
      return false;
    }
    // Authorization/preconditions are simulated as the immediate receiver caller.
    // Failed simulation is not a successful maintenance action.
    io.simulate(target, data);
    const txHash = io.write(target, data);
    results.push({ id, status: "report-delivered-verify-target-events", detail: txHash });
    return true;
  };
  if (config.kind === "monitor" || config.kind === "policy-preview") {
    for (const observation of config.observations) {
      try {
        const value = io.read(observation);
        const ok = observation.expect === undefined || compare(selected(value, observation.index), "eq", observation.expect);
        results.push({ id: observation.id, status: ok ? "observed" : "alert", detail: JSON.stringify(value, (_, v) => typeof v === "bigint" ? v.toString() : v) });
      } catch (e) { results.push({ id: observation.id, status: "read-error", detail: errorText(e) }); }
    }
    // No transaction, including simulation of privileged actions, from policy templates.
    if (config.kind === "monitor") return results;
  }
  if (config.kind === "upkeep") {
    const target = config.targetAddress! as Address;
    const check = io.read({ target, signature: "function checkUpkeep(bytes) view returns (bool,bytes)", args: ["0x"] });
    if (!Array.isArray(check) || typeof check[0] !== "boolean" || typeof check[1] !== "string") throw new Error("Invalid checkUpkeep result");
    if (!check[0]) return [{ id: "upkeep", status: "no-work" }];
    dispatch("upkeep", target, encode({ target, signature: "function performUpkeep(bytes)", args: [check[1]] }));
    return results;
  }
  for (const action of config.actions.filter(a => a.enabled && (!trigger.actionIds.length || trigger.actionIds.includes(a.id)))) {
    try {
      const ready = action.guards.every(g => compare(selected(io.read(g), g.index), g.op, g.expected));
      if (!ready) { results.push({ id: action.id, status: "not-ready" }); continue; }
      if (config.kind === "policy-preview") {
        results.push({ id: action.id, status: "policy-preview-only", detail: encode(action) });
      } else if (dispatch(action.id, action.target as Address, encode(action))) break;
    } catch (e) {
      // Do not continue after a write failure: receipt may be uncertain. Runtime write errors
      // are fatal; preflight/read failures remain visible to the operator.
      if (e instanceof DeliveryError) throw e;
      results.push({ id: action.id, status: "blocked-or-read-error", detail: errorText(e) });
    }
  }
  return results;
}
export class DeliveryError extends Error {}
