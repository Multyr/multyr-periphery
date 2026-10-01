import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  fallback,
  http,
  parseGwei,
  type Abi,
  type Address,
  type Chain,
  type LocalAccount,
  type PublicClient,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { arbitrum, base, mainnet } from "viem/chains";
import type { Config } from "./config.ts";
import { log } from "./log.ts";

const KNOWN_CHAINS: Record<number, Chain> = { [arbitrum.id]: arbitrum, [mainnet.id]: mainnet, [base.id]: base };

export type SendResult =
  | { status: "mined"; receipt: TransactionReceipt }
  | { status: "reverted"; receipt: TransactionReceipt }
  | { status: "not-eligible"; reason: string }
  | { status: "dry-run" }
  | { status: "skipped"; reason: string };

export interface WriteRequest {
  label: string;
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
}

/**
 * Thin wrapper over viem. Every write is simulated from the keeper address
 * first; a simulation revert means "not eligible right now" and no tx is sent.
 * The contracts stay the sole authority on eligibility.
 */
export class ChainClient {
  readonly pub: PublicClient;
  readonly wallet?: WalletClient;
  readonly account?: LocalAccount;
  /** Address used for simulations (signer, or KEEPER_ADDRESS in check mode). */
  readonly from?: Address;
  readonly dryRun: boolean;
  private readonly maxFeePerGas: bigint;
  private readonly receiptTimeoutMs: number;

  constructor(cfg: Config, account: LocalAccount | undefined, opts: { dryRun: boolean; from?: Address }) {
    const chain = KNOWN_CHAINS[cfg.chain.chainId];
    if (!chain) throw new Error(`chain ${cfg.chain.chainId} not in KNOWN_CHAINS; add it in chain.ts`);
    const transport = fallback(cfg.env.rpcUrls.map((u) => http(u, { timeout: 20_000, retryCount: 2 })));
    this.pub = createPublicClient({ chain, transport }) as PublicClient;
    this.account = account;
    if (account) this.wallet = createWalletClient({ chain, transport, account });
    this.from = account?.address ?? opts.from;
    this.dryRun = opts.dryRun;
    this.maxFeePerGas = parseGwei(String(cfg.chain.maxFeePerGasGwei));
    this.receiptTimeoutMs = cfg.chain.txReceiptTimeoutSec * 1000;
  }

  async now(): Promise<number> {
    const block = await this.pub.getBlock({ blockTag: "latest" });
    return Number(block.timestamp);
  }

  read<T = unknown>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []): Promise<T> {
    return this.pub.readContract({ address, abi, functionName, args }) as Promise<T>;
  }

  /** eth_call the write from the keeper address. Revert = not eligible. */
  async simulate(req: WriteRequest): Promise<{ ok: true; request: unknown } | { ok: false; reason: string }> {
    try {
      const { request } = await this.pub.simulateContract({
        address: req.address,
        abi: req.abi,
        functionName: req.functionName,
        args: req.args ?? [],
        account: this.account ?? this.from,
      } as any);
      return { ok: true, request };
    } catch (e) {
      return { ok: false, reason: revertReason(e) };
    }
  }

  async write(req: WriteRequest): Promise<SendResult> {
    const sim = await this.simulate(req);
    if (!sim.ok) return { status: "not-eligible", reason: sim.reason };
    const request = sim.request;
    if (this.dryRun || !this.wallet) {
      log.info("dry-run: would send", { label: req.label, to: req.address, fn: req.functionName, args: req.args });
      return { status: "dry-run" };
    }

    const fees = await this.pub.estimateFeesPerGas();
    if ((fees.maxFeePerGas ?? 0n) > this.maxFeePerGas) {
      return { status: "skipped", reason: `fee ${fees.maxFeePerGas} above cap ${this.maxFeePerGas}` };
    }
    const hash = await this.wallet.writeContract({
      ...(request as any),
      maxFeePerGas: this.maxFeePerGas,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas ?? 0n,
    });
    log.info("tx sent", { label: req.label, hash });
    const receipt = await this.pub.waitForTransactionReceipt({ hash, timeout: this.receiptTimeoutMs });
    log.info("tx mined", {
      label: req.label,
      hash,
      status: receipt.status,
      block: receipt.blockNumber,
      gasUsed: receipt.gasUsed,
    });
    return receipt.status === "success" ? { status: "mined", receipt } : { status: "reverted", receipt };
  }
}

export function revertReason(e: unknown): string {
  if (e instanceof BaseError) {
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      return revert.data?.errorName ?? revert.reason ?? revert.shortMessage;
    }
    return e.shortMessage;
  }
  return String(e);
}
