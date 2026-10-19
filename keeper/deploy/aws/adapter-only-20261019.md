# Adapter-only repair: keeper configuration

Use `KEEPER_CONFIG=/app/config/arbitrum-one.json` for the adapter-only Safe repair. Strategy `0xa9E676D15976A1332905238ca609Dff9A484Efe0` and upkeep `0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF` remain active. Do not activate `arbitrum-one.next.json` or the staged replacement strategy.

No AWS target or application-code change is required solely for swapping adapters. W5 enumerates all registered adapters, then filters enabled/non-quarantined adapters, so it discovers replacements automatically. W2's upkeep poke-target list is updated on-chain in the atomic Safe swap, and replacement adapters grant KEEPER_ROLE to that existing upkeep. Old poke targets are removed. The retired 0x05202b06647d4597fB851162A1E32AA8437EeFc3 is absent from the default configuration.

Gas floors are set per adapter in the existing read-only estimator by Safe. No gas-quote publishing job is needed. Telemetry code in commit 25c538648e7b898f2e65eff345006d352f69f3e8 is available for a separate image rollout; an adapter swap alone does not require that rollout.

W4 remains Monday 10:00–16:00 UTC, polled every 30 minutes. A pending fee balance outside this window does not establish failure. W6 polls every 120 seconds and refreshes 120 seconds before expiry; a 600-second TTL gives an approximately eight-minute refresh interval.

After execution verify: W2 uses the same upkeep, its APY poke list contains new Morpho/Dolomite/Fluid only; W5 sees seven enabled adapters even though the registry retains four disabled historical addresses; run preflight and inspect all six job logs. Record the Safe hash and first subsequent adapter-deployment hash. Live AWS state must be checked independently; repository settings do not prove a running ECS image/config matches them.
