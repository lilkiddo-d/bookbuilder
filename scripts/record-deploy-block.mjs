// Writes the real L2 deployment block into deployments/<chainId>.json (+ the app copy) as "deployBlock".
// Needed because on Arbitrum-based chains Solidity/Foundry report an L1-style block.number, while
// eth_getLogs uses L2 block numbers. Source of truth: the broadcast receipts Foundry saved.
// Usage: node scripts/record-deploy-block.mjs <chainId>
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const chainId = process.argv[2] ?? "4663";
const runFile = join(root, "contracts", "broadcast", "Deploy.s.sol", chainId, "run-latest.json");
if (!existsSync(runFile)) throw new Error(`No broadcast found at ${runFile}. Run the deploy with --broadcast first.`);
const run = JSON.parse(readFileSync(runFile, "utf8"));
const blocks = (run.receipts ?? []).map((r) => Number(BigInt(r.blockNumber)));
if (blocks.length === 0) throw new Error("Broadcast has no receipts.");
const deployBlock = Math.min(...blocks);

for (const f of [join(root, "deployments", `${chainId}.json`), join(root, "app", "public", "deployments", `${chainId}.json`)]) {
  if (!existsSync(f)) continue;
  const d = JSON.parse(readFileSync(f, "utf8"));
  d.deployBlock = deployBlock;
  writeFileSync(f, JSON.stringify(d, null, 2) + "\n");
  console.log(`deployBlock=${deployBlock} -> ${f}`);
}
