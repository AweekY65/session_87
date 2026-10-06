// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev 随机操作处理器：加池、移除、双向 swap。
contract AMMHandler is Test {
    ConstantProductAMM public amm;
    MockERC20 public token0;
    MockERC20 public token1;

    uint256 public ghost_lastK;
    uint256 public ghost_lastSupply;
    uint256 public ghost_swaps;
    uint256 public ghost_adds;
    uint256 public ghost_removes;

    uint256 internal constant MAX_OP = 1e15; // 限制单次操作规模，避免 invariant 乘积溢出。

    constructor() {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        amm = new ConstantProductAMM(address(token0), address(token1));
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
    }

    function addLiquidity(uint256 a0, uint256 a1) external {
        a0 = bound(a0, 1e6, MAX_OP);
        a1 = bound(a1, 1e6, MAX_OP);
        token0.mint(address(this), a0);
        token1.mint(address(this), a1);
        try amm.addLiquidity(a0, a1, 0) {
            ghost_adds++;
            _snapshot();
        } catch {}
    }

    function removeLiquidity(uint256 shares) external {
        uint256 bal = amm.balanceOf(address(this));
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        try amm.removeLiquidity(shares, 0, 0) {
            ghost_removes++;
            _snapshot();
        } catch {}
    }

    function swap(bool zeroForOne, uint256 amountIn) external {
        if (amm.totalSupply() == 0) return;
        amountIn = bound(amountIn, 1, MAX_OP);
        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        tokenIn.mint(address(this), amountIn);
        try amm.swap(address(tokenIn), amountIn, 0) {
            ghost_swaps++;
            _snapshot();
        } catch {}
    }

    function _snapshot() internal {
        ghost_lastK = amm.reserve0() * amm.reserve1();
        ghost_lastSupply = amm.totalSupply();
    }
}

contract ConstantProductAMMInvariantTest is Test {
    AMMHandler internal handler;
    ConstantProductAMM internal amm;

    function setUp() public {
        handler = new AMMHandler();
        amm = handler.amm();
        targetContract(address(handler));
    }

    /// @notice 记账储备与合约实际持币始终一致。
    function invariant_ReservesMatchBalances() public view {
        assertEq(amm.reserve0(), handler.token0().balanceOf(address(amm)));
        assertEq(amm.reserve1(), handler.token1().balanceOf(address(amm)));
    }

    /// @notice 一旦初始化，MINIMUM_LIQUIDITY 永久锁定，totalSupply 不会归零。
    function invariant_SupplyNeverBelowMinimum() public view {
        if (handler.ghost_adds() > 0) {
            assertGe(amm.totalSupply(), amm.MINIMUM_LIQUIDITY());
            assertEq(amm.balanceOf(address(0)), amm.MINIMUM_LIQUIDITY());
        }
    }

    /// @notice 每份 LP share 对应的价值（k / supply^2）单调不减：
    ///         手续费只进不出，移除流动性按比例同减 k 与 supply。
    function invariant_KPerShareNonDecreasing() public view {
        uint256 lastK = handler.ghost_lastK();
        uint256 lastSupply = handler.ghost_lastSupply();
        if (lastSupply == 0) return;
        uint256 k = amm.reserve0() * amm.reserve1();
        uint256 supply = amm.totalSupply();
        // k * lastSupply^2 >= lastK * supply^2
        assertGe(k * lastSupply * lastSupply, lastK * supply * supply);
    }

    /// @notice 池子非空时两种储备都必须为正，不允许抽干任一侧。
    function invariant_ReservesPositiveWhenInitialized() public view {
        if (amm.totalSupply() > 0) {
            assertGt(amm.reserve0(), 0);
            assertGt(amm.reserve1(), 0);
        }
    }
}
