# StopLoss Sentinel

**Track:** Reactive Omni Buildathon — *Every Second Counts*
**Networks (testnet only):** Reactive Lasna (5318007) · Base Sepolia (84532)

A stop-loss / take-profit guardian for DEX positions that needs **no keeper
bot**. A reactive smart contract on Reactive Lasna watches a DEX's price
events on Base Sepolia; the moment the price crosses your stop-loss or
take-profit threshold, the Reactive Network itself delivers a callback to
your vault contract, which executes the protective swap and records the
measured end-to-end loop latency on-chain. **Live proof below: both loops
executed end-to-end, with on-chain recorded latencies of 2 seconds
(stop-loss) and 1 second (take-profit).**

Built on the current **Reactive Omni** architecture: the Sentinel subscribes
through the system contract (`0x8888…8888` on Lasna), receives reactive
transactions from it (`onlySystem`), and requests callbacks via
`requestCallbackV_1_0`; on Base Sepolia, callbacks are delivered by the
per-chain callback proxy `0x476F44b1…585`, and the vault authenticates both
the proxy and the injected reactive-contract address.

## How it works

```
Base Sepolia                                   Reactive Lasna
────────────                                   ──────────────
StopLossVaultOmni.createOrder() ──OrderCreated──▶  StopLossSentinelOmni
MockDex.setPrice()              ──PriceUpdated──▶  checks thresholds
                                                        │ threshold crossed
StopLossVaultOmni.executeOrder() ◀───callback────  requestCallbackV_1_0
        │  (delivered by the Base Sepolia callback proxy 0x476F…585)
        └─▶ swaps on MockDex, stores trigger price,
            amount out, and loop latency on-chain
```

1. **MockDex** (Base Sepolia) — a minimal two-token spot DEX. Its
   market-maker `setPrice()` and every swap emit `PriceUpdated(price,
   timestamp)`. The origin timestamp rides inside the event data because
   Reactive `LogRecord`s carry no timestamp — this is what lets the vault
   measure loop latency on-chain.
2. **StopLossVaultOmni** (Base Sepolia) — users deposit the mock token SLT
   and create orders (`createOrder(amount, stopLossPrice, takeProfitPrice)`),
   emitting `OrderCreated`. Its `executeOrder` is guarded twice:
   `onlyServiceProvider` (caller must be the Base Sepolia callback proxy)
   and `onlyCallbackSender` (the address the proxy injects into the
   payload's first slot must be the Sentinel).
3. **StopLossSentinelOmni** (Lasna) — subscribes to both event streams in
   its constructor. On `OrderCreated` it records the thresholds; on
   `PriceUpdated` it checks every active order and, on a cross, requests a
   callback to the vault via the system contract. Orders are marked
   inactive before firing, so an order can never execute twice.

## Contracts

| Contract | Chain | Address |
|---|---|---|
| MockERC20 (SLT) | Base Sepolia | `0x784637C89caafbE41CBFF892dCef6D60ab74b36C` |
| MockERC20 (mUSD) | Base Sepolia | `0xdc51A4f76B62aa66B8A4202640Aed443E0e48dD5` |
| MockDex | Base Sepolia | `0x61C260e37c7A6366FfC676e19E7A48C6Cf169671` |
| **StopLossVaultOmni** (live) | Base Sepolia | `0x0bdd18A6C9fD370767835f0D12002e8f08DF2cAb` |
| **StopLossSentinelOmni** (live) | Reactive Lasna | `0x61C260e37c7A6366FfC676e19E7A48C6Cf169671` |

Deployer (throwaway, testnet only): `0xc451dee9b027Bc0a5fAC61AaAA599B7d0E1bd1Ad`

Deployment transactions:

- Deploy MockERC20 (SLT): `0xf4dbfd1b442184fb22b74ac85cf30971818e09a136038820c540875cdf357a37`
- Deploy MockERC20 (mUSD): `0x8f740d2cd87ee01dd4625dbbae2e96836664f8e0726634cc4426b0142a49ea25`
- Deploy MockDex: `0xf401ced722bd190f13f37f756b42505f4e98059e643a7a63a660e95055b1456f`
- Seed liquidity (1,000,000 SLT / 2,000,000 mUSD, opening price 2.0): `0xbf4a2d248561a26b1be7f08131e7f411f1d2b20ad9fd8aff58f71f80a9a01ba7`
- Deploy StopLossSentinelOmni on Lasna: `0xbc53ef5d1b28564069d721e096c73872812c70cd000536a73662fd9ffe4e1b54`
  (funded with lREACT at deployment and topped up in
  `0xcdd1db812cc177e8fd77f061a0e1ad0ae8c092e74da9d4c7a5767309ca4968aa` and
  `0x3d0b673a3620ae1b6cbc62e0831d064a4130fbf0f7570c8b22a0b3046e12771e`)
- Deploy StopLossVaultOmni on Base Sepolia (funded with 0.003 ETH for
  callback settlement): `0xb4080a8f95a7d05b2e556b2fc11ad7409b160bc89d634fc8d74f3e2fc2c984e9`

The vault↔Sentinel pair is cross-wired by CREATE address prediction: the
Sentinel was deployed pointing at the vault's predicted address, and the
vault was deployed next with the Sentinel as its authorized callback
sender (both addresses verified on-chain after deployment).

Funding trail (all testnet): 0.05 Sepolia ETH from the Google Cloud Web3
faucet → 0.025 ETH bridged to Base Sepolia via the official L1StandardBridge
`0xfd0Bf71F60660E2f608ed56e1659C450eB113120` (deposits
`0x9d3ec41d6b324b2f03b5861dd5a8c73b35871ca646447402448746434b7d349e`,
`0x26eb928f1465c6a52dfa07c925a24fc7436b65d6a159004ae98ac12ada8c6cf6`) →
0.0249 ETH converted to 2.49 lREACT via the official Reactive faucet
contract `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (txs
`0xc7e65ccc1779a88a0affa618912e97bb30cff4cd0b9857606915b1ec42673749`,
`0xafbf74e14b40f6d9ad123b7512114e49f104214b2b8d491d290114bafc28936c`).

> **Migration note.** The first deployment used the pre-Omni (legacy)
> pattern — `StopLossVault` at `0x52b665E189ca707BC7e5131f9048Cc6487617e5F`
> and `StopLossSentinelReactive` at
> `0x784637C89caafbE41CBFF892dCef6D60ab74b36C`, sources kept in `src/` for
> reference. Lasna migrated to the Omni architecture in October 2026, so
> the legacy contract's `vmOnly` gate rejects every delivery and its
> subscriptions (registered with the legacy service contract) are never
> dispatched; its order can never execute. The Omni pair above is the live
> system. The legacy loop is still fully covered by local tests.

## Proof of the live loop

### Loop 1 — stop-loss (order 0: 5,000 SLT, stop-loss 1.5, take-profit 3.0)

- Deposit 10,000 SLT: `0xc10bb62abf3cf2993e083fb381aa8db659bf267c0b1fb50a442d55122865f135`
- OrderCreated (origin event): `0x14c463edee4f1d144db27e65e0caaa2af95da1d6e94b0a2772a71300ed864be4`
- Sentinel reaction — order tracked (Lasna): `0x4c6c30374ec454f002021d986ffca5f6d275e781e8088c0651510f8f6feb8a14`
- PriceUpdated trigger (origin event, price 2.0 → 1.4): `0xd72dcc918dcbd63f77eec3502489b0bb0440a0824f05a317d070f0eb6193861f`
- Sentinel reaction — triggered + callback requested (Lasna): `0x603c876ff95d5c58ade8b96d5b9473f83cd203c4502aaae5abb50e55155e8d11`
- Callback execution / OrderExecuted (destination): `0x5b31ae81f58331292769f5b75b7ca7a2bd057a525fef72b5b3ec888e0c09afcb`
- **Result: sold 5,000 SLT → 6,979 mUSD; loop latency recorded on-chain: 2 seconds**

### Loop 2 — take-profit (order 1: 5,000 SLT, stop-loss 1.5, take-profit 3.0)

- OrderCreated (origin event): `0x1e5619527ba842a5066bdc23c59acad238169126516dd72b421dc34d2d06c205`
- Sentinel reaction — order tracked (Lasna): `0xa7e9847dba395f2c22f7feb155ee3af7dc661e3c4af78640634c5f8941cbc4d9`
- PriceUpdated trigger (origin event, price → 3.2): `0x9714c40af0ac03b9efd066a28e4186929957443186402f3e03dc691b3f672af3`
- Sentinel reaction — triggered + callback requested (Lasna): `0x4df04d63abafadeb9bfb12cf179fa3e339dd211c59708ccae4fb0097998e0345`
- Callback execution / OrderExecuted (destination): `0x8ea27659158f00b2b40336ada6e667aef4ba2e25439961aaeb175973bc813511`
- **Result: sold 5,000 SLT → 15,952 mUSD; loop latency recorded on-chain: 1 second**

## Run it locally

```bash
forge build
forge test        # 10 tests, 3 suites — all passing
```

- `test/OmniLoop.t.sol` — the full Omni loop on one chain: a mock system
  contract etched at `0x8888…8888` stands in for the network, hand-built
  `LogRecord`s drive `react()`, the captured callback request is delivered
  by a pranked Base Sepolia proxy with the Sentinel's address injected into
  the payload's first slot (exactly as the network does). Asserts the swap
  math (5,000 SLT × 1.4 × 0.997 = 6,979 mUSD), the recorded latency, and
  that wrong-sender and non-proxy callbacks are rejected.
- `test/SentinelOmni.t.sol` — the Omni Sentinel alone: constructor
  subscriptions, `onlySystem` gating, track → trigger → callback-request
  payload correctness, no double-fire.
- `test/SentinelLoop.t.sol` — the legacy pair's simulated loop (kept for
  reference; see the migration note above).

## Deploy (testnets)

See `DEPLOY-RUNBOOK.md` for the original plan. What actually shipped:
fund a throwaway wallet from public faucets, bridge Sepolia ETH to Base
Sepolia via the official L1StandardBridge, convert Sepolia ETH to lREACT
via the official Reactive faucet contract, deploy the tokens/DEX with
`script/DeployBase.s.sol`, then deploy the Omni pair by CREATE prediction —
`script/DeployReactiveOmni.s.sol` on Lasna pointing at the vault's
predicted Base address, then `script/DeployVaultOmni.s.sol` on Base Sepolia
with the Sentinel as authorized callback sender — then move the mock
market price and watch it react.

## Notes

- Everything is testnet-only; the mock tokens have no value and `mint` is
  permissionless by design.
- Base Sepolia has ~200 ms blocks, so all timing uses timestamps, never
  block counts.
- Built during the Reactive Omni Buildathon (Nov–Dec 2026) on top of the
  official libraries: `reactive-lib-omni` for the live Omni pair,
  `reactive-lib` for the legacy reference implementation.
