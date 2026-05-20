# Contributing

Thanks for your interest in contributing to `multyr-periphery`. This file
describes how external contributions are handled.

## Branch Convention

| Branch pattern | Purpose |
|---|---|
| `main` | Latest tagged release |
| `pierdev` | Development integration branch (not stable) |
| `reorg/runbook-<id>` | Individual Run Book execution branches |
| `feat/<short-name>` | Feature branches — rebase onto `pierdev` before review |
| `fix/<short-name>` | Bug fix branches |

## Commit Style

Internal commits use the Run Book step format:

```
runbook-<id>: step <N> — <one-line action>
```

External contributors may use a simpler `<area>: <imperative summary>` style.
Examples:

```
periphery: fix epoch boundary calculation in EpochPayout
docs: add DepositRouter whitelist flowchart
test: add ReferralBinding attribution edge case
```

## Pull Request Process

1. Open the PR against `pierdev` (never against `main` directly).
2. Ensure CI passes: `forge build`, `forge test`, `forge fmt --check`.
3. Update `CHANGELOG.md` under the relevant heading.
4. A Foundation reviewer will respond within 7 days.
5. Squash or rebase before merge if requested.

## Code Style

- Solidity 0.8.20
- `forge fmt` is the canonical formatter — run before pushing
- All new public functions need at least one unit test
- All revert paths need a named custom error
- Comments in English only

## Testing

- Unit and integration tests: `forge test --no-match-path "test/fork*"`
- Fork tests require `ARBITRUM_ARCHIVE_RPC_URL`
- Coverage goal: ≥ 90% line coverage on `src/`

## Scope Notes

This repo contains periphery contracts only. Core vault logic lives in
`multyr-core`. Do not add core vault logic to periphery contracts. Cross-repo
dependencies must go through the published interfaces in `multyr-core/src/interfaces/`.

## License

By contributing, you agree that your contribution is licensed under the same
Business Source License 1.1 terms as the rest of this repository.
