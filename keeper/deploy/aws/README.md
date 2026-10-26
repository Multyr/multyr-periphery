## Release candidate: 27 October 2026

The current live service is `multyr-keeper-simulation:6` in `eu-north-1`.
The name is historical: the worker sends transactions in `run` mode.
Strategy: `0x2AD722B6241605481829E4B251AE8A4Ba8Be86cE`.
StrategyUpkeep: `0xAB30b7D1ADe850b6b122bcfF29F389CF1D051D44`.
Image digest: `sha256:9f4cdae078658c5a42cdf0a9eb49f9ab2242d6e704e9a30c37022d6a3eb8dfb8`.
Config: `/app/config/arbitrum-one.ema-first-20261023.json`.
The 26 October read-only service check found running/desired 1/1.
Earlier revision descriptions below are historical, not rollout instructions.
`task-definition.json` is a simulation bootstrap template, not the current live
revision. Do not register it to reproduce the live candidate. Use the versioned
EMA-first rollout record and preserve runtime RPC/KMS secrets outside Git.
Code freeze and pre-burn acceptance are separate; acceptance remains incomplete.

# AWS replacement rollout — 18 October 2026

Live service `multyr-keeper-simulation` now runs revision `:4`, image digest `sha256:99aae44ad8e78180a8723a9e9d561b16be034d63f2853407d1c48bffc86ca40e`. W2 targets replacement upkeep `0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF`; W5 targets strategy `0xa9E676D15976A1332905238ca609Dff9A484Efe0`. Gas and score events are logged alongside actual receipt fees. No quote-publishing job is required. Existing RPC/KMS settings and all other jobs were preserved from live revision :3.

Typecheck, 32 tests and live preflight passed. Old worker stopped before the replacement started. Its first cycle successfully deployed idle funds, harvested and refreshed both liquidity batches. Evidence: `multyr-strategies/deployments/replacement-20261017/aws-rollout/`. Historical configuration below describes the previous deployment.

# AWS live keeper — 9 October 2026

The user explicitly authorized sending mode. The existing service
`multyr-keeper-simulation` now runs task definition `multyr-keeper-simulation:2`
with command `run`, SIGNER=aws-kms, and the existing eu-north-1 signer key.
The service name is retained; it no longer indicates the runtime mode.
One healthy task runs with stop-before-start deployment settings.

Live log group: `/ecs/multyr-keeper-primary`; stream:
`live/keeper/ba00b29db80f465d8afe7e0ce7cda875`.

The first cycle mined five successful transactions: W1 CRYSTALLIZE and
REBALANCE (both internal operations confirmed successful), W2 HARVEST, and two
W5 liquidity batches. W3/W4/W6 had no work due. On-chain receipts were independently
checked for success and the correct keeper sender. Evidence is in workspace
`deployment-20261009/aws-live-status.json`, `aws-live-cloudwatch.json`,
`aws-live-first-receipts.json`, and ECS service/task status files.

Polling remains W1/W3/W5 every 240 seconds, W2 every 600 seconds, W4 every 1800
seconds and W6 every 120 seconds. Every write is simulated first. The fee cap
is 1 gwei, and gas headroom is 1.5 times the estimate. Keeper funding was observed
at 0.005 ETH before activation; the configured low-balance alert threshold is
also 0.005 ETH, so gas spending will place it below the alert threshold.

No 3-USDC deposit or governance parameter change was broadcast. The requested
minimum-deposit-zero Safe batch is prepared at
`deployment-20261009/minimum-deposit-zero.safe.json` and still needs Safe execution.
The minimum strategy deployment amount and withdrawal timing remain unchanged.

## Stop or roll back

Stop the service and ongoing transaction sending:

```sh
aws ecs update-service --cluster multyr-keeper --service multyr-keeper-simulation \
  --desired-count 0 --region eu-north-1
```

To return to simulations, update the same service to task definition
`multyr-keeper-simulation:1` and desired count 1, retaining minimumHealthyPercent=0
and maximumPercent=100. Do not run another keeper with the same signer.

`task-definition-live.json` is the live registration input;
`task-definition.json` retains the simulation configuration. `service.json`
now points to the live revision. The old simulation run and successful KMS
message-signing diagnostic are retained in deployment-20261009 evidence files.
No operator AWS session credentials are included in the image or task environment.
