import { cre, EVMClient, getNetwork, encodeCallMsg, bytesToHex, protoBigIntToBigint,
  LAST_FINALIZED_BLOCK_NUMBER, prepareReportRequest, TxStatus, Runner, type Runtime } from "@chainlink/cre-sdk";
import { decodeFunctionResult, encodeAbiParameters, parseAbiItem, type AbiFunction, type Address, type Hex } from "viem";
import { configSchema, validate, execute, encode, DeliveryError, type Config, type IO } from "./engine";

function run(runtime: Runtime<Config>, trigger: string): string {
  const config = runtime.config;
  // Disabled workflows do not issue capabilities, but a deployed disabled handler still
  // occupies a slot and receives triggers. Do not deploy unused workflow folders.
  if (config.mode === "disabled") return JSON.stringify([{ id: trigger, status: "disabled" }]);
  const network = getNetwork({ chainFamily: "evm", chainSelectorName: config.chainSelectorName });
  if (!network) throw new Error("Unsupported configured network");
  const evm = new EVMClient(network.chainSelector.selector);
  let calls = 0;
  const budget = () => { if (++calls > 15) throw new Error("EVM read quota exceeded; split this batch"); };
  budget();
  const header = evm.headerByNumber(runtime, { blockNumber: LAST_FINALIZED_BLOCK_NUMBER }).result();
  if (!header.header?.blockNumber) throw new Error("Missing finalized block header");
  const block = protoBigIntToBigint(header.header.blockNumber);
  if (block <= 0n) throw new Error("Invalid finalized block");
  const call = (target: string, data: Hex) => {
    budget();
    return evm.callContract(runtime, {
      call: encodeCallMsg({ from: config.receiverAddress as Address, to: target as Address, data }),
      blockNumber: block,
    }).result();
  };
  const io: IO = {
    read(request) {
      const fn = parseAbiItem(request.signature) as AbiFunction;
      if (fn.type !== "function") throw new Error("Function required");
      return decodeFunctionResult({ abi: [fn], functionName: fn.name, data: bytesToHex(call(request.target, encode(request)).data) });
    },
    simulate(target, data) { call(target, data); },
    write(target, data) {
      try {
        const payload = encodeAbiParameters(
          [{ type: "address" }, { type: "uint256" }, { type: "bytes" }], [target, block, data]);
        const report = runtime.report(prepareReportRequest(payload)).result();
        const result = evm.writeReport(runtime, { receiver: config.receiverAddress, report,
          gasConfig: { gasLimit: config.writeGasLimit } }).result();
        if (result.txStatus !== TxStatus.SUCCESS) throw new Error(result.errorMessage || String(result.txStatus));
        return bytesToHex(result.txHash ?? new Uint8Array());
      } catch (e) { throw new DeliveryError(`Report delivery failed or uncertain: ${String(e).slice(0, 200)}`); }
    },
  };
  const entries = execute(config, trigger, io);
  for (const entry of entries) runtime.log(JSON.stringify(entry).slice(0, 950));
  return JSON.stringify(entries);
}
export async function start(): Promise<void> {
  const runner = await Runner.newRunner<Config>({ configSchema: {
    "~standard": { version: 1, vendor: "multyr", validate: (input: unknown) => {
      const parsed = configSchema.safeParse(input);
      return parsed.success ? { value: parsed.data } : { issues: parsed.error.issues };
    } },
  } });
  await runner.run((config: Config) => {
    validate(config);
    return config.triggers.filter(t => t.enabled).map(t => cre.handler(
      new cre.capabilities.CronCapability().trigger({ schedule: t.schedule }),
      (runtime: Runtime<Config>) => run(runtime, t.name),
    ));
  });
}
