import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { encodeAbiParameters, keccak256, toHex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { secp256k1 } from "@noble/curves/secp256k1";
import { parseChainConfig } from "../src/config.ts";
import { DueGate } from "../src/gate.ts";
import { distributeWindow } from "../src/jobs/feeCollector.ts";
import { dueBatches } from "../src/jobs/liquidity.ts";
import { describePerformData } from "../src/jobs/upkeep.ts";
import { warmNavDue } from "../src/jobs/warmNav.ts";
import { kmsAccount, parseDerSignature, toEthSignature } from "../src/signers/kms.ts";

test("primary acts immediately; secondary waits out the grace window", () => {
  const p = new DueGate("primary", false);
  assert.equal(p.shouldAct("W1", 1000, 900).act, true);

  const s = new DueGate("secondary", false);
  assert.deepEqual(s.shouldAct("W1", 1000, 900), { act: false, waitSec: 900 });
  assert.deepEqual(s.shouldAct("W1", 1500, 900), { act: false, waitSec: 400 });
  assert.equal(s.shouldAct("W1", 1900, 900).act, true);
  s.clear("W1"); // primary cleared it
  assert.equal(s.shouldAct("W1", 2000, 900).act, false);
});

test("secondary uses on-chain dueSince when provided, even when stateless", () => {
  const s = new DueGate("secondary", true);
  assert.equal(s.shouldAct("W6", 1000, 180, 900).act, false);
  assert.equal(s.shouldAct("W6", 1080, 180, 900).act, true);
  // No derivable dueSince + stateless → act (grace comes from schedule offset).
  assert.equal(s.shouldAct("W1", 1000, 900).act, true);
});

test("weekly distribution window", () => {
  const w = { weekday: 1, hourUtc: 10, durationHours: 6 };
  const mon1030 = Date.UTC(2026, 8, 28, 10, 30) / 1000; // Mon 2026-09-28
  const r = distributeWindow(mon1030, w);
  assert.equal(r.start, Date.UTC(2026, 8, 28, 10, 0) / 1000);
  assert.equal(r.inside, true);

  const mon0900 = Date.UTC(2026, 8, 28, 9, 0) / 1000;
  const r2 = distributeWindow(mon0900, w);
  assert.equal(r2.start, Date.UTC(2026, 8, 21, 10, 0) / 1000); // previous Monday
  assert.equal(r2.inside, false);

  const thu = Date.UTC(2026, 9, 1, 12, 0) / 1000;
  assert.equal(distributeWindow(thu, w).inside, false);
});

test("liquidity batches only include stale adapters' batches", () => {
  const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as const;
  const adapters = [
    { adapter: A(1), cachedTs: 1000 },
    { adapter: A(2), cachedTs: 5000 },
    { adapter: A(3), cachedTs: 5000 },
    { adapter: A(4), cachedTs: 0 }, // never cached
    { adapter: A(5), cachedTs: 5000 },
  ];
  // maxAge 3600, margin 300 → due when now >= ts + 3300
  const b = dueBatches(adapters, 5000, 3600, 300, 2);
  assert.deepEqual(b, [
    { start: 0, end: 2, dueSince: 4300 },
    { start: 2, end: 4, dueSince: 3300 },
  ]);
  assert.deepEqual(dueBatches(adapters.slice(1, 3), 5000, 3600, 300, 2), []);
});

test("warm NAV due on age or invalid", () => {
  assert.deepEqual(warmNavDue(1000, 500, true, 600, 120), { due: true, dueSince: 980 });
  assert.equal(warmNavDue(900, 500, true, 600, 120).due, false);
  assert.deepEqual(warmNavDue(600, 500, false, 600, 120), { due: true, dueSince: 500 });
});

test("performData decoding matches each upkeep's encoding", () => {
  const vault = encodeAbiParameters([{ type: "uint8" }, { type: "uint256" }], [2, 7n]);
  assert.deepEqual(describePerformData("vault", vault), { op: "EPOCH_FUND", arg: 7n });
  const strat = encodeAbiParameters([{ type: "uint8" }, { type: "uint256" }], [6, 0n]);
  assert.deepEqual(describePerformData("strategy", strat), { op: "EXECUTE_REBALANCE_STEP", strategyIndex: 0n });
  const claims = encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256[]" }, { type: "uint256" }, { type: "uint256" }],
    [3n, [1n, 2n], 3n, 3n],
  );
  assert.deepEqual(describePerformData("claims", claims), {
    op: "SETTLE_CLAIMS",
    epochId: 3n,
    claims: 2,
    nextEpoch: 3n,
    nextClaim: 3n,
  });
});

test("shipped arbitrum config parses and covers W1-W6", () => {
  const raw = JSON.parse(readFileSync(new URL("../config/arbitrum-one.json", import.meta.url), "utf8"));
  const cfg = parseChainConfig(raw);
  assert.deepEqual(cfg.jobs.map((j) => j.id), ["W1", "W2", "W3", "W4", "W5", "W6"]);
});

// --- KMS signature plumbing, exercised with a local key standing in for the HSM ---

function derEncode(r: bigint, s: bigint): Uint8Array {
  const int = (x: bigint) => {
    let b = Buffer.from(x.toString(16).padStart(64, "0"), "hex");
    while (b.length > 1 && b[0] === 0 && !(b[1] & 0x80)) b = b.subarray(1);
    if (b[0] & 0x80) b = Buffer.concat([Buffer.from([0]), b]);
    return Buffer.concat([Buffer.from([0x02, b.length]), b]);
  };
  const body = Buffer.concat([int(r), int(s)]);
  return new Uint8Array(Buffer.concat([Buffer.from([0x30, body.length]), body]));
}

test("DER parse + low-s normalisation + recovery yields the key's address", async () => {
  const pk = generatePrivateKey();
  const acct = privateKeyToAccount(pk);
  const hash = keccak256(toHex("multyr"));
  const sig = secp256k1.sign(hash.slice(2), pk.slice(2), { lowS: true });
  // Force high-s, as KMS may return it.
  const highS = secp256k1.CURVE.n - sig.s;
  const der = derEncode(sig.r, highS);
  assert.deepEqual(parseDerSignature(der), { r: sig.r, s: highS });
  const eth = await toEthSignature(hash, der, acct.address);
  assert.equal(BigInt(eth.s), sig.s);

  const kms = kmsAccount(acct.publicKey, async (digest) => {
    const s2 = secp256k1.sign(digest, pk.slice(2), { lowS: false });
    return derEncode(s2.r, s2.s);
  });
  assert.equal(kms.address, acct.address);
  assert.equal(await kms.signMessage({ message: "hi" }), await acct.signMessage({ message: "hi" }));
});
