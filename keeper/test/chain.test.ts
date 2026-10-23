import assert from "node:assert/strict";
import { test } from "node:test";
import { ChainClient } from "../src/chain.ts";

function fixture(pending: number[], statuses = ["success", "success"]) {
  const sent: number[] = [];
  const chain = Object.create(ChainClient.prototype) as ChainClient;
  Object.assign(chain, {
    dryRun: false, from: "0x0000000000000000000000000000000000000001",
    maxFeePerGas: 100n, gasLimitMultiplier: 1.5, confirmedNonceFloor: 0,
    pub: {
      simulateContract: async () => ({ request: {} }),
      estimateFeesPerGas: async () => ({ maxFeePerGas: 1n }),
      estimateContractGas: async () => 100n,
      getTransactionCount: async () => pending.shift(),
      waitForTransactionReceipt: async () => ({ status: statuses.shift(), gasUsed: 100n, effectiveGasPrice: 1n }),
    },
    wallet: { writeContract: async ({ nonce }: { nonce: number }) => { sent.push(nonce); return "0x01"; } },
  });
  return { chain, sent };
}
const req = { label: "test", address: "0x0000000000000000000000000000000000000002" as const, abi: [], functionName: "perform" };
test("a stale pending nonce cannot reuse a confirmed mined nonce", async () => {
  const { chain, sent } = fixture([3296, 3296]);
  await chain.write(req); await chain.write(req);
  assert.deepEqual(sent, [3296, 3297]);
});
test("reverted mined transactions consume a nonce and newer RPC nonces take precedence", async () => {
  const { chain, sent } = fixture([10, 10, 15], ["reverted", "success", "success"]);
  assert.equal((await chain.write(req)).status, "reverted");
  await chain.write(req); await chain.write(req);
  assert.deepEqual(sent, [10, 11, 15]);
});
