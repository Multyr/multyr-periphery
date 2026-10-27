import { test } from "node:test";
import assert from "node:assert/strict";
import { assertLocalUrl, manifest, replay, validateRecords, verifyFork, type Rpc } from "../scripts/pdf-cycle.ts";

test("replay rejects remote RPCs and credential-bearing URLs", () => {
  for (const url of ["https://arb1.arbitrum.io/rpc", "http://127.0.0.1.evil.test", "file:///tmp/rpc", "http://user:secret@localhost:8545"]) {
    assert.throws(() => assertLocalUrl(url));
  }
  for (const url of ["http://127.0.0.1:8545", "http://localhost:8545", "http://[::1]:8545"]) assertLocalUrl(url);
});

function records() {
  return manifest.transactions.map((hash: string, i: number) => ({
    row: i + 1, hash, block: manifest.forkBlock + i + 1, timestamp: 100 + i,
    tx: { hash, from: manifest.signer, to: manifest.coreVault, input: "0x12345678", value: "0x0", transactionIndex: "0x0" },
  }));
}

test("replays chronological order, including Euler capacity before Morpho", () => {
  const rows = records();
  rows[34].block = rows[31].block;
  rows[31].block += 1;
  rows[32].block += 1;
  rows[33].block += 1;
  const sorted = validateRecords(rows);
  assert.ok(sorted.findIndex(r => r.row === 35) < sorted.findIndex(r => r.row === 32));
});

test("incomplete, duplicate, altered-hash and foreign-sender plans fail", () => {
  assert.throws(() => validateRecords(records().slice(1)));
  const duplicate = records(); duplicate[1] = duplicate[0];
  assert.throws(() => validateRecords(duplicate));
  const foreign = records(); foreign[0].tx.from = "0x0000000000000000000000000000000000000001";
  assert.throws(() => validateRecords(foreign));
  const altered = records(); altered[0].tx.hash = manifest.transactions[1];
  assert.throws(() => validateRecords(altered));
});

test("fork verification rejects an advanced or mismatched fork without writes", async () => {
  const calls: string[] = [];
  const rpc: Rpc = async (method) => {
    calls.push(method);
    return ({ web3_clientVersion: "anvil/v1", eth_chainId: "0xa4b1",
      anvil_nodeInfo: { forkConfig: { forkBlockNumber: manifest.forkBlock } },
      eth_getBlockByNumber: { number: `0x${(manifest.forkBlock + 1).toString(16)}`, hash: "0xwrong" },
    } as any)[method];
  };
  await assert.rejects(verifyFork(rpc, async () => ({ hash: "0xoriginal" })), /pristine/);
  assert.ok(!calls.some(m => m.includes("send") || m.includes("impersonate")));
});

test("partial replay failure stops impersonation and restores the whole snapshot", async () => {
  const calls: string[] = [];
  const rpc: Rpc = async (method) => {
    calls.push(method);
    if (method === "evm_snapshot") return "0x1";
    if (method === "eth_call") throw new Error("archive unavailable");
    if (method === "evm_revert") return true;
  };
  const report: any = { transactions: [] };
  await assert.rejects(replay(rpc, [], report), /archive unavailable/);
  assert.deepEqual(calls.slice(-2), ["anvil_stopImpersonatingAccount", "evm_revert"]);
  assert.equal(report.forkRestored, true);
});

test("successful receipt with no minted shares fails the deposit assertion and rolls back", async () => {
  let reads = 0;
  let receiptReads = 0;
  let restored = false;
  const rpc: Rpc = async (method) => {
    if (method === "evm_snapshot") return "0x1";
    if (method === "eth_call") {
      reads++;
      if (reads === 1) return "0x7"; // seven registered adapters
      if (reads <= 8) return `0x${reads.toString(16)}`;
      return "0x0"; // initial and post-deposit share balance: zero
    }
    if (method === "eth_blockNumber") return `0x${manifest.forkBlock.toString(16)}`;
    if (method === "eth_sendTransaction") return "0xreplay";
    if (method === "eth_getTransactionReceipt") return ++receiptReads === 1 ? null : { status: "0x1" };
    if (method === "evm_revert") { restored = true; return true; }
  };
  const deposit = records()[4]; deposit.tx.gas = "0x100000";
  const report: any = { transactions: [] };
  await assert.rejects(replay(rpc, [deposit], report), /Deposit minted no shares/);
  assert.equal(report.transactions.length, 1);
  assert.equal(receiptReads, 2);
  assert.equal(restored, true);
  assert.notEqual(report.passed, true);
});
