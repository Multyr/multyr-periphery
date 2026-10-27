/** Read-only. RPC_URL=... node scripts/rebalance-gas-shadow.ts STRATEGY [PREPARE_TX STEP_TX ...] */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, isAddress, parseAbi, parseEventLogs, type Address, type Hex } from "viem";
import { receiptFeeWei } from "../src/rebalance-gas.ts";

const [strategy, ...hashes] = process.argv.slice(2);
if (!strategy || !isAddress(strategy) || !process.env.RPC_URL) throw new Error("Provide STRATEGY and RPC_URL; optional ordered rebalance transaction hashes");
const root = fileURLToPath(new URL("../../../multyr-strategies/out/", import.meta.url));
const abi = (file: string, contract: string) => JSON.parse(readFileSync(`${root}/${file}.sol/${contract}.json`, "utf8")).abi;
const gateAbi = abi("StrategyRebalanceGateModule", "StrategyRebalanceGateModule");
const estimatorAbi = abi("ReadOnlyGasEstimator", "ReadOnlyGasEstimator");
const client = createPublicClient({ transport: http(process.env.RPC_URL) });
const block = await client.getBlockNumber();
const estimator = await client.readContract({ address: strategy, abi: parseAbi(["function rebalanceGasEstimator() view returns(address)"]), functionName: "rebalanceGasEstimator", blockNumber: block }) as Address;
const preview = await client.readContract({ address: strategy, abi: gateAbi, functionName: "previewRebalanceGas", blockNumber: block });
const scoringAbi = abi("StrategyScoringModule", "StrategyScoringModule");
const scoring = await client.readContract({ address: strategy, abi: scoringAbi, functionName: "computeRebalanceInputs", blockNumber: block }) as [number[], Address[], bigint[], bigint, bigint, bigint[]];
const candidate = preview as [Array<{adapter: Address; amount: bigint; deposit: boolean}>, unknown];
let weightedAnnualDelta = 0n;
for (const action of candidate[0]) {
  const at = scoring[1].findIndex(a => a.toLowerCase() === action.adapter.toLowerCase());
  if (at < 0) throw new Error("Candidate adapter absent from scoring inputs");
  const amount = action.amount * BigInt(scoring[0][at]);
  weightedAnnualDelta += action.deposit ? amount : -amount;
}
const annualYieldChangeUSDC = weightedAnnualDelta / 10000n;
const expectedPortfolioAPYChangeBps = scoring[3] > 0n ? weightedAnnualDelta / scoring[3] : null;
const gate = await client.readContract({ address: strategy, abi: gateAbi, functionName: "canRebalance", blockNumber: block });
const receipts = [];
let actualWei = 0n;
let actualUSDC: bigint | null = 0n;
let prepareQuote: any = null;
let preparations = 0;
let completed = false;
let cancelled = false;
let previousBlock = 0n;
const seen = new Set<string>();
for (const hash of hashes) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash) || seen.has(hash.toLowerCase())) throw new Error("Invalid or duplicate transaction hash");
  seen.add(hash.toLowerCase());
  const receipt = await client.getTransactionReceipt({ hash: hash as Hex });
  if (receipt.blockNumber < previousBlock) throw new Error("Supply receipts chronologically");
  previousBlock = receipt.blockNumber;
  const events = parseEventLogs({ abi: gateAbi, logs: receipt.logs }).filter(e => e.address.toLowerCase() === strategy.toLowerCase()) as unknown as { eventName: string; args: any }[];
  const planEvents = events.filter(e => ["RebalancePlanCreated", "RebalanceStepExecuted", "RebalancePlanCancelled", "Rebalanced", "RebalanceEconomicsInvalidated"].includes(e.eventName));
  if (planEvents.length === 0) throw new Error(`Transaction ${hash} has no rebalance lifecycle event for this strategy`);
  if (events.some(e => e.eventName === "RebalancePlanCreated")) {
    preparations++;
    prepareQuote = events.find(e => e.eventName === "RebalanceGasEvaluated")?.args ?? null;
  }
  completed ||= events.some(e => e.eventName === "Rebalanced");
  cancelled ||= events.some(e => e.eventName === "RebalancePlanCancelled");
  const feeWei = receiptFeeWei(receipt);
  const [valid, eth, usdc] = await client.readContract({ address: estimator, abi: estimatorAbi, functionName: "validatedPrices", blockNumber: receipt.blockNumber }) as [boolean,bigint,bigint];
  const feeUSDC = valid ? (feeWei * eth + usdc * 10n**12n - 1n) / (usdc * 10n**12n) : null;
  actualWei += feeWei;
  actualUSDC = actualUSDC === null || feeUSDC === null ? null : actualUSDC + feeUSDC;
  receipts.push({ hash, block: receipt.blockNumber, gasUsed: receipt.gasUsed, feeWei, feeUSDC, events });
}
console.log(JSON.stringify({ strategy, estimator, block, preview, gate, annualYieldChangeUSDC, expectedPortfolioAPYChangeBps, receipts, actualWei, actualUSDC,
  preparations, completed, cancelled, prepareQuote,
  // Caller-supplied receipts may omit steps: never label this an independently verified complete cost.
  scope: "Sum of supplied wrapper receipts; verify all plan steps are included before calibration",
  suppliedCostErrorBps: preparations === 1 && completed && !cancelled && prepareQuote?.costUSDC > 0n && actualUSDC !== null
    ? (actualUSDC - prepareQuote.costUSDC) * 10000n / prepareQuote.costUSDC : null,
}, (_, v) => typeof v === "bigint" ? v.toString() : v, 2));
