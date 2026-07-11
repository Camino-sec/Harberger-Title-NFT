# 链上交互流程：一个完整的博弈周期

## 前置设定

| 参数 | 值 |
|------|-----|
| 年化税率 | 10%（1000 基点） |
| 基准价格（floorPrice） | 10 TOKEN |
| 代币精度 | 18 位小数（与 ETH 相同） |
| 时间单位 | 为了演示方便，假设 1 天 = 真实 1 天 |

---

## 场景一：正常博弈周期（A → B 买断）

### Step 1：角色 A 铸造 NFT

**操作**：
1. A 调用 `MockERC20.approve(harbergerContract, 200 TOKEN)`
2. A 调用 `HarbergerTitleNFT.mint(initialPrice=100 TOKEN, depositAmount=10 TOKEN)`

**链上状态变化**：
```
holder           = A
selfAssessedPrice = 100 TOKEN
escrowBalance    = 10 TOKEN
lastSettlementTime = T0（铸造时间）
```

**A 的心理博弈**：
> "我报 100 TOKEN 的价格，意味着每年要交 10 TOKEN 的税（100 × 10%）。我充了 10 TOKEN 押金，大约能撑 1 年。如果 1 年内没人买走我，我就得续费了。"

---

### Step 2：时间流逝 — 税金如何消耗

假设经过了 **180 天**（约半年）。

**税金计算**（惰性求值，不主动触发，只在有人调用相关函数时才计算）：

```
owedTax = selfAssessedPrice × taxRateBps × timeElapsed / (365 days × 10000)
        = 100 TOKEN × 1000 × 180 days / (365 days × 10000)
        = 100 × 1000 × 15,552,000 秒 / (31,536,000 秒 × 10000)
        ≈ 4.93 TOKEN
```

**链上状态**（概念上的，实际未写入）：
```
escrowBalance（账面）    = 10 TOKEN
owedTax（未结算）        = 4.93 TOKEN
netEscrowBalance（净值） = 5.07 TOKEN
```

**A 的处境**：
> "还剩大约 5 TOKEN 的押金净值，按当前价格还能撑半年左右。我要不要降价少交点税？但如果我降到 50 TOKEN，别人只要花 50 TOKEN 就能买走我的头衔……"

---

### Step 3：角色 B 强制买断（Happy Path）

**时间点**：铸造后第 200 天。

**B 的操作**：
1. B 调用 `MockERC20.approve(harbergerContract, 120 TOKEN)`（100 买断价 + 20 押金）
2. B 调用 `HarbergerTitleNFT.buyout(pricePayed=100 TOKEN, depositAmount=20 TOKEN)`

> **为什么买断时就要带上押金？** 早期版本里 `escrowBalance` 在买断后会被清零，"充值押金"是买家事后"可选"的下一步——但这意味着买断成功的下一个区块，B 的押金是 0，欠税立刻大于押金，B 会瞬间重新进入违约状态，被任何第三方免费/低价抢走。现在 `buyout()` 要求押金和买断在同一笔交易里原子完成，堵住这个"零押金窗口"（详见 README 4.6）。

**合约内部执行流程**：

```
┌─────────────────────────────────────────────────────┐
│ buyout() 执行步骤                                      │
├─────────────────────────────────────────────────────┤
│                                                       │
│ ① 计算欠税                                            │
│    timeElapsed = 200 天 = 17,280,000 秒               │
│    owedTax = 100 × 1000 × 17,280,000                 │
│            / (31,536,000 × 10000)                     │
│            ≈ 5.48 TOKEN                               │
│                                                       │
│ ② 从 A 的押金中扣除税金                                │
│    taxDeducted = min(5.48, 10) = 5.48 TOKEN           │
│    escrowRefund = 10 - 5.48 = 4.52 TOKEN              │
│                                                       │
│ ③ 代币转移                                             │
│    B 的钱包 → A 的钱包：100 TOKEN（买断价格）            │
│    合约押金 → A 的钱包：4.52 TOKEN（退还剩余押金）       │
│    合约押金 → 留在合约：5.48 TOKEN（税金，归入合约）     │
│                                                       │
│ ④ 转移 NFT                                            │
│    NFT(0) 的持有者：A → B                               │
│                                                       │
│ ⑤ 重置状态（与④之前的转账合并为一笔交易，原子完成）      │
│    holder = B                                          │
│    selfAssessedPrice = 100 TOKEN（继承 A 的定价）       │
│    escrowBalance = 20 TOKEN（B 买断时一并充值，不再为 0）│
│    lastSettlementTime = 当前时间                        │
│                                                       │
└─────────────────────────────────────────────────────┘
```

**各方资金变化**：

| 角色 | 变化 |
|------|------|
| A | +100 TOKEN（卖价）+ 4.52 TOKEN（押金退还）= **+14.52 TOKEN**，失去 NFT |
| B | -100 TOKEN（买断价）- 20 TOKEN（自己的新押金），获得 NFT，escrowBalance = 20 TOKEN |
| 合约 | +5.48 TOKEN（A 的税金留在合约中）+ 20 TOKEN（B 的新押金） |

**B 买断之后可选的后续操作**（押金已经在买断时到位，不再是紧急操作）：
1. B 可以随时调用 `depositCollateral(更多 TOKEN)` 追加押金
2. B 调用 `setPrice(150 TOKEN)` 提高售价（意味着每年要交 15 TOKEN 的税）

---

## 场景二：违约周期（A 的税金耗尽 → C 免费申领）

### Step 1-2：与场景一相同

A 铸造，充了 10 TOKEN 押金，报价 100 TOKEN。

### Step 3：时间流逝到第 365 天（税金耗尽）

**税金计算**：
```
owedTax = 100 × 1000 × 365 days / (365 days × 10000) = 10 TOKEN
```

**关键时刻**：owedTax（10 TOKEN）= escrowBalance（10 TOKEN）

> 此时刚好不违约（欠税 = 押金），但再多一秒就违约了。

### Step 4：第 366 天 — 违约触发

```
owedTax > escrowBalance  →  true（10.03 TOKEN > 10 TOKEN）
isForeclosed = true
```

**链上状态**：
```
holder           = A
selfAssessedPrice = 100 TOKEN
escrowBalance    = 10 TOKEN（账面，但已不足覆盖欠税）
isForeclosed     = true
```

### Step 5：角色 C 申领违约 NFT

**C 的操作**：
1. C 调用 `MockERC20.approve(harbergerContract, 15 TOKEN)`（10 floorPrice + 5 押金）
2. C 调用 `HarbergerTitleNFT.claimForeclosed(pricePayed=10 TOKEN, depositAmount=5 TOKEN)`

> 注意：floorPrice = 10 TOKEN，所以 C 至少需要支付 10 TOKEN；`depositAmount` 是 C 可选带上的押金,同样是为了避免自己申领成功后又立刻被别人重新违约申领(同一个"零押金窗口"问题,详见 README 4.6)。如果 floorPrice 设为 0，则 C 的申领价可以是 0。

**合约内部执行流程**：

```
┌─────────────────────────────────────────────────────┐
│ claimForeclosed() 执行步骤                             │
├─────────────────────────────────────────────────────┤
│                                                       │
│ ① 验证 NFT 确实处于 Foreclosure 状态                    │
│    owedTax > escrowBalance → true ✓                   │
│                                                       │
│ ② 从 C 处收取 floorPrice + 押金（合并为一笔转账）        │
│    C → 合约：10 TOKEN（floorPrice）+ 5 TOKEN（押金）    │
│                                                       │
│ ③ 转移 NFT                                            │
│    NFT(0) 的持有者：A → C                               │
│                                                       │
│ ④ 重置状态（与②之前的转账合并为一笔交易，原子完成）      │
│    holder = C                                          │
│    selfAssessedPrice = floorPrice = 10 TOKEN           │
│    escrowBalance = 5 TOKEN（C 申领时一并充值，不再为 0）│
│    isForeclosed = false                                │
│    lastSettlementTime = 当前时间                        │
│                                                       │
└─────────────────────────────────────────────────────┘
```

**各方资金变化**：

| 角色 | 变化 |
|------|------|
| A | 失去 NFT，押金被税金耗尽（0 退还），**净损失** |
| C | -10 TOKEN（floorPrice）- 5 TOKEN（自己的新押金），获得 NFT，escrowBalance = 5 TOKEN |
| 合约 | +10 TOKEN（floorPrice）+ 5 TOKEN（C 的新押金）+ A 的押金（已被税金消耗） |

---

## 博弈全景图

```
                    ┌──────────────────────────────────────┐
                    │          税金消耗示意（10% 年化）        │
                    └──────────────────────────────────────┘

    押金余额
    (TOKEN)
    10 ┤████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       │                    ↑ 违约临界点
     8 ┤████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       │             ↑
     6 ┤████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       │          ↑
     4 ┤████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       │       ↑
     2 ┤████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       │  ↑
     0 ┤░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       └──┬────┬────┬────┬────┬────┬────┬────┬────┬────→
         0   40   80  120  160  200  240  280  320  365  天

       ████ = 净押金余额（扣除已产生税金后）
       ░░░░ = 已消耗的税金
```

**核心博弈心理**：

| 持有者的选择 | 好处 | 风险 |
|-------------|------|------|
| 报高价（如 1000 TOKEN） | 买断价格高，别人难以买走 | 税金高（100 TOKEN/年），押金消耗快 |
| 报低价（如 10 TOKEN） | 税金低（1 TOKEN/年），押金能撑很久 | 别人花 10 TOKEN 就能买走 |
| 不充押金 | 零成本持有 | 很快违约，NFT 被收回 |

> **这就是哈伯格税的精妙之处**：它迫使资产始终有一个"真实"的市场价格。
> 持有者不能漫天要价（因为税金贵），也不能故意低价占坑（因为别人会买走）。
