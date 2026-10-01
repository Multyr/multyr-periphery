# StrategyUpkeep CRE setup

This project lives in `multyr-periphery/multyr-chainlink`. The nested `multyr-strategy/` folder is
the CRE workflow for the lending strategy coordinator; it does not refer to the `multyr-strategies`
repository. It mirrors the already-verified `multyr-core/` (VaultUpkeep) setup described in
[SETUP-STATUS.md](./SETUP-STATUS.md): the same generic, unmodified `AutomationReceiver` / official
upstream receiver template, pointed at a second, independent receiver instance for `StrategyUpkeep`
(per the runbook's "prefer one receiver per workflow/security boundary" guidance, since this receiver's
outbound allowlist is scoped to a different target).

## Prepared, not yet verified in this session

- Network: Arbitrum One, chain ID 42161.
- Existing upkeep: `StrategyUpkeep` `0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550` (matches
  `script/automation/arbitrum-deployment.json`).
- `contracts/evm/script/DeployStrategyReceiver.s.sol` and
  `contracts/evm/test/StrategyUpkeepArbitrumFork.t.sol` were added, mirroring
  `DeployVaultReceiver.s.sol` / `VaultUpkeepArbitrumFork.t.sol` exactly, adjusted for two real
  differences in `LendingStrategyUpkeep.sol` (read directly from
  `multyr-strategies/src/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol`):
  - **Success signal.** VaultUpkeep emits one event with a success flag,
    `UpkeepPerformed(uint8,uint256,bool)`. StrategyUpkeep instead emits either
    `UpkeepPerformed(uint8,address,uint256)` on success or `UpkeepErrored(uint8,address,bytes)` on
    failure (mutually exclusive per action, except `OP_POKE_APY`, whose individually try/catch'd
    sub-pokes never block the final unconditional `UpkeepPerformed`). The fork test treats
    "`UpkeepPerformed` observed and `UpkeepErrored` absent" as success.
  - **Wiring check.** VaultUpkeep's caller authorization is `BufferManager.keeper() == VaultUpkeep`.
    StrategyUpkeep instead relies on OpenZeppelin AccessControl: the test asserts
    `UsdcMultiLendingVault.hasRole(keccak256("KEEPER_ROLE"), StrategyUpkeep)` is true, and that
    `StrategyUpkeep.isStrategy(UsdcMultiLendingVault)` is true.
  - Both new files were compiled — together with the real, unmodified `AutomationReceiver.sol` /
    `ReceiverTemplate.sol` and the vendored OpenZeppelin sources — using standalone `solc 0.8.26`
    (matching the receiver's exact pragma) and produced zero errors.
- `multyr-strategy/` CRE workflow folder was added, mirroring `multyr-core/` exactly: `main.ts` is a
  byte-for-byte copy (the workflow logic is fully generic, driven entirely by `config.*.json`; there is
  no vault/strategy-specific code in it), `package.json` and `tsconfig.json` are unchanged copies, and
  `workflow.yaml` / `config.*.json` follow the same shape with workflow names `multyr-strategy-test` /
  `multyr-strategy-production` / `multyr-strategy-simulation` and `targetAddress` set to StrategyUpkeep.
  As with `multyr-core`, receiver address and gas remain zero so the draft cannot accidentally run.

## What this session could NOT verify — read before trusting the above

This session's shell could reach neither the local Foundry/CRE toolchain on this machine (the bridge to
this repository's connected folder did not mount into a shell here) nor any external network host needed
to install its own copy or reach a live RPC (`foundry.paradigm.xyz`, `github.com` release downloads, and
`arb1.arbitrum.io` were all blocked by this session's own egress policy). Concretely, unlike VaultUpkeep's
setup, none of the following were done for StrategyUpkeep:

- **No `forge build` / `forge test` was run.** Only a standalone `solc` compile (see above), which
  confirms the new Solidity is syntactically/type-correct and matches the receiver's real ABI, but does
  **not** execute Foundry cheatcodes, fork a chain, or prove the test's logic actually behaves as intended
  at runtime.
- **No live Arbitrum RPC call was made.** `StrategyUpkeep.owner() == RootTimelock`,
  `StrategyUpkeep.isStrategy(UsdcMultiLendingVault)`, and
  `UsdcMultiLendingVault.hasRole(KEEPER_ROLE, StrategyUpkeep)` are all asserted by the new fork test (it
  will revert on a fork if any is false) and are consistent with
  [the runbook](../docs/arbitrum-automation-runbook.md) ("the existing StrategyUpkeep needs strategy
  `KEEPER_ROLE`"), but current on-chain state was not independently queried in this session.
- **No block with due StrategyUpkeep work was found or pinned.** VaultUpkeep's fork test hardcodes a
  specific block (`505380956` in the RPC's own numbering) found by manually searching for one where
  `checkUpkeep` returned true. This session had no RPC access to repeat that search for StrategyUpkeep, so
  `StrategyUpkeepArbitrumFork.t.sol` will revert with "No due action at fork block; choose a block with
  work" against whatever fork block you give it until you find and pin one — the same state VaultUpkeep's
  test was in before that search was done.
- **No `workflow.js` / `workflow.wasm` was built** — that needs the CRE CLI/Bun toolchain.

## Remaining inputs/actions (same shape as VaultUpkeep's, plus one)

1. From `contracts/evm`: `forge build`, then find a fork block with due StrategyUpkeep work (`cast call
   0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550 'checkUpkeep(bytes)(bool,bytes)' 0x --rpc-url
   "$ARBITRUM_RPC_URL" --block <N>`, bisecting recent blocks the same way VaultUpkeep's block was found),
   then run `forge test --match-path test/StrategyUpkeepArbitrumFork.t.sol -vvv --fork-url
   "$ARBITRUM_RPC_URL" --fork-block-number <N>` and hardcode that block once found, mirroring
   `VaultUpkeepArbitrumFork.t.sol`.
2. Confirm the wiring this session could only assert, not verify live — the `cast call` commands are
   already in [the runbook](../docs/arbitrum-automation-runbook.md).
3. Complete `cre login` and select the funded wallet signer, same as VaultUpkeep.
4. Obtain the CRE workflow author address for this job (can reuse `multyr-core`'s author, or use a
   distinct one for independent revocation — both are compatible with this receiver design).
5. Measure consumer/report gas for StrategyUpkeep's branches separately: HARVEST, REBALANCE
   (prepare/execute step), DEPLOY_IDLE and POKE_APY likely cost differently — the runbook notes POKE_APY
   alone can be gas-heavy ("Morpho can cost around 3.15M gas"). Size `writeGasLimit` and the receiver's
   `consumerGasLimit` for the worst branch you intend to enable, not just whichever branch a single fork
   test happens to exercise.
6. Dry-run then broadcast `contracts/evm/script/DeployStrategyReceiver.s.sol` with the selected signer. It
   configures only `performUpkeep(bytes)` on `StrategyUpkeep`, validates the workflow author/name, sets
   consumer gas, and transfers receiver ownership to `RootTimelock`.
7. Set `receiverAddress` and `writeGasLimit` in `multyr-strategy/config.production.json` (and a separate
   simulation receiver/identity for `config.test.json`, workflow name `multyr-strategy-test`).
8. Simulate, deploy, and confirm a successful report and underlying `UpkeepPerformed` — same as
   VaultUpkeep's final step. Do not treat the receiver transaction's success as proof the upkeep itself
   succeeded; check for `UpkeepErrored` too.

## Commands for continuation

Run from `multyr-chainlink/`; no private keys belong in these files:

```sh
export PATH="$PWD/.tools:$HOME/.foundry/bin:$PATH"
cre whoami
```

After supplying `WORKFLOW_AUTHOR` and `CONSUMER_GAS_LIMIT`, dry-run from `contracts/evm`:

```sh
forge script script/DeployStrategyReceiver.s.sol:DeployStrategyReceiver \
  --rpc-url https://arb1.arbitrum.io/rpc --account "$DEPLOYER_ACCOUNT"
# Add --broadcast only when proceeding with the reviewed mainnet deployment.
```

After receiver deployment/configuration, from the project root:

```sh
cre workflow simulate multyr-strategy --target=production-settings
cre workflow deploy multyr-strategy --target=production-settings
```

The simulation command above does not broadcast by default. Both configuration targets point to
Arbitrum mainnet; `test-settings` names a configuration, not a testnet.
