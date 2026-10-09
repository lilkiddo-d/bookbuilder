#!/usr/bin/env bash
# Full local rehearsal against an anvil fork of Robinhood Chain mainnet.
#   1) start the fork:   anvil --fork-url https://robinhood.drpc.org --chain-id 31337 --port ${FORK_PORT:-8545}
#   2) run this script:  bash scripts/fork-rehearsal.sh
# (an archive RPC is needed: the public RPC prunes state after ~10-30 min)
# Uses anvil's unlocked default accounts (no private keys are read, typed or stored).
set -euo pipefail
cd "$(dirname "$0")/../contracts"

RPC="http://127.0.0.1:${FORK_PORT:-8545}"
GOV=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ISSUER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
INV_A=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
INV_B=0x90F79bf6EB2c4f870365E785982E1f101E93b906
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168

rpc() { curl -s -X POST -H "content-type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"; echo; }
fs() { forge script script/SeedFork.s.sol --sig "$1()" --rpc-url "$RPC" --unlocked --sender "$2" --broadcast -q; }

echo "== deploy protocol (same script as mainnet)"
KYC_ATTESTOR=$GOV forge script script/Deploy.s.sol --rpc-url "$RPC" --unlocked --sender "$GOV" --broadcast -q

echo "== schedule issuer approval on the 48h Timelock"
fs schedule $GOV
rpc evm_increaseTime '[172801]' >/dev/null && rpc evm_mine '[]' >/dev/null
echo "== execute approval + KYC demo investors"
fs execute $GOV

echo "== fund demo investors with real USDG on the fork (balances mapping slot 1)"
for a in $INV_A $INV_B; do
  slot=$(node -e "const {keccak256,encodeAbiParameters}=require('viem');console.log(keccak256(encodeAbiParameters([{type:'address'},{type:'uint256'}],['$a',1n])))" 2>/dev/null \
    || (cd ../scripts && node -e "const {keccak256,encodeAbiParameters}=require('viem');console.log(keccak256(encodeAbiParameters([{type:'address'},{type:'uint256'}],['$a',1n])))"))
  rpc anvil_setStorageAt "[\"$USDG\",\"$slot\",\"0x000000000000000000000000000000000000000000000000000000e8d4a51000\"]" >/dev/null # 1,000,000 USDG
done

echo "== issuer creates offerings"
fs offerings $ISSUER
rpc evm_increaseTime '[3700]' >/dev/null && rpc evm_mine '[]' >/dev/null
echo "== demo demand"
fs activity $INV_A
echo "done. Frontend: NEXT_PUBLIC_DEFAULT_CHAIN_ID=31337 NEXT_PUBLIC_FORK_RPC_URL=$RPC pnpm app:dev"
