#!/usr/bin/env python3
"""Read-only inventory of repository deployment records against a pinned RPC block.

No .env files or signing keys are read. Missing code is not proof of failed deployment:
records may describe a fork. RPC errors are recorded separately from missing code.
"""
import argparse
import json
import os
from pathlib import Path
import re
import urllib.request

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")

def discover(repos):
    found = {}
    def add(address, label, path):
        if isinstance(address, str) and ADDRESS.fullmatch(address) and int(address, 16):
            found.setdefault(address.lower(), set()).add(f"{path}:{label}")
    for repo in repos:
        for path in sorted((Path(repo) / "broadcast").rglob("*.json")):
            if "dry-run" in path.parts:
                continue
            data = json.loads(path.read_text())
            if not isinstance(data, dict):
                continue
            chain = data.get("chainId", data.get("chain"))
            if chain is not None and str(chain) not in ("42161", "0xa4b1"):
                continue
            if chain is None and "42161" not in path.parts:
                continue
            for key, value in data.items():
                add(value, key, path)
            for tx in data.get("transactions", []):
                if tx.get("transactionType") in ("CREATE", "CREATE2"):
                    add(tx.get("contractAddress"), tx.get("contractName", "CREATE"), path)
    return found

def rpc(url, method, params):
    body = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(str(result["error"]))
    return result["result"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", default=[])
    parser.add_argument("--manifest", type=Path, help="Explicit contracts map; preferred over historical broadcasts")
    parser.add_argument("--output", required=True)
    parser.add_argument("--offline", action="store_true", help="List candidates without asserting deployment")
    args = parser.parse_args()
    candidates = discover(args.repo)
    if args.manifest:
        manifest = json.loads(args.manifest.read_text())
        if manifest["chainId"] != 42161:
            parser.error("Manifest is not Arbitrum One")
        for name, addr in manifest["contracts"].items():
            if not ADDRESS.fullmatch(addr) or int(addr, 16) == 0:
                parser.error(f"Invalid address for {name}")
            candidates.setdefault(addr.lower(), set()).add(f"{args.manifest}:{name}")
    if not candidates:
        parser.error("No candidates; provide --manifest or --repo")
    if args.offline:
        Path(args.output).write_text(json.dumps(dict(chainId=42161, verified=False,
            addresses=[dict(address=a, sources=sorted(s), status="unverified")
                       for a, s in sorted(candidates.items())]), indent=2) + "\n")
        print(f"Saved {len(candidates)} unverified candidate addresses")
        return
    url = os.environ.get("ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc")
    if int(rpc(url, "eth_chainId", []), 16) != 42161:
        raise SystemExit("Expected chain 42161")
    block = rpc(url, "eth_blockNumber", [])
    header = rpc(url, "eth_getBlockByNumber", [block, False])
    rows = []
    for address, sources in sorted(candidates.items()):
        row = dict(address=address, sources=sorted(sources))
        try:
            code = rpc(url, "eth_getCode", [address, block])
            row.update(status="code" if code != "0x" else "no_code", codeBytes=(len(code)-2)//2)
        except Exception as exc:
            # Do not include RPC URL/credentials in reports.
            row.update(status="rpc_error", errorType=type(exc).__name__)
        rows.append(row)
    report = dict(chainId=42161, blockNumber=int(block, 16), blockHash=header["hash"], addresses=rows)
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"block": int(block, 16), "addresses": len(rows),
                      **{s: sum(r["status"] == s for r in rows) for s in ("code", "no_code", "rpc_error")}}))
    if any(r["status"] == "rpc_error" for r in rows):
        raise SystemExit(2)

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        raise SystemExit(f"Inventory failed ({type(exc).__name__}); no live verification completed") from None
