/** Historical PDF cycle replay. Source RPC is read-only; writes require a local Anvil fork. */
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { encodeFunctionData, parseAbi, type Address } from "viem";

export type Rpc = (method: string, params?: unknown[]) => Promise<any>;
type Recorded = { row: number; hash: string; block: number; timestamp: number; tx: any };
export const manifest = JSON.parse(await readFile(new URL("./pdf-cycle-manifest.json", import.meta.url), "utf8"));
const abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function adapterCount() view returns (uint256)",
  "function adapters(uint256) view returns (address)",
  "function enabled(address) view returns (bool)",
  "function positionAssets(address) view returns (uint256)",
  "function deployIdle()",
  "function selectiveRecall(address[])",
]);
const hex = (n: number | bigint) => `0x${n.toString(16)}`;
function requireThat(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}

export function assertLocalUrl(value: string): void {
  const u = new URL(value);
  requireThat(["http:", "https:"].includes(u.protocol) &&
    ["127.0.0.1", "localhost", "[::1]"].includes(u.hostname) && !u.username && !u.password,
  "FORK_RPC_URL must be a loopback HTTP URL without credentials");
}

export function rpcAt(url: string): Rpc {
  let id = 0;
  return async (method, params = []) => {
    // Reject redirects so a local endpoint cannot redirect a write remotely.
    let response: Response;
    try {
      response = await fetch(url, {
        method: "POST", redirect: "error", signal: AbortSignal.timeout(60_000),
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
      });
    } catch (error) {
      const code = (error as { cause?: { code?: string } }).cause?.code;
      throw new Error(`${method}: RPC connection failed or timed out${code ? ` (${code})` : ""}`);
    }
    requireThat(response.ok, `${method}: HTTP ${response.status}`);
    const body = await response.json() as any;
    requireThat(!body.error, `${method}: RPC error ${body.error?.code ?? "unknown"}`);
    return body.result;
  };
}

export function validateRecords(records: Recorded[]): Recorded[] {
  requireThat(records.length === 56, "Expected all 56 PDF transactions");
  for (const r of records) {
    requireThat(r.hash.toLowerCase() === manifest.transactions[r.row - 1]?.toLowerCase(), "Manifest hash mismatch");
    requireThat(r.tx.hash.toLowerCase() === r.hash.toLowerCase(), "RPC transaction hash mismatch");
    requireThat(r.tx.from.toLowerCase() === manifest.signer.toLowerCase(), `Row ${r.row}: unexpected sender`);
    requireThat(r.tx.to && r.tx.input?.startsWith("0x") && BigInt(r.tx.value) === 0n,
      `Row ${r.row}: unexpected deployment or ETH transfer`);
  }
  requireThat(new Set(records.map(r => r.row)).size === 56, "Duplicate PDF row");
  // PDF row 35 (Euler capacity) happened BEFORE row 32. Never replay page order.
  const sorted = [...records].sort((a, b) => a.block - b.block || Number(BigInt(a.tx.transactionIndex) - BigInt(b.tx.transactionIndex)));
  requireThat(sorted[0].block === manifest.forkBlock + 1, "Unexpected starting block");
  return sorted;
}

export async function loadRecords(source: Rpc): Promise<Recorded[]> {
  requireThat(Number(BigInt(await source("eth_chainId"))) === manifest.chainId, "Source must be Arbitrum One");
  const records: Recorded[] = [];
  for (let i = 0; i < manifest.transactions.length; i += 4) {
    const batch = await Promise.all(manifest.transactions.slice(i, i + 4).map(async (hash: string, j: number) => {
      const [tx, receipt] = await Promise.all([
        source("eth_getTransactionByHash", [hash]), source("eth_getTransactionReceipt", [hash]),
      ]);
      requireThat(tx && receipt && BigInt(receipt.status) === 1n, `Row ${i + j + 1}: missing or failed source transaction`);
      const block = await source("eth_getBlockByHash", [tx.blockHash, false]);
      requireThat(block && receipt.blockHash === tx.blockHash && block.hash === tx.blockHash,
        `Row ${i + j + 1}: inconsistent source block`);
      return { row: i + j + 1, hash, block: Number(BigInt(tx.blockNumber)), timestamp: Number(BigInt(block.timestamp)), tx };
    }));
    records.push(...batch);
  }
  return validateRecords(records);
}

export async function verifyFork(fork: Rpc, source: Rpc): Promise<void> {
  const [version, chain, info, block, origin] = await Promise.all([
    fork("web3_clientVersion"), fork("eth_chainId"), fork("anvil_nodeInfo"),
    fork("eth_getBlockByNumber", ["latest", false]),
    source("eth_getBlockByNumber", [hex(manifest.forkBlock), false]),
  ]);
  requireThat(/anvil/i.test(version), "Replay requires Anvil");
  requireThat(Number(BigInt(chain)) === manifest.chainId, "Fork must use Arbitrum chain ID");
  requireThat(info.forkConfig && Number(info.forkConfig.forkBlockNumber) === manifest.forkBlock,
    "Anvil must be forked at the manifest block");
  requireThat(Number(BigInt(block.number)) === manifest.forkBlock && block.hash === origin?.hash,
    "Fork must be pristine and match the historical source block; restart Anvil");
  requireThat(await fork("anvil_getAutomine"), "Anvil automining must be enabled");
}

async function readUint(rpc: Rpc, target: string, name: string, args: unknown[] = []): Promise<bigint> {
  const data = encodeFunctionData({ abi, functionName: name as any, args: args as any });
  return BigInt(await rpc("eth_call", [{ to: target, data }, "latest"]));
}

export async function replay(fork: Rpc, records: Recorded[], report: any): Promise<void> {
  const snapshot = await fork("evm_snapshot");
  try {
    await fork("anvil_impersonateAccount", [manifest.signer]);
    await fork("anvil_setBalance", [manifest.signer, hex(10n ** 19n)]);
    const count = Number(await readUint(fork, manifest.strategyVault, "adapterCount"));
    requireThat(count === 7, `Expected seven adapters, got ${count}`);
    const adapters: Address[] = [];
    for (let i = 0; i < count; i++) {
      const n = await readUint(fork, manifest.strategyVault, "adapters", [BigInt(i)]);
      adapters.push(`0x${n.toString(16).padStart(40, "0")}`);
    }
    const initialShares = await readUint(fork, manifest.coreVault, "balanceOf", [manifest.signer]);
    requireThat(initialShares === 0n, "PDF signer must start with zero shares");
    const funded = new Set<string>();
    const deploySelector = encodeFunctionData({ abi, functionName: "deployIdle" }).slice(0, 10);
    let beforeExit = 0n;
    for (const r of records) {
      if (r.row === 55) beforeExit = await readUint(fork, manifest.usdc, "balanceOf", [manifest.signer]);
      // Preserve cooldown timestamps, not the intervening unrelated L2 blocks.
      // Bulk empty-block mining advances Anvil's clock and can overshoot the
      // next historical timestamp (Arbitrum has multiple blocks per second).
      await fork("evm_setNextBlockTimestamp", [r.timestamp]);
      const transaction = {
        from: manifest.signer, to: r.tx.to, data: r.tx.input, value: r.tx.value,
        gas: hex(BigInt(r.tx.gas) * 2n),
      };
      const hash = await fork("eth_sendTransaction", [transaction]);
      // Fork execution may still be fetching remote storage after send returns.
      let receipt;
      const deadline = Date.now() + 120_000;
      do {
        receipt = await fork("eth_getTransactionReceipt", [hash]);
        if (receipt) break;
        await new Promise(resolve => setTimeout(resolve, 500));
      } while (Date.now() < deadline);
      requireThat(receipt, `Row ${r.row}: receipt unavailable`);
      report.transactions.push({ pdfRow: r.row, originalHash: r.hash, replayHash: hash, receipt });
      requireThat(BigInt(receipt.status) === 1n, `Row ${r.row} reverted; see report`);
      console.log(`PDF row ${r.row}: ${hash}`);
      if (r.row === 5) requireThat(await readUint(fork, manifest.coreVault, "balanceOf", [manifest.signer]) > 0n, "Deposit minted no shares");
      if (r.tx.to.toLowerCase() === manifest.strategyVault.toLowerCase() && r.tx.input.slice(0, 10) === deploySelector) {
        const enabled = [];
        for (const a of adapters) if (await readUint(fork, manifest.strategyVault, "enabled", [a])) enabled.push(a);
        requireThat(enabled.length === 1, `Row ${r.row}: adapter isolation failed`);
        requireThat(await readUint(fork, manifest.strategyVault, "positionAssets", [enabled[0]]) > 0n,
          `Row ${r.row}: deployIdle succeeded but adapter received no recorded position`);
        funded.add(enabled[0]);
      }
      // Each explicit recall is immediately followed by an adapter switch or final exit.
      if ([15, 20, 25, 30, 36, 41, 52].includes(r.row)) {
        for (const a of adapters) requireThat(await readUint(fork, manifest.strategyVault, "positionAssets", [a]) <= 1n,
          `Row ${r.row}: recall left a position in ${a}`);
      }
      if (r.row === 55) {
        const received = await readUint(fork, manifest.usdc, "balanceOf", [manifest.signer]) - beforeExit;
        requireThat(received > 0n, "Withdrawal returned no USDC");
        report.withdrawnUsdcUnits = received.toString();
      }
    }
    requireThat(funded.size === 7, "Not all seven adapters received funds");
    requireThat(await readUint(fork, manifest.coreVault, "balanceOf", [manifest.signer]) === 0n, "Exit left signer shares");
    for (const a of adapters) requireThat(await readUint(fork, manifest.strategyVault, "enabled", [a]) === 1n, "Adapter not restored");
    report.passed = true;
  } finally {
    // Restore ALL fork state even on a partial failure, including admin overrides.
    try { await fork("anvil_stopImpersonatingAccount", [manifest.signer]); }
    finally {
      report.forkRestored = await fork("evm_revert", [snapshot]);
      requireThat(report.forkRestored, "Could not restore fork snapshot; restart Anvil");
    }
  }
}

async function main(): Promise<void> {
  const mode = process.argv[2] ?? "plan";
  requireThat(["plan", "replay"].includes(mode), "Usage: node scripts/pdf-cycle.ts [plan|replay]");
  const sourceUrl = process.env.SOURCE_RPC_URL;
  requireThat(sourceUrl, "Set SOURCE_RPC_URL to an Arbitrum archive RPC (read-only)");
  const source = rpcAt(sourceUrl);
  const report: any = { mode, chainId: manifest.chainId, forkBlock: manifest.forkBlock, passed: false, transactions: [] };
  const output = process.env.CYCLE_REPORT ?? "pdf-cycle-report.json";
  try {
    const records = await loadRecords(source);
    report.plan = records.map(r => ({ pdfRow: r.row, originalHash: r.hash, block: r.block, timestamp: r.timestamp, to: r.tx.to, data: r.tx.input }));
    if (mode === "plan") { console.log(`Validated ${records.length} historical transactions; no writes sent.`); return; }
    const forkUrl = process.env.FORK_RPC_URL ?? "http://127.0.0.1:8545";
    assertLocalUrl(forkUrl);
    const fork = rpcAt(forkUrl);
    await verifyFork(fork, source);
    await replay(fork, records, report);
    console.log("PASS: all seven adapters funded and recalled, exit completed, fork restored.");
  } catch (error) {
    report.passed = false;
    report.error = error instanceof Error ? error.message : "Unknown failure";
    throw error;
  } finally {
    await writeFile(output, JSON.stringify(report, null, 2) + "\n");
    console.log(`Report: ${output}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
