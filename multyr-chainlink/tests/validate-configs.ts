// Local tooling only; never imported into a CRE/WASM workflow.
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { configSchema, validate, ZERO } from "../suite/engine";
const root = resolve(import.meta.dir, "..");
const catalog = JSON.parse(readFileSync(join(root, "workflow-catalog.json"), "utf8"));
const known = new Set<string>(Object.values(catalog.contracts).map((v: any) => v.toLowerCase()));
if (known.size !== 40) throw new Error("Expected 40 unique deployment addresses");
let count = 0;
for (const name of readdirSync(join(root, "workflows"))) {
  for (const env of ["production", "simulation"]) {
    const config = configSchema.parse(JSON.parse(readFileSync(join(root, "workflows", name, `config.${env}.json`), "utf8")));
    validate(config);
    const targets = [config.targetAddress, ...config.actions.map(a => a.target),
      ...config.actions.flatMap(a => a.guards.map(g => g.target)), ...config.observations.map(o => o.target)].filter(Boolean);
    if (targets.some(t => !known.has(t!.toLowerCase()))) throw new Error(`${name}: unknown/old deployment target`);
    if (config.mode === "live" || config.receiverAddress !== ZERO || config.writeGasLimit !== "0") {
      throw new Error(`${name}: checked-in template is write-enabled or contains a live receiver/gas budget`);
    }
    if (!config.triggers.some(t => t.enabled)) throw new Error(`${name}: no trigger`);
    count++;
  }
}
if (count !== catalog.workflows.length * 2) throw new Error("Workflow catalog/config count mismatch");
console.log(`Validated ${count} non-broadcast workflow configs against 40 deployment addresses.`);
