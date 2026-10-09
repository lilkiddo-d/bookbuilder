/**
 * Bookbuilder auction-closing keeper.
 *
 * Each tick it:
 *  1. finalizes every offering whose sale / reveal window has ended (`canFinalize()`),
 *  2. flips escrows to Failed once the issuer's delivery deadline passed (`markDeliveryFailed()`),
 *  3. optionally pushes refunds / tokens to investors (`settle(investor)`) once an escrow is Failed or Delivered,
 *  4. optionally calls `FeeCollector.distribute(USDG)` on a slower cadence.
 *
 * Every action is permissionless on-chain; the keeper holds no privileged role.
 * Reads use viem. Writes are signed ONLY through Foundry (`cast send --account bookbuilder-keeper`),
 * so this process never sees a private key. `KEEPER_SIGNER=dry` (default) only logs.
 */
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbiItem, type Address, type PublicClient } from "viem";
import { robinhoodMainnet } from "@bookbuilder/config";
import {
  offeringFactoryAbi,
  offeringEscrowAbi,
  fixedPriceOfferingAbi,
  feeCollectorAbi,
} from "./abi/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const env = (k: string, d = "") => process.env[k] ?? d;

const CHAIN_ID = Number(env("CHAIN_ID", "4663"));
const RPC_URL = env("RPC_URL", CHAIN_ID === 31337 ? "http://127.0.0.1:8545" : robinhoodMainnet.rpcUrls.public);
const SIGNER = env("KEEPER_SIGNER", "dry") as "dry" | "keystore" | "unlocked";
const ACCOUNT = env("KEEPER_ACCOUNT", "bookbuilder-keeper");
const PASSWORD_FILE = env("KEEPER_PASSWORD_FILE");
const FROM = env("KEEPER_FROM");
const INTERVAL = Number(env("KEEPER_INTERVAL", "60")) * 1000;
const MAX_TX = Number(env("KEEPER_MAX_TX", "10"));
const AUTO_SETTLE = env("KEEPER_AUTO_SETTLE", "true") === "true";
const DISTRIBUTE_EVERY = Number(env("KEEPER_DISTRIBUTE_EVERY", "86400")) * 1000;
const ONCE = process.argv.includes("--once");

// Stage enum from IBookbuilder.sol
const Stage = { Active: 0, Succeeded: 1, Delivered: 2, Failed: 3 } as const;

type Deployment = {
  chainId: number;
  blockNumber: number;
  deployBlock?: number; // real L2 block, written by scripts/record-deploy-block.mjs
  contracts: Record<string, Address>;
  paymentTokens: Record<string, Address>;
};

function loadDeployment(): Deployment {
  const p = join(here, "..", "..", "deployments", `${CHAIN_ID}.json`);
  if (!existsSync(p)) throw new Error(`No deployment file at ${p}. Deploy first (see DEPLOY.md).`);
  return JSON.parse(readFileSync(p, "utf8")) as Deployment;
}

function log(...a: unknown[]) {
  console.log(new Date().toISOString(), ...a);
}

/** Send a tx via Foundry's signer. Never touches key material. */
function send(to: Address, sig: string, args: string[] = []): Promise<boolean> {
  if (SIGNER === "dry") {
    log(`[dry] would call ${to}.${sig}(${args.join(", ")})`);
    return Promise.resolve(true);
  }
  const cmd = ["send", to, sig, ...args, "--rpc-url", RPC_URL];
  if (SIGNER === "keystore") {
    cmd.push("--account", ACCOUNT);
    if (PASSWORD_FILE) cmd.push("--password-file", PASSWORD_FILE);
  } else {
    if (CHAIN_ID !== 31337) throw new Error("KEEPER_SIGNER=unlocked is only allowed on the local fork (31337)");
    cmd.push("--unlocked", "--from", FROM);
  }
  return new Promise((resolve) => {
    const child = spawn("cast", cmd, { stdio: ["inherit", "pipe", "pipe"] });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("close", (code) => {
      const ok = code === 0;
      log(ok ? "sent" : "FAILED", `${to}.${sig}(${args.join(", ")})`, ok ? "" : out.trim().slice(0, 400));
      resolve(ok);
    });
  });
}

async function listOfferings(client: PublicClient, factory: Address): Promise<Address[]> {
  const n = await client.readContract({ address: factory, abi: offeringFactoryAbi, functionName: "offeringCount" });
  const out: Address[] = [];
  const page = 100n;
  for (let i = 0n; i < n; i += page) {
    const chunk = await client.readContract({
      address: factory,
      abi: offeringFactoryAbi,
      functionName: "offerings",
      args: [i, page],
    });
    out.push(...chunk);
  }
  return out;
}

const depositedEvent = parseAbiItem("event Deposited(address indexed investor, uint256 amount, uint256 newDeposit)");
const investorCache = new Map<Address, { from: bigint; investors: Set<Address> }>();

async function investorsOf(client: PublicClient, escrow: Address, fromBlock: bigint): Promise<Address[]> {
  const c = investorCache.get(escrow) ?? { from: fromBlock, investors: new Set<Address>() };
  const latest = await client.getBlockNumber();
  const step = 50_000n;
  for (let b = c.from; b <= latest; b += step) {
    const to = b + step - 1n > latest ? latest : b + step - 1n;
    const logs = await client.getLogs({ address: escrow, event: depositedEvent, fromBlock: b, toBlock: to });
    for (const l of logs) if (l.args.investor) c.investors.add(l.args.investor);
  }
  c.from = latest + 1n;
  investorCache.set(escrow, c);
  return [...c.investors];
}

let lastDistribute = 0;

/** First block to scan for Deposited logs. block.number in the deploy script is L1-style on Arbitrum chains. */
function startBlock(dep: Deployment): bigint {
  const override = env("KEEPER_FROM_BLOCK");
  if (override) return BigInt(override);
  return BigInt(dep.deployBlock ?? dep.blockNumber);
}

async function tick(client: PublicClient, dep: Deployment) {
  const factory = dep.contracts.OfferingFactory;
  const offerings = await listOfferings(client, factory);
  const now = BigInt(Math.floor(Date.now() / 1000));
  let budget = MAX_TX;
  log(`tick: ${offerings.length} offerings`);

  for (const o of offerings) {
    if (budget <= 0) break;
    // all offering kinds share canFinalize()/finalize()/escrow()
    const [canFinalize, escrow] = await Promise.all([
      client.readContract({ address: o, abi: fixedPriceOfferingAbi, functionName: "canFinalize" }),
      client.readContract({ address: o, abi: fixedPriceOfferingAbi, functionName: "escrow" }),
    ]);
    if (canFinalize) {
      if (await send(o, "finalize()")) budget--;
      continue;
    }
    const [stage, deadline] = await Promise.all([
      client.readContract({ address: escrow, abi: offeringEscrowAbi, functionName: "stage" }),
      client.readContract({ address: escrow, abi: offeringEscrowAbi, functionName: "deliveryDeadline" }),
    ]);
    if (stage === Stage.Succeeded && now > deadline) {
      if (await send(escrow, "markDeliveryFailed()")) budget--;
      continue;
    }
    if (AUTO_SETTLE && (stage === Stage.Failed || stage === Stage.Delivered)) {
      const investors = await investorsOf(client, escrow, startBlock(dep));
      for (const inv of investors) {
        if (budget <= 0) break;
        const pos = await client.readContract({
          address: escrow,
          abi: offeringEscrowAbi,
          functionName: "positionOf",
          args: [inv],
        });
        if (pos.done || pos.deposit === 0n) continue;
        if (await send(escrow, "settle(address)", [inv])) budget--;
      }
    }
  }

  if (DISTRIBUTE_EVERY > 0 && Date.now() - lastDistribute > DISTRIBUTE_EVERY && budget > 0) {
    const usdg = dep.paymentTokens.USDG;
    const fc = dep.contracts.FeeCollector;
    const bal = await client.readContract({
      address: usdg,
      abi: [parseAbiItem("function balanceOf(address) view returns (uint256)")],
      functionName: "balanceOf",
      args: [fc],
    });
    if (bal > 0n) await send(fc, "distribute(address)", [usdg]);
    lastDistribute = Date.now();
    void feeCollectorAbi; // ABI kept for typed reads by operators
  }
}

async function main() {
  const dep = loadDeployment();
  const client = createPublicClient({ transport: http(RPC_URL) }) as PublicClient;
  const chainId = await client.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`RPC chain ${chainId} != CHAIN_ID ${CHAIN_ID}`);
  if (SIGNER === "unlocked" && !FROM) throw new Error("KEEPER_FROM is required with KEEPER_SIGNER=unlocked");
  log(`keeper up: chain ${chainId}, signer=${SIGNER}${SIGNER === "keystore" ? `(${ACCOUNT})` : ""}, factory ${dep.contracts.OfferingFactory}`);
  for (;;) {
    try {
      await tick(client, dep);
    } catch (e) {
      log("tick error:", (e as Error).message);
    }
    if (ONCE) break;
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
