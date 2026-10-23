import { test } from "node:test";
import assert from "node:assert/strict";
import { receiptFeeWei } from "../src/rebalance-gas.ts";

test("receipt fee includes Arbitrum poster gas exactly once", () => {
  const receipt = { gasUsed: 120_000n, effectiveGasPrice: 20_000_000n, gasUsedForL1: 20_000n };
  assert.equal(receiptFeeWei(receipt), 2_400_000_000_000n);
});

import { encodeAbiParameters, encodeEventTopics, type TransactionReceipt } from "viem";
import { rebalanceGasEvents, rebalanceGasObservations } from "../src/rebalance-gas.ts";

test("quote observations retain plan scope and one wrapper receipt fee", () => {
  const strategy = "0x0000000000000000000000000000000000000011" as const;
  const actionsHash = `0x${"11".repeat(32)}` as const;
  const receipt = {
    transactionHash: `0x${"22".repeat(32)}`, blockNumber: 100n,
    gasUsed: 120_000n, effectiveGasPrice: 20_000_000n,
    logs: [{ address: strategy,
      topics: encodeEventTopics({ abi: rebalanceGasEvents, eventName: "RebalanceGasEvaluated", args: { actionsHash } }),
      data: encodeAbiParameters([{type:"uint256"},{type:"uint256"},{type:"uint256"},{type:"bool"}], [500_000n, 6_000_000n, 123n, true]),
    }],
  } as unknown as TransactionReceipt;
  const observations = rebalanceGasObservations(receipt);
  assert.equal(observations.length, 1);
  assert.equal(observations[0].strategy, strategy);
  assert.equal(observations[0].transactionFeeWei, 2_400_000_000_000n);
  assert.equal(observations[0].comparisonScope, "remaining-plan-quote-versus-single-transaction");
  assert.equal((observations[0] as any).costUSDC, 500_000n);
});

test("rebalance score observations preserve action hash and adapter alignment", () => {
  const strategy = "0x0000000000000000000000000000000000000011" as const;
  const adapter = "0x0000000000000000000000000000000000000022" as const;
  const actionsHash = `0x${"33".repeat(32)}` as const;
  const receipt = {
    transactionHash: `0x${"44".repeat(32)}`, blockNumber: 100n,
    gasUsed: 120_000n, effectiveGasPrice: 20_000_000n,
    logs: [{ address: strategy,
      topics: encodeEventTopics({ abi: rebalanceGasEvents, eventName: "RebalanceScores", args: { actionsHash } }),
      data: encodeAbiParameters(
        [{type:"address[]"},{type:"uint256[]"},{type:"uint16[]"},{type:"uint256[]"},{type:"uint256"}],
        [[adapter], [10_000n], [250], [100_000_000n], 100_000_000n]),
    }],
  } as unknown as TransactionReceipt;
  const [observation] = rebalanceGasObservations(receipt);
  assert.equal(observation.event, "RebalanceScores");
  assert.equal((observation as any).actionsHash, actionsHash);
  assert.deepEqual((observation as any).adapters, [adapter]);
  assert.deepEqual((observation as any).normalizedScores, [10_000n]);
  assert.deepEqual((observation as any).apyBps, [250]);
});
