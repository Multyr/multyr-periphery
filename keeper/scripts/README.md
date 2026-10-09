# PDF adapter-cycle test

This is a separate historical test of the 56 transactions in
`arbitrum-adapter-cycle-transactions-20260929 (1) (1).pdf`. It does not add
admin operations to the W1–W6 production keeper.

The manifest records the PDF transaction hashes and the block immediately
before the first transaction: **509739747** on Arbitrum One. The script fetches
the original calldata, sender, receipt and timestamp from your source RPC.
It then replays the calls on a **pristine local Anvil fork only**. No private
key is used. There is no mainnet broadcast mode.

## Run

From the `keeper` directory, after `npm ci`, with Node >=22.18 and Anvil installed:

```sh
# Must serve historical state at block 509739747, not just old receipts.
export SOURCE_RPC_URL='https://YOUR_ARBITRUM_ARCHIVE_RPC'

# Optional read-only validation and calldata report:
npm run cycle:plan

# In another terminal, with the same SOURCE_RPC_URL:
anvil --fork-url "$SOURCE_RPC_URL" --fork-block-number 509739747 \
  --host 127.0.0.1 --port 8545

# Back in the keeper terminal:
FORK_RPC_URL=http://127.0.0.1:8545 npm run cycle:replay
```

The default output is `pdf-cycle-report.json` in the current directory.
Set `CYCLE_REPORT` to choose another path. This contains the ordered plan,
original and replay transaction hashes, receipts, the withdrawal amount,
success/failure and snapshot-restoration status. RPC URLs and keys are not
written to the report. Source-RPC access is read-only.

The public `https://arb1.arbitrum.io/rpc` endpoint returned **historical state
not available** for this block during validation. Use an archive provider.

## What it checks

- All 56 source receipts succeeded and all transactions have the PDF signer.
- The local endpoint is Anvil, uses chain ID 42161, and is forked at the
  expected block with a matching block hash and no subsequent local blocks.
- Calls run in chronological order. PDF row 35 (Euler capacity) precedes
  row 32 on-chain, despite its position in the table.
- Original transaction timestamps are reproduced for cooldowns. Local block
  numbers differ because intervening unrelated L2 blocks are not mined.
- The deposit mints shares; each isolated adapter has a positive recorded
  position after deployment; each explicit recall clears positions to at
  most one base unit; all seven adapters receive funds during the cycle.
- The exit transfers USDC, leaves the signer with zero shares, and all
  seven adapters are enabled at the end.
- Every replay transaction succeeds, including the final withdrawal-rule
  restoration transaction.

The entire local snapshot is reverted on success **or failure**, restoring
all local contract state, balances and temporary admin overrides. If the
process is killed or restoration fails, restart Anvil before another run.
Keep the Anvil instance dedicated to this test; do not run keepers against it.

## Scope and limitations

This replays the recorded calls against historical deployed bytecode, not
your uncommitted Solidity code or the current deployment state. It is not
a recurring production workflow or a fresh test at the latest block.

Unrelated transactions that occurred between the 56 calls are not replayed.
Block-number-dependent accrual, external protocol rates, oracle updates, Arbitrum-specific execution and
rounding can therefore differ from the original chain. Gas fees, transaction
hashes and the final USDC amount need not match the PDF exactly. A divergence
fails the relevant check and is recorded rather than silently changing the
historical calldata or weakening a contract guard.

Validation: `npm run typecheck` and `npm test`. A full successful fork run
requires working historical-state RPC access.

Validated on October 7, 2026 using an Infura archive endpoint: all 56 replay
transactions succeeded, all seven adapter checks passed, the exit completed,
and the fork snapshot was restored. The replay uses the original timestamps
but different local block numbers, as described above.

On the development host, Node needed `NODE_EXTRA_CA_CERTS=/private/etc/ssl/cert.pem`
to use the host CA bundle. If Node reports `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`,
configure the appropriate trusted CA bundle for your host; do not disable
certificate verification.
