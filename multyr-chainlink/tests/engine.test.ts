import { describe, expect, test } from "bun:test";
import { configSchema, execute, validate, compare, encode, DeliveryError, ZERO, type IO } from "../suite/engine";
import { decodeFunctionData, parseAbi } from "viem";

const target = "0x0196b1fd654fcC5A61fe6E9431b39Be88BB32FFE";
function base(extra = {}) {
  return configSchema.parse({ mode: "preview", kind: "upkeep", chainSelectorName: "ethereum-mainnet-arbitrum-1",
    receiverAddress: ZERO, writeGasLimit: "0", targetAddress: target,
    triggers: [{ name: "tick", schedule: "0 */10 * * * *", enabled: true }], ...extra });
}
function fixture(result: unknown = [true, "0x1234"]) {
  const seen = { reads: 0, simulations: 0, writes: 0 };
  const io: IO = { read() { seen.reads++; return result; }, simulate() { seen.simulations++; }, write() { seen.writes++; return "0xabc"; } };
  return { io, seen };
}
const live = { mode: "live", receiverAddress: "0x1111111111111111111111111111111111111111", writeGasLimit: "1000000", deploymentVerified: true };
const actions = [0, 1].map(i => ({ id: `action-${i}`, target, signature: "function performUpkeep(bytes)", args: ["0x"] }));
describe("maintenance execution safety", () => {
  test("disabled does no reads, reports or transactions", () => {
    const { io, seen } = fixture(); execute(base({ mode: "disabled" }), "tick", io);
    expect(seen).toEqual({ reads: 0, simulations: 0, writes: 0 });
  });
  test("preview returns calldata but never submits or simulates a write", () => {
    const { io, seen } = fixture(); const result = execute(base(), "tick", io);
    expect(result[0].status).toBe("preview"); expect(seen.writes).toBe(0); expect(seen.simulations).toBe(0);
    const data = JSON.parse(result[0].detail!).calldata;
    expect(decodeFunctionData({ abi: parseAbi(["function performUpkeep(bytes)"]), data }).args).toEqual(["0x1234"]);
  });
  test("idle upkeep generates no report", () => {
    const { io, seen } = fixture([false, "0x"]); expect(execute(base(live), "tick", io)[0].status).toBe("no-work");
    expect(seen.writes).toBe(0);
  });
  test("rejects malformed check response", () => {
    const { io } = fixture(["true", "0x"]); expect(() => execute(base(), "tick", io)).toThrow("Invalid checkUpkeep");
  });
  test("requires explicit verification, receiver and positive bounded gas", () => {
    expect(() => validate(base({ mode: "live" }))).toThrow();
    expect(() => validate(base({ ...live, deploymentVerified: false }))).toThrow();
    expect(() => validate(base({ ...live, writeGasLimit: "10000001" }))).toThrow();
  });
  test("one write per run, even with two eligible actions", () => {
    const { io, seen } = fixture(); execute(base({ ...live, kind: "calls", actions }), "tick", io);
    expect(seen.writes).toBe(1); expect(seen.simulations).toBe(1);
  });
  test("trigger restricts action selection", () => {
    const { io } = fixture(); const config = base({ kind: "calls", actions,
      triggers: [{ name: "tick", schedule: "0 */10 * * * *", enabled: true, actionIds: ["action-1"] }] });
    expect(execute(config, "tick", io).map(e => e.id)).toEqual(["action-1"]);
  });
  test("false readiness guard prevents sending", () => {
    const { io, seen } = fixture(false);
    const config = base({ ...live, kind: "calls", actions: [{ ...actions[0], guards: [{ target, signature: "function ready() view returns (bool)", op: "eq", expected: true }] }] });
    expect(execute(config, "tick", io)[0].status).toBe("not-ready"); expect(seen.writes).toBe(0);
  });
  test("simulation revert never sends", () => {
    const { io, seen } = fixture(); io.simulate = () => { throw new Error("claim not ready"); };
    expect(execute(base({ ...live, kind: "calls", actions }), "tick", io)[0].status).toBe("blocked-or-read-error");
    expect(seen.writes).toBe(0);
  });
  test("uncertain delivery aborts instead of sending next action", () => {
    const { io, seen } = fixture(); io.write = () => { seen.writes++; throw new DeliveryError("unknown receipt"); };
    expect(() => execute(base({ ...live, kind: "calls", actions }), "tick", io)).toThrow(DeliveryError);
    expect(seen.writes).toBe(1);
  });
  test("policy writes rejected even with configured live receiver", () => {
    expect(() => validate(base({ ...live, kind: "policy-preview", actions }))).toThrow("preview-only");
  });
  test("monitor flags deviations and never writes", () => {
    const { io, seen } = fixture(true);
    const result = execute(base({ kind: "monitor", observations: [{ id: "paused", target, signature: "function paused() view returns (bool)", expect: false }] }), "tick", io);
    expect(result[0].status).toBe("alert"); expect(seen.writes).toBe(0);
  });
  test("integer values above Number precision remain exact", () => {
    expect(compare(9007199254740993n, "gt", "9007199254740992")).toBe(true);
    const data = encode({ target, signature: "function setValue(uint256)", args: ["9007199254740993"] });
    expect(decodeFunctionData({ abi: parseAbi(["function setValue(uint256)"]), data }).args).toEqual([9007199254740993n]);
  });
});
