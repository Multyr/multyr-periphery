#!/usr/bin/env bash
# Run with an administrator-authorized AWS profile in account 820140266807.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
account="$(aws sts get-caller-identity --query Account --output text)"
[[ "$account" == "820140266807" ]] || { echo 'Wrong AWS account' >&2; exit 1; }
aws iam create-role \
  --role-name multyr-keeper-execution-role \
  --assume-role-policy-document "file://$script_dir/execution-role-trust.json" \
  --description 'Pull Multyr keeper image and write CloudWatch logs; no KMS access'
aws iam put-role-policy \
  --role-name multyr-keeper-execution-role \
  --policy-name PullKeeperImageAndWriteLogs \
  --policy-document "file://$script_dir/execution-role-policy.json"
# Also add operator-pass-role-policy.json to the operator's SSO permission set
# (and provision it to this account). This grants only this role to ECS tasks.
