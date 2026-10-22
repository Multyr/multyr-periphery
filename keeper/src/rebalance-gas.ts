import { parseAbi, parseEventLogs, type TransactionReceipt } from "viem";

export const rebalanceGasEvents = parseAbi([
  "event ExecutionGasObserved(address indexed adapter,uint256 gasUsed,bool deposit)",
  "event GasEmaUpdated(address indexed adapter,uint64 emaGas,bool isDeposit)",
  "event RebalanceScores(bytes32 indexed actionsHash,address[] adapters,uint256[] normalizedScores,uint16[] apyBps,uint256[] targetAssets,uint256 tvl)",
  "event RebalanceDepositSkipped(address indexed adapter,uint256 amount)",
  "event RebalanceGasEvaluated(bytes32 indexed actionsHash,uint256 costUSDC,uint256 l2Gas,uint256 posterWei,bool reliable)",
  "event RebalanceEconomicsInvalidated()",
  "event RebalanceEconomicsEvaluated(uint256 movedUSDC,uint256 grossBenefitUSDC,uint256 gasCostUSDC,int256 netBenefitBps,bool accepted)",
]);

/** Arbitrum receipt gasUsed already includes poster gas. Do not add gasUsedForL1 again. */
export function receiptFeeWei(receipt: Pick<TransactionReceipt, "gasUsed" | "effectiveGasPrice">): bigint {
  return receipt.gasUsed * receipt.effectiveGasPrice;
}

export function rebalanceGasObservations(receipt: TransactionReceipt) {
  return parseEventLogs({ abi: rebalanceGasEvents, logs: receipt.logs }).map((event) => ({
    strategy: event.address,
    event: event.eventName,
    ...event.args,
    tx: receipt.transactionHash,
    block: receipt.blockNumber,
    transactionGasUsed: receipt.gasUsed,
    transactionFeeWei: receiptFeeWei(receipt),
    // A quote covers the remaining plan, whereas a receipt covers ONE wrapper transaction.
    comparisonScope: "remaining-plan-quote-versus-single-transaction",
  }));
}
