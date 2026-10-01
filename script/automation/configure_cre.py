#!/usr/bin/env python3
"""Create one independent workflow from Chainlink's official automation-migration template.

Only writes local configuration. Does not deploy, grant roles or submit transactions.
For a fresh project: cre init --template=automation-migration-ts --project-name multyr-chainlink --workflow-name my-workflow
"""
import argparse
import json
from pathlib import Path
import re
import shutil

def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise argparse.ArgumentTypeError("Expected a nonzero EVM address")
    return value

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", type=Path, required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--template-workflow", default=None, help="Source folder inside project; defaults to my-workflow or existing multyr-core workflow")
    p.add_argument("--receiver", type=address, required=True)
    p.add_argument("--target", type=address, required=True)
    p.add_argument("--gas", type=int, required=True, help="Measured complete receiver transaction gas with margin")
    p.add_argument("--schedule", default="0 */1 * * * *")
    p.add_argument("--function", help="Direct CRON call, e.g. pokeLiquidityBatch(uint256,uint256)")
    p.add_argument("--args", default="[]", help="JSON arguments for a direct CRON call")
    a = p.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", a.name) or a.name == "my-workflow":
        p.error("name must be a unique lowercase workflow name (max 40 chars)")
    if a.gas <= 0:
        p.error("gas must be positive and measured against current CRE limits")
    args = json.loads(a.args)
    if not isinstance(args, list) or (args and not a.function):
        p.error("args must be a JSON array and require --function")
    source_name = a.template_workflow or ("my-workflow" if (a.project / "my-workflow").is_dir() else "multyr-core")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", source_name):
        p.error("Invalid template workflow folder name")
    template = a.project / source_name
    if not (template / "main.ts").is_file() or not (a.project / "contracts").is_dir():
        p.error("Source workflow main.ts or shared contracts directory is missing")
    dest = a.project / a.name
    if dest.exists():
        p.error("Workflow already exists; refusing to overwrite")
    config = dict(chainSelectorName="ethereum-mainnet-arbitrum-1", receiverAddress=a.receiver,
                  targetAddress=a.target, migrationType="CRON" if a.function else "CUSTOM",
                  schedule=a.schedule, checkData="0x", writeGasLimit=str(a.gas))
    if a.function:
        config.update(targetFunction=a.function, targetInputs=args)
    shutil.copytree(template, dest, ignore=shutil.ignore_patterns("node_modules", ".git", "*.wasm", "workflow.js", "binary.wasm.br.b64"))
    for env in ("test", "production"):
        (dest / f"config.{env}.json").write_text(json.dumps(config, indent=2) + "\n")
    (dest / "workflow.yaml").write_text("\n".join(
        f'{env}-settings:\n  user-workflow:\n    workflow-name: "{a.name}-{env}"\n'
        f'  workflow-artifacts:\n    workflow-path: "./main.ts"\n'
        f'    config-path: "./config.{short}.json"\n    secrets-path: ""\n'
        for env, short in (("test", "test"), ("production", "production"))))
    print(f"Created {dest}; both targets point to Arbitrum MAINNET. Simulation only until reviewed.")

if __name__ == "__main__":
    main()
