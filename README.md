# ConstantProductAMM

完全本地运行的恒定乘积 AMM（`x * y = k`）参考实现，基于 Foundry。
所有合约部署、Token、交易与状态仅存在于 Foundry 本地测试 EVM（anvil 内存链）中，
**不依赖主网、测试网、RPC Provider、Oracle、数据库或任何外部服务**。

## 结构

- `src/ConstantProductAMM.sol` — AMM 核心合约（自带 LP share ERC20）
- `src/mocks/MockERC20.sol` — 仅供本地测试的最小 ERC20
- `test/ConstantProductAMM.t.sol` — 单元测试 + fuzz 测试
- `test/ConstantProductAMM.invariant.t.sol` — invariant（状态机随机序列）测试

## 数学公式

### 添加流动性

- 首次加池，铸造份额（Uniswap V2 风格）：

  ```
  shares = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
  ```

  其中 `MINIMUM_LIQUIDITY = 1000` 被永久铸造到 `address(0)` 锁定，
  防止除零与首存通胀攻击（inflation attack）。

- 后续加池，按两侧储备比例取较小者：

  ```
  shares = min(amount0 * totalSupply / reserve0,
               amount1 * totalSupply / reserve1)
  ```

  比例失衡时，超出比例的部分不会为调用者铸造任何 share（相当于捐赠给池子），
  因此无法通过失衡存入无成本获取价值。

### 移除流动性

```
amount0 = shares * reserve0 / totalSupply
amount1 = shares * reserve1 / totalSupply
```

严格按 share 占比返还，不存在选择性提取。

### Swap（含手续费）

手续费固定 **0.3%**（`997/1000`），输出报价：

```
amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
```

交易完成后合约内联校验手续费调整后的 invariant：

```
(reserveIn * 1000 + amountIn * 997) * reserveOutNew >= reserveIn * reserveOut * 1000
```

即扣除手续费后的有效输入仍满足 `k` 不减；手续费部分留存池内，使 `k` 严格增大，
归全体 LP 所有。任何导致 invariant 异常下降的交易都会 revert（`InvariantViolated`）。

### 滑点保护

- `swap(tokenIn, amountIn, minAmountOut)`：实际输出 `< minAmountOut` 时 revert（`InsufficientOutput`）。
- `addLiquidity(..., minShares)`、`removeLiquidity(..., minAmount0, minAmount1)` 同理。

## 舍入规则

- 所有除法均为 Solidity 整数除法，**向下取整**，舍入误差永远有利于池子而非用户。
- 首次铸造使用 Babylonian 平方根，向下取整。
- 极小输入导致输出取整为 0 时 revert（`InsufficientOutput`），不会凭空产生或吞没资产。
- 零输入一律 revert（`ZeroAmount`）；储备不足 revert（`InsufficientReserve`）。

## 安全假设与设计

- **Checks-Effects-Interactions**：`removeLiquidity`/`swap` 先销毁 share、更新储备，再转出资产。
- **重入防护**：所有外部入口（`addLiquidity`/`removeLiquidity`/`swap`）使用互斥锁 `lock`，
  嵌套调用直接 revert（`Reentrancy`），测试中用恶意 Token 回调验证了无法重复提取流动性。
- **储备显式记账**：`reserve0/reserve1` 为合约内部账本，不依赖 `balanceOf` 外部调用结果做状态转换。
- **适用范围**：面向标准 ERC20（无转账手续费、无回调）。对 fee-on-transfer 或 ERC777 风格
  带回调的 Token，重入锁可阻断跨函数重入，但不保证记账与实收一致——生产环境应使用
  余额差值记账。本工程 Token 均为本地 `MockERC20`，满足标准行为。
- **完全本地**：测试通过 Foundry 的本地 EVM 执行，无任何网络/RPC 依赖。

## 运行测试

```bash
# 安装依赖（唯一需要网络的步骤，拉取 forge-std 子模块）
git clone https://github.com/foundry-rs/forge-std lib/forge-std

# 编译
forge build

# 全部测试（单元 + fuzz + invariant），纯本地执行
forge test

# 查看详情
forge test -vvv

# 仅 invariant 测试
forge test --match-contract Invariant -vvv
```

测试覆盖：首次加池铸造、追加/失衡流动性、移除流动性、双向 swap 精确输出、
0.3% 手续费使 `k` 增大、滑点 revert、零输入/极小输入/储备不足等极端数值、
重入阻断，以及 4 条 invariant（储备与余额一致、LP 单价单调不减、
最小流动性永锁、初始化后储备恒正）。
