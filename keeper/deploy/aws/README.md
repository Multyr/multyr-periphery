# AWS simulation keeper — 9 October 2026

Account 820140266807, region eu-north-1. The fresh session authenticated successfully.
The tested simulation image has been pushed to the existing private ECR repository:

`820140266807.dkr.ecr.eu-north-1.amazonaws.com/multyr-keeper@sha256:d1ce53317b0c9f52b6af8194897635528ad27088359c311e36287e1df6843d5a`

## Remaining administrator action

The operator's PowerUserAccess session was denied `iam:CreateRole` for
`multyr-keeper-execution-role`. An AWS administrator must run `admin-setup.sh`
from this directory, which uses `execution-role-trust.json` and
`execution-role-policy.json`. Also grant the operator's SSO permission set the
narrow `iam:PassRole` permission in `operator-pass-role-policy.json` and provision
that permission set to this account. No administrator session or keys need to
be shared with the keeper.

The execution role can pull only this ECR repository and write only the existing
`/ecs/multyr-keeper-primary` log group. It grants no KMS access. The task has no
application task role, no signing credentials, and no AWS session credentials.

## Ready deployment inputs

`task-definition.json` is pinned to the published image digest. Once the role
and PassRole permission exist, register it with ECS. Replace the placeholder
in `service.json` with the returned task-definition ARN before creating the
service. Reuse the existing cluster, three default public subnets and dedicated
keeper security group (no inbound rules). Existing logs retain 30 days. No NAT
gateway or load balancer is needed. One task uses 0.25 vCPU and 512 MiB RAM.
Stop-before-start deployment settings prevent overlapping keeper instances.

`stack.json` is an alternative fresh-infrastructure template, validated by AWS;
do not deploy it over these existing named resources. It is not the active plan.

The service runs `check-loop`, never loads a signer, and simulates eth_call from
`0x404da3b474b8b4c87d5e3c39230c71a7237630da`. That address already holds KEEPER_ROLE
on strategy `0x7bF0f446BB20b54597E66a602cB94D0F231D24E2`. Polling: W1/W3/W5 every
240 seconds, W2 every 600 seconds, W4 every 1800 seconds, W6 every 120 seconds.

Local validation: image build, healthy container smoke test, TypeScript check,
23 keeper tests, and W1-W6 read-only execution passed. W3/W4 had nothing due;
W1/W2/W5/W6 passed outer call simulation. Simulated state changes are not persisted.

No ECS service is running yet. No keeper funding, broadcasts or 3-USDC deposit
were sent. Those remain on hold under the user's simulation-only instruction.
