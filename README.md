# ConstantProductAMM — 完全本地测试的恒定乘积 AMM

一个仅运行在 Foundry 本地测试 EVM 中的恒定乘积做市商（AMM）实现。
**不依赖**主网、测试网、RPC Provider、Oracle、数据库或任何外部服务：
所有合约部署、Token、交易与状态都在 `forge test` 启动的本地 EVM 内完成。

## 结构

```
src/ConstantProductAMM.sol      # AMM 核心合约（自身即 LP Token，ERC20）
test/ConstantProductAMM.t.sol   # 单元测试 + fuzz 测试
test/invariant/                 # invariant 测试（handler + 不变量断言）
test/mocks/                     # MockERC20 / ReentrantToken（重入攻击模拟）
lib/forge-std/                  # forge-std v1.11.0（已 vendor，无需联网）
```

## 数学公式

设储备为 `(x, y)`，LP 总供应为 `S`，恒定乘积不变量 `k = x · y`。

**首次添加流动性**（Uniswap V2 风格）：

```
shares = sqrt(x · y) - MINIMUM_LIQUIDITY        (MINIMUM_LIQUIDITY = 1000)
```

其中 `MINIMUM_LIQUIDITY` 永久铸造到 `0x...dead`，防止首位 LP 通过
"份额通胀攻击"（inflation attack）掏空后续流动性提供者。

**追加流动性**：先按当前储备比例把投入调整为最优数量
（`amount1Optimal = amount0 · y / x`，超出部分不拉取、留在用户钱包），再铸造：

```
shares = min(amount0 · S / x, amount1 · S / y)
```

取 `min` 保证比例失衡的存入无法无成本获取价值。

**移除流动性**（按份额占比赎回）：

```
amount0 = shares · x / S
amount1 = shares · y / S
```

**Swap（exact input，0.3% 手续费）**：

```
amountInWithFee = amountIn · 997
amountOut = amountInWithFee · reserveOut / (reserveIn · 1000 + amountInWithFee)
```

手续费（输入的 0.3%）留存池内，因此每次 swap 后 `k` 严格不减（`k' ≥ k`），
LP 份额对应的池子价值随交易累积单调增长。

## 舍入规则

- 所有除法均为 EVM 整数除法，**一律向下取整（floor）**，舍入误差永远有利于池子；
- `sqrt` 使用 Babylonian 方法，向下取整；
- 输入为 0 → `ZeroAmount()`；输出取整为 0 → `InsufficientOutputAmount()`，
  极小输入不会"白送"资产也不会产生异常状态；
- 储备不足 / 份额为 0 → `InsufficientLiquidity()`；
- 实际输出低于 `minAmountOut`（或铸造份额低于 `minShares`）→ `SlippageExceeded()`，
  整笔交易 revert，超过允许滑点的交易不会部分成交。

## 安全假设与设计

- **Checks-Effects-Interactions**：先更新储备、铸造/销毁份额，再进行外部 token 转账；
- **重入防护**：所有改变状态的外部入口（`addLiquidity` / `removeLiquidity` /
  `swapExactIn`）共享同一互斥锁，重入直接 revert `Locked()`
  （测试中用恶意回调 token 验证无法重复提取流动性）；
- **Token 假设**：两种 token 均为标准 ERC20（无转账手续费、无 rebasing、
  无回调hook的良性实现）；`transfer`/`transferFrom` 的返回值与 returndata 均被检查；
- **滑点保护**：所有状态变更函数都带 `min*` 参数，由调用者设定可接受下界；
- **无特权角色**：合约不可升级、无 owner、无暂停开关，无外部价格源。

## 测试

```bash
forge test            # 全部单元测试 + fuzz + invariant
forge test -vvv       # 带调用轨迹
forge test --match-contract AMMInvariantTest   # 只跑 invariant
```

覆盖场景：首次加池（sqrt 铸份额、最小流动性锁定）、按比例追加、失衡存入只拉最优数量、
按比例移除、双向 swap、0.3% 手续费公式与 `k` 单调性、滑点边界 revert、
零输入 / 极小输入 / 空池 / 超大输入（渐近不抽干储备）、重入攻击阻断，
以及 fuzz（往返无免费价值、不变量不降）和 invariant 测试
（储备==余额、LP 供应守恒、token 总量守恒、k/份额有下界、储备恒正）。

## 离线环境说明

本工程在完全离线的条件下构建与测试：

- `forge` 二进制安装于 `~/.foundry/bin/forge`；
- `foundry.toml` 中 `offline = true` 且 `solc` 指向本机包装脚本
  `~/.local/bin/solc`（将 forge 的 standard-json 调用转发给本机 `solcjs`，
  npm 包 `solc@0.8.26`），forge 不会联网下载编译器；
- `forge-std` 已 vendor 在 `lib/forge-std`，无需 git submodule 更新。
