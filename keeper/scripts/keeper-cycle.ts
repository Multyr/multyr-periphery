/** Fork-only integration test using the production job classes and ChainClient. */
import { readFile, writeFile } from "node:fs/promises";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { encodeFunctionData, parseAbi, parseEventLogs, type Address, type Hex } from "viem";
import { ChainClient, type WriteRequest, type SendResult } from "../src/chain.ts";
import { parseChainConfig, type Config } from "../src/config.ts";
import { DueGate } from "../src/gate.ts";
import { buildJobs } from "../src/runner.ts";
import { strategyVaultAbi, bufferManagerAbi, feeCollectorAbi } from "../src/abis.ts";
import { assertLocalUrl, rpcAt, manifest, loadRecords, verifyFork } from "./pdf-cycle.ts";

const forkUrl = process.env.FORK_RPC_URL ?? "http://127.0.0.1:18545";
assertLocalUrl(forkUrl);
if (!process.env.SOURCE_RPC_URL) throw new Error("SOURCE_RPC_URL required");
const fork = rpcAt(forkUrl), source = rpcAt(process.env.SOURCE_RPC_URL);
const output = process.env.KEEPER_CYCLE_REPORT ?? "keeper-cycle-report.json";
const report: any = { mode: "local-fork-production-keepers", forkBlock: manifest.forkBlock, passed: false, transactions: [], checks: [], fixtures: [] };
const cfg: Config = {
  chain: parseChainConfig(JSON.parse(await readFile(new URL("../config/arbitrum-one.json", import.meta.url), "utf8"))),
  env: { instance: "primary", rpcUrls: [forkUrl], signer: "local" },
};
// Anvil's default priority fee can exceed production's 1 gwei cap. This is
// explicitly a local gas-price fixture, not a production config change.
cfg.chain.maxFeePerGasGwei = 10;
report.fixtures.push("Local gas price cap: 10 gwei (production config: 1 gwei)");
const account = privateKeyToAccount(generatePrivateKey());
report.keeperAddress = account.address;
let phase = "setup";
let fixtureGas: bigint | undefined;
class RecordingChain extends ChainClient {
  override async simulate(req: WriteRequest): Promise<{ok:true;request:unknown}|{ok:false;reason:string}> {
    if (!fixtureGas) return super.simulate(req);
    try {
      const { request } = await this.pub.simulateContract({ address: req.address, abi: req.abi,
        functionName: req.functionName, args: req.args ?? [], account: this.account, gas: fixtureGas } as any);
      return { ok: true, request };
    } catch (e) { return { ok: false, reason: e instanceof Error ? e.message : String(e) }; }
  }
  override async write(req: WriteRequest): Promise<SendResult> {
    const res = await super.write(req);
    const entry: any = { phase, label: req.label, target: req.address, functionName: req.functionName, args: req.args, status: res.status };
    if ("receipt" in res) {
      entry.receipt = res.receipt;
      entry.events = parseEventLogs({ abi: req.abi, logs: res.receipt.logs }).filter(l => l.address.toLowerCase() === req.address.toLowerCase());
    }
    if ("reason" in res) entry.reason = res.reason;
    report.transactions.push(entry);
    await save();
    return res;
  }
}
const chain = new RecordingChain(cfg, account, { dryRun: false });
const ctx = { chain, cfg, gate: new DueGate("primary", false) };
const jobs = buildJobs(cfg);
const A = cfg.chain.addresses;
const abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function owner() view returns (address)",
  "function governor() view returns (address)",
  "function grantRole(bytes32,address)",
  "function idleCash() view returns (uint256)",
  "function positionAssets(address) view returns (uint256)",
  "function currentEpochId() view returns (uint256)",
  "function requestEpochWithdrawal(uint256) returns (uint256,uint256)",
  "function epochClaim(uint256,uint256) view returns ((address user,uint64 requestedAt,bool claimed,uint256 assetsOwed,uint256 grossShares))",
  "function canCloseCurrentEpoch() view returns (bool)",
  "function canDeploy() view returns (bool)",
  "function nextClaimIdForEpoch(uint256) view returns (uint256)",
  "function getQueueParams(address) view returns ((uint8 maxClaimsPerUserPerEpoch,uint64 cooldownPerClaim,uint64 epochDuration))",
  "function setVaultQueueOverride(address,(uint8 maxClaimsPerUserPerEpoch,uint64 cooldownPerClaim,uint64 epochDuration))",
  "function setDefaultGovCaps(uint64,uint256,uint16,uint16,uint16,uint64,uint256,uint256,uint16)",
  "function minParamDelay(address) view returns (uint64)",
  "function maxPerfRate(address) view returns (uint256)",
  "function maxFeeBps(address) view returns (uint16)",
  "function maxImmediateExitPenaltyBps(address) view returns (uint16)",
  "function maxForceExitPenaltyBps(address) view returns (uint16)",
  "function guardianPauseCooldown(address) view returns (uint64)",
  "function minDeployAmount(address) view returns (uint256)",
  "function stratTaGas(address) view returns (uint256)",
  "function opsMaxBps(address) view returns (uint16)",
  "function oracleConfigFor(address,address) view returns (address,uint256)",
  "function getFeed(address) view returns (address)",
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
  "function setShareConfig(address,uint8)",
  "function getWithdrawalParams(address) view returns ((uint16 capPerEpochBps,uint256 maxWithdrawalPerBlock,uint256 maxWithdrawalPerTx,uint256 minClaimAmount,uint64 lockPeriod))",
  "function setVaultWithdrawalOverride(address,(uint16 capPerEpochBps,uint256 maxWithdrawalPerBlock,uint256 maxWithdrawalPerTx,uint256 minClaimAmount,uint64 lockPeriod))",
]);
async function save() { await writeFile(output, JSON.stringify(report, (_k,v) => typeof v === "bigint" ? v.toString() : v, 2)+"\n"); }
function check(ok: unknown, name: string, details?: unknown) {
  report.checks.push({ phase, name, passed: !!ok, details });
  if (!ok) throw new Error(name);
}
async function mineAt(ts: number) {
  const now = Number((await chain.pub.getBlock({ blockTag: "latest" })).timestamp);
  await fork("evm_setNextBlockTimestamp", [Math.max(ts, now + 1)]);
  await fork("evm_mine");
}
async function admin(to: Address, data: Hex, label: string, sender: Address = manifest.signer) {
  await fork("anvil_impersonateAccount", [sender]);
  const hash = await fork("eth_sendTransaction", [{ from: sender, to, data, gas: "0x989680" }]);
  const receipt = await chain.pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  report.transactions.push({ phase, label, actor: "fixture/user/admin", receipt });
  check(receipt.status === "success", label);
  await save();
  return receipt;
}
async function tick(id: string) {
  console.log(`Running ${id} (${phase})`);
  const job = jobs.find(j => j.id === id)!;
  const result = await job.tick(ctx);
  report.checks.push({ phase, job: id, tick: result });
  await save();
  return result;
}
function eventsSince(start: number): any[] {
  return report.transactions.slice(start).flatMap((t: any) => t.events ?? []);
}
let snapshot: string | undefined;
try {
  const records = await loadRecords(source);
  await verifyFork(fork, source);
  snapshot = await fork("evm_snapshot");
  await fork("anvil_setBalance", [account.address, "0x8ac7230489e80000"]);
  await fork("anvil_setBalance", [manifest.signer, "0x8ac7230489e80000"]);
  for (const row of records.filter(r => r.row <= 5)) {
    await mineAt(row.timestamp);
    await admin(row.tx.to, row.tx.input, `PDF row ${row.row}`);
  }
  const role = await chain.read<Hex>(A.strategyVault, strategyVaultAbi, "KEEPER_ROLE");
  await admin(A.strategyVault, encodeFunctionData({ abi, functionName: "grantRole", args: [role, account.address] }), "Fork fixture: grant W5 keeper role");
  report.fixtures.push("Ephemeral keeper wallet funded with local ETH and granted strategy KEEPER_ROLE for W5");
  for (const job of jobs) {
    try { report.checks.push(...await job.preflight(ctx)); }
    catch (e) { report.checks.push({ job: job.id, preflightError: String(e) }); }
  }
  let setupSnapshot = await fork("evm_snapshot");
  if (process.env.KEEPER_BASELINE_REPORT) {
    report.baseline = JSON.parse(await readFile(process.env.KEEPER_BASELINE_REPORT, "utf8"));
    check(report.baseline.baselineCompleted && report.baseline.forkBlock === manifest.forkBlock, "Baseline report matches historical fork");
  } else {
    phase = "baseline-all-jobs";
    for (const id of ["W6", "W5", "W1", "W2", "W3", "W4"]) {
      try { await tick(id); }
      catch (e) { report.checks.push({ job: id, error: String(e) }); }
    }
    check(await fork("evm_revert", [setupSnapshot]), "Restore after baseline");
    setupSnapshot = await fork("evm_snapshot");
  }
  report.baselineCompleted = true;
  // Baseline estimation can succeed at the outer try/catch while starving
  // an inner call. Isolate this in a second, explicitly budgeted test pass.
  fixtureGas = 6_000_000n;
  report.fixtures.push("Functional pass supplies 6,000,000 gas per keeper call; production auto-estimation is tested separately in baseline");
  const configAddress = records.find(r => r.row === 54)!.tx.to as Address;
  const governance = manifest.signer as Address;
  const encode = (name: string, args: any[]) => encodeFunctionData({ abi, functionName: name as any, args: args as any });
  const balance = (token: Address, user: Address) => chain.read<bigint>(token, abi, "balanceOf", [user]);
  phase = "funded-claims-and-fee-harvest";
  await mineAt((await chain.now()) + 601);
  await tick("W6");
  const nav = await chain.read<any>(A.bufferManager, bufferManagerAbi, "warmNavState");
  check(nav[2] && Number(nav[1]) >= (await chain.now()) - 30, "W6 warm NAV valid and refreshed");
  await tick("W5");
  const wp = await chain.read<any>(configAddress, abi, "getWithdrawalParams", [A.coreVault]);
  await admin(configAddress, encode("setVaultWithdrawalOverride", [A.coreVault, {...wp, capPerEpochBps: 1, lockPeriod: 0n}]), "Fixture: 1 bps instant cap and zero deposit lock");
  const qp = await chain.read<any>(configAddress, abi, "getQueueParams", [A.coreVault]);
  const governor = await chain.read<Address>(A.feeCollector, abi, "governor");
  await admin(A.feeCollector, encode("setShareConfig", [A.coreVault, 2]), "Fixture: enable AUTO_HARVEST", governor);
  report.fixtures.push("Queue scenario only: AUTO_HARVEST, 1 bps instant cap, zero deposit lock; original epoch duration retained");
  const queueStart = report.transactions.length;
  await tick("W4");
  check(await chain.read<bigint>(A.feeCollector, feeCollectorAbi, "pendingHarvestClaimCount", [A.coreVault]) > 0n, "W4 queued a fee harvest");
  const queued = eventsSince(queueStart).find((e: any) => e.eventName === "HarvestQueued");
  check(queued, "W4 emitted HarvestQueued");
  const queuedShares = BigInt(queued.args.shares);
  const epoch = await chain.read<bigint>(A.coreVault, abi, "currentEpochId");
  const claimId = await chain.read<bigint>(A.coreVault, abi, "nextClaimIdForEpoch", [epoch]);
  const shares = await balance(A.coreVault, governance);
  await admin(A.coreVault, encode("requestEpochWithdrawal", [shares]), "User requests queued withdrawal");
  const beforePayout = await balance(A.usdc, governance);
  // The fork has no future Chainlink heartbeats. Preserve the observed price,
  // decimals and round IDs while supplying current timestamps for the time jump.
  // Only the feed's two read methods are mocked; no keeper/claim state is patched.
  const [oracle] = await chain.read<[Address,bigint]>(configAddress,abi,"oracleConfigFor",[A.usdc,A.coreVault]);
  const feed = await chain.read<Address>(oracle,abi,"getFeed",[A.usdc]);
  const rd = await chain.read<any>(feed,abi,"latestRoundData");
  const decimals = await chain.read<number>(feed,abi,"decimals");
  const store = (v: bigint, offset: string) => `7f${BigInt.asUintN(256,v).toString(16).padStart(64,"0")}60${offset}52`;
  const latestCode = "5b"+store(rd[0],"00")+store(rd[1],"20")+"4260405242606052"+store(rd[4],"80")+"60a06000f3";
  const latestOffset = 33;
  const decimalOffset = latestOffset+latestCode.length/2;
  const dispatch = `60003560e01c8063feaf968c1461${latestOffset.toString(16).padStart(4,"0")}578063313ce5671461${decimalOffset.toString(16).padStart(4,"0")}5760006000fd`;
  await fork("anvil_setCode",[feed,`0x${dispatch}${latestCode}5b${store(BigInt(decimals),"00")}60206000f3`]);
  const mocked = await chain.read<any>(feed,abi,"latestRoundData");
  check(mocked[1] === rd[1] && mocked[0] === rd[0] && mocked[4] === rd[4], "Heartbeat fixture preserves observed price and round IDs");
  check(await chain.read<number>(feed,abi,"decimals") === decimals,"Heartbeat fixture preserves decimals");
  report.fixtures.push({kind:"future-oracle-heartbeat",feed,answer:rd[1],decimals,epochDuration:qp.epochDuration});
  await mineAt((await chain.now()) + Number(qp.epochDuration) + 1);
  await tick("W6");
  await tick("W1");
  await tick("W3");
  const claim = await chain.read<any>(A.coreVault, abi, "epochClaim", [epoch, claimId]);
  check(claim.claimed, "W3 paid the user's claim");
  check(await balance(A.usdc, governance) > beforePayout, "W3 transferred USDC to user");
  const harvestStart = report.transactions.length;
  await tick("W4");
  const w4Events = eventsSince(harvestStart);
  const settled = w4Events.find((e: any) => e.eventName === "HarvestSettled");
  check(settled && BigInt(settled.args.sharesRedeemed) === queuedShares, "W4 settled the queued fee harvest in full", settled?.args);
  check(w4Events.some((e: any) => e.eventName === "Distributed" && e.args.token.toLowerCase() === A.usdc.toLowerCase()),
    "W4 distributed the harvested USDC");
  check(await balance(A.usdc, A.feeCollector) === 0n, "W4 left no undistributed USDC");
  // The time jump lands inside the weekly window, so the same tick also runs
  // distribute(coreShares) on fee shares CRYSTALLIZE minted after the first
  // harvest; under AUTO_HARVEST that queues a new claim. Only that may remain.
  const pendingAfter = await chain.read<bigint>(A.feeCollector, feeCollectorAbi, "pendingHarvestClaimCount", [A.coreVault]);
  check(pendingAfter === 0n || w4Events.some((e: any) => e.eventName === "HarvestQueued"),
    "Any remaining fee claim was newly queued by this tick", { pendingAfter });
  report.pendingHarvestClaimsAfterW4 = pendingAfter;
  report.queueScenarioPassed = true;

  check(await fork("evm_revert", [setupSnapshot]), "Restore before PDF keeper cycle");
  phase = "pdf-keeper-cycle";
  const caps = await Promise.all(["minParamDelay", "maxPerfRate", "maxFeeBps", "maxImmediateExitPenaltyBps", "maxForceExitPenaltyBps", "guardianPauseCooldown", "minDeployAmount", "stratTaGas", "opsMaxBps"].map(n => chain.read<any>(configAddress, abi, n, [A.coreVault])));
  report.originalMinDeployAmount = caps[6]; caps[6] = 1n;
  await admin(configAddress, encode("setDefaultGovCaps", caps), "Fixture: lower minimum deploy amount for PDF's 4 USDC deposit");
  report.fixtures.push("PDF scenario: minDeployAmount lowered to 1 base unit; all other governance cap values preserved");
  const adapters: Address[] = [];
  for (let i=0; i<7; i++) adapters.push(await chain.read<Address>(A.strategyVault,strategyVaultAbi,"adapters",[BigInt(i)]));
  const funded = new Set<string>();
  for (const row of records.filter(r => r.row > 5)) {
    phase = `pdf-row-${row.row}`;
    await mineAt(row.timestamp);
    if (row.row === 6) {
      await tick("W6"); await tick("W5"); await tick("W1");
      check(await chain.read<bigint>(A.strategyVault,abi,"idleCash") > 0n, "W1 deployed core funds into strategy");
    } else if ([13,14,18,19,23,24,28,29,33,34,39,40,44,45].includes(row.row)) {
      await tick("W5"); await tick("W6"); await tick("W2");
      const enabled = [];
      for (const a of adapters) if (await chain.read<boolean>(A.strategyVault,strategyVaultAbi,"enabled",[a])) enabled.push(a);
      check(enabled.length === 1, "Exactly one adapter enabled");
      check(await chain.read<bigint>(A.strategyVault,abi,"positionAssets",[enabled[0]]) > 0n, "W2 funded isolated adapter", enabled[0]);
      funded.add(enabled[0]);
    } else {
      const before = row.row === 55 ? await balance(A.usdc, governance) : 0n;
      await admin(row.tx.to,row.tx.input,`PDF row ${row.row} (admin/user operation)`);
      if ([15,20,25,30,36,41,52].includes(row.row)) for (const a of adapters) check(await chain.read<bigint>(A.strategyVault,abi,"positionAssets",[a]) <= 1n, "Admin recall cleared adapter", a);
      if (row.row === 55) { report.withdrawnUsdcUnits = await balance(A.usdc, governance)-before; check(report.withdrawnUsdcUnits>0n,"Instant withdrawal paid user"); }
    }
  }
  check(funded.size === 7, "W2 funded all seven adapters");
  check(await balance(A.coreVault, governance) === 0n, "No user shares after exit");
  report.pdfScenarioPassed = true;
  const failures = report.transactions.flatMap((t:any) => (t.events??[]).filter((e:any) => e.args?.success === false || /Failed|Errored/.test(e.eventName)).map((e:any)=>({phase:t.phase,label:t.label,event:e.eventName})));
  report.innerFailures = failures;
  report.functionalPass = failures.length === 0;
  report.baselineInnerFailures = (report.baseline?.transactions ?? report.transactions.filter((t:any) => t.phase === "baseline-all-jobs"))
    .flatMap((t:any) => (t.events??[]).filter((e:any) => e.args?.success === false || /Failed|Errored/.test(e.eventName)).map((e:any)=>({label:t.label,event:e.eventName})));
  report.passed = report.functionalPass && report.baselineInnerFailures.length === 0;
} catch (e) {
  report.error = e instanceof Error ? e.message : String(e);
  console.error(report.error);
  process.exitCode = 1;
} finally {
  if (snapshot) {
    await fork("anvil_stopImpersonatingAccount", [manifest.signer]);
    report.forkRestored = await fork("evm_revert", [snapshot]);
  }
  await save();
  console.log(`Report: ${output}`);
}
