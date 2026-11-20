# StopLoss Sentinel — Live Deployment Runbook (testnets only)

Everything here is **testnet-only**: Reactive Lasna (5318007), Base Sepolia
(84532), Ethereum Sepolia (11155111). No mainnet, no real funds.

Deployer wallet (throwaway, testnet only):
`0xc451dee9b027Bc0a5fAC61AaAA599B7d0E1bd1Ad`
Private key: `~/workspace/goals/reactive-omni-buildathon-entry/hidden_files/deployer-wallet.txt` (mode 600).

```bash
export PATH=$HOME/workspace/tools/foundry/bin:$PATH
cd ~/workspace/reactive-omni
export DEPLOYER_PK=<from deployer-wallet.txt>
export BASE_RPC=https://sepolia.base.org
export LASNA_RPC=https://lasna-rpc.rnk.dev/
export ETHSEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export ADDR=0xc451dee9b027Bc0a5fAC61AaAA599B7d0E1bd1Ad
```

## Step 0 — Funding (USER STEP, blocked on faucet)

The deployer needs testnet ETH. All no-account faucets were exhausted
(pk910 requires a captcha to start mining; Bware/Unichain faucets unreachable;
Chainlink/QuickNode/Alchemy/Superchain require account sign-in). Muhammad
does ONE of these in his browser (≈2 minutes each):

- **Google Cloud Web3 faucet** — https://cloud.google.com/application/web3/faucet/ethereum/sepolia
  → sign in with Google, claim **Ethereum Sepolia ETH** to `$ADDR`.
- **Superchain faucet** — https://console.optimism.io/faucet
  → sign in with GitHub, claim **Base Sepolia ETH** to `$ADDR`.

Target: ≥0.05 ETH on Ethereum Sepolia **and** ≥0.02 ETH on Base Sepolia
(0.1 ETH on Ethereum Sepolia is comfortable; surplus Sepolia ETH can be
bridged to Base Sepolia via the L1StandardBridge
`0xfd0Bf71F60660E2f608ed56e1659C450eB113120` — verify on Base docs first).

## Step 1 — Convert Sepolia ETH to lREACT (Lasna gas + execution funds)

Official Reactive faucet (rate 1 ETH → 100 lREACT, docs:
dev.reactive.network/reactive-mainnet#get-testnet-react):

```bash
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
  --rpc-url $ETHSEPOLIA_RPC --private-key $DEPLOYER_PK \
  "request(address)" $ADDR --value 0.05ether   # -> 5 lREACT on Lasna
cast balance $ADDR --rpc-url $LASNA_RPC        # verify lREACT arrived
```

## Step 2 — Deploy origin + destination on Base Sepolia

```bash
forge script script/DeployBase.s.sol --rpc-url base_sepolia \
  --private-key $DEPLOYER_PK --broadcast -vvv
# record TOKEN_A, TOKEN_B, DEX, VAULT from the output
export TOKEN_A=... TOKEN_B=... DEX=... VAULT=...
```

## Step 3 — Deploy the reactive contract on Lasna

```bash
DEX_ADDR=$DEX VAULT_ADDR=$VAULT REACT_FUNDING=2000000000000000000 \
forge script script/DeployReactive.s.sol --rpc-url lasna \
  --private-key $DEPLOYER_PK --broadcast -vvv
export SENTINEL=<address from output>
```

Verify on https://lasna.reactscan.net that the Sentinel holds its funding and
has 2 subscriptions (vault `OrderCreated`, DEX `PriceUpdated` on chain 84532).

## Step 4 — Run the live loop (stop-loss)

```bash
# user position: deposit 10,000 SLT, open an order over 5,000 SLT
cast send $TOKEN_A --rpc-url $BASE_RPC --private-key $DEPLOYER_PK "approve(address,uint256)" $VAULT 10000000000000000000000
cast send $VAULT --rpc-url $BASE_RPC --private-key $DEPLOYER_PK "deposit(uint256)" 10000000000000000000000
cast send $VAULT --rpc-url $BASE_RPC --private-key $DEPLOYER_PK "createOrder(uint256,uint256,uint256)" 5000000000000000000000 1500000000000000000 3000000000000000000
# -> ORIGIN TX #1 (OrderCreated). Wait until the Sentinel tracks it:
cast call $SENTINEL --rpc-url $LASNA_RPC "trackedOrders(uint256)(bool,bool,uint256,uint256)" 0

# market crashes through the 1.5 stop-loss (price was 2.0)
cast send $DEX --rpc-url $BASE_RPC --private-key $DEPLOYER_PK "setPrice(uint256)" 1400000000000000000
# -> ORIGIN TX #2 (PriceUpdated). The Sentinel reacts on Lasna and the
#    callback proxy executes the swap on Base Sepolia automatically.
# Evidence to capture:
cast call $VAULT --rpc-url $BASE_RPC "orders(uint256)(address,uint256,uint256,uint256,bool,bool,uint256,uint256,uint256)" 0
# -> executed=true, amountOut, loopLatencySeconds recorded on-chain.
```

## Step 5 — Second loop (take-profit)

Create order #1 the same way, then `setPrice(3.2)` and capture the same
evidence. Two full loops (one SL, one TP) make the strongest submission.

## Step 6 — Evidence checklist for the BUIDL submission

- [ ] Contract addresses: TOKEN_A, TOKEN_B, DEX, VAULT (Base Sepolia), SENTINEL (Lasna)
- [ ] Tx hash: OrderCreated (Base Sepolia)
- [ ] Tx hash: PriceUpdated trigger (Base Sepolia)
- [ ] Tx hash: Sentinel reaction on Lasna (reactscan — the react() tx + Callback)
- [ ] Tx hash: callback execution on Base Sepolia (OrderExecuted, from the 0x8888…8888 proxy)
- [ ] `orders(0)` output showing executed + loopLatencySeconds
- [ ] Demo video < 3 min (Muhammad uploads to YouTube)
- [ ] Public GitHub repo (packaged with the parent agent at submission time)
