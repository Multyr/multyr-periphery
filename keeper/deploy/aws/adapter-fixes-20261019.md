# Read-only estimator and adapter correction cutover

The pending configuration is `keeper/config/arbitrum-one.next.json`. Activate it only after the Safe migration batch succeeds on Arbitrum One.

- Replacement strategy: `0xB143245BBB4333435CD8cc7CcCe1d6E0ABcF5DB6`
- Replacement StrategyUpkeep: `0x7c8de9F5d184b507ed2d110403cf4792865C8123`
- Retiring strategy: `0xa9E676D15976A1332905238ca609Dff9A484Efe0`
- Retiring StrategyUpkeep: `0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF`
- Earlier retired upkeep `0x05202b06647d4597fB851162A1E32AA8437EeFc3` must remain disabled and absent from active jobs.
- Existing read-only gas estimator: `0xD29649980B46e73127d14Cd6f2620527E3c9934d`

W2 points to the replacement upkeep; W5 refreshes replacement strategy liquidity. W1, W3, W4 and W6 retain their current targets and cadence. No keeper gas-quote publication transaction is introduced. The Safe migration calibrates the new adapter addresses in the existing estimator.

After Safe execution:

1. Confirm the Router enables the replacement and disables the retiring strategy; confirm old upkeep is disabled, new upkeep enabled, old adapter NAV drained and keeper roles present on the replacement.
2. Build the keeper image from this repository and pin its digest. Register a new revision of the existing ECS task definition, preserving the live RPC secret, KMS signer, roles, networking and primary/sending settings. Set `KEEPER_CONFIG=/app/config/arbitrum-one.next.json`.
3. Update service `multyr-keeper-simulation` in cluster `multyr-keeper`, region `eu-north-1`. Its legacy name does not mean it is a dry run. Keep desiredCount=1 and minimumHealthyPercent=0 / maximumPercent=100 to prevent overlapping primary workers.
4. Check startup addresses, all six job runs, the first W1/W2 deployment receipts and actual adapter balances. Ensure every allocation respects the 25% ceiling. Compare complete-plan modeled costs with the sum of execution receipt fees; a single receipt is not directly comparable to a whole-plan quote.
5. Promote the pending config to the default config after the rollout is verified, recording the migration hash, image digest and ECS task revision.

Do not roll back to retired strategy targets after migration. If the new task fails, pause sending and repair the configuration or image while preserving the new on-chain target.

W4 distribution remains scheduled for Monday 10:00–16:00 UTC, polled every 30 minutes. An accrued token balance outside this window does not alone mean the job failed. W6 polls every two minutes and refreshes two minutes before NAV expiry (approximately eight minutes for a ten-minute TTL).

Validation: 32 keeper tests and TypeScript checks passed. The pending six-job configuration parses successfully. Production AWS activation is intentionally pending successful Safe migration.
