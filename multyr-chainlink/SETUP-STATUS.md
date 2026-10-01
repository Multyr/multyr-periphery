# VaultUpkeep CRE setup

This project lives in `multyr-periphery/multyr-chainlink`. The nested `multyr-core/` folder
is the CRE workflow for the core vault; it does not refer to the core repository.
The receiver, scripts, local tools and workflow have been moved together.

See [STRATEGY-SETUP-STATUS.md](./STRATEGY-SETUP-STATUS.md) for the equivalent, separately-prepared
`multyr-strategy/` workflow and receiver for `StrategyUpkeep`, which mirrors this setup.

## Prepared and verified

- Network: Arbitrum One, chain ID 42161.
- Existing upkeep: `0x8672921E03c9995AE1Dbe234A7a08C327163883e`.
- Live `core()`: `0x4575Ec0dD1ED08FD4F426665E5B56442594189bb` (matches).
- Live BufferManager `keeper()`: existing upkeep (matches).
- Live upkeep owner: RootTimelock `0xE2812E869F8005397130CCDF1aaabd75447844df`.
- Production CRE forwarder: `0xF8344CFd5c43616a4366C34E3EEE75af79a74482`, from the
  [official directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts).
- Official receiver template is pinned in `UPSTREAM.json`; its source is unchanged.
- Local CLI: `.tools/cre` v1.34.0. Local Bun: `.tools/bun` v1.4.2. Download SHA-256 digests verified.
- Receiver and deployment script compile. All 54 upstream receiver tests passed.
- Workflow TypeScript passes and `multyr-core/workflow.wasm` was built successfully.
- A local fork of RPC block **505380956** successfully delivered the due crystallization operation
  through the receiver; the upkeep emitted `UpkeepPerformed(3,0,true)`.
  Measured receiver-call gas: **864,811** (warm test context; excludes transaction/forwarder overhead).
  Arbitrum's EVM `block.number` observed inside the test was 25982108; that is distinct from the RPC L2 height.

## Not yet active

No receiver was deployed to mainnet and no CRE workflow was activated. The receiver address and write
gas limit remain zero in both config files so the draft cannot accidentally run. One current-action fork
test does not establish a worst-case gas limit for every upkeep branch.

Remaining inputs/actions:

1. Complete the CRE browser login started by `.tools/cre login`; verify deployment access.
2. Select the funded wallet signer/account for receiver deployment. No Foundry keystore was found locally.
3. Obtain the actual CRE workflow author address, which is not automatically the deployer or timelock.
4. Measure/choose the consumer and total report gas budgets within current CRE limits for relevant branches.
5. Dry-run then broadcast `contracts/evm/script/DeployVaultReceiver.s.sol`, using the selected signer.
   It configures only `performUpkeep(bytes)` on the intended upkeep, validates workflow author/name, sets
   consumer gas, and transfers receiver ownership to the existing RootTimelock.
6. Set `receiverAddress` to the confirmed deployed address and `writeGasLimit` to the measured total budget
   in `multyr-core/config.production.json`. Configure a separate simulation receiver or matching identity
   for tests: the production receiver requires workflow name `multyr-core-production`, whereas test-settings
   names the workflow `multyr-core-test`.
7. Simulate, deploy the workflow, confirm it is active, then observe a successful report and underlying upkeep
   event/state progress. Do not treat the generic receiver's transaction success as proof that the upkeep succeeded.

## Commands for continuation

Run from this directory; no private keys belong in these files:

```sh
export PATH="$PWD/.tools:$HOME/.foundry/bin:$PATH"
cre whoami
```

After supplying WORKFLOW_AUTHOR and CONSUMER_GAS_LIMIT in the local environment, dry-run from `contracts/evm`:

```sh
forge script script/DeployVaultReceiver.s.sol:DeployVaultReceiver \
  --rpc-url https://arb1.arbitrum.io/rpc --account "$DEPLOYER_ACCOUNT"
# Add --broadcast only when proceeding with the reviewed mainnet deployment.
```

After receiver deployment/configuration, from the project root:

```sh
cre workflow simulate multyr-core --target=production-settings
cre workflow deploy multyr-core --target=production-settings
```

The simulation command above does not broadcast by default. Both configuration targets point to Arbitrum
mainnet. `test-settings` is not a testnet. Preserve the generated lockfiles and pinned upstream revision.
