// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../../src/ConstantProductAMM.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Invariant 测试的随机操作执行器：在若干 actor 之间随机加/撤流动性与双向 swap，
///         并记录幽灵变量（ghost variables）供不变量断言使用。
contract AMMHandler is Test {
    ConstantProductAMM public amm;
    MockERC20 public token0;
    MockERC20 public token1;

    address[] public actors;
    address internal currentActor;

    // 幽灵变量
    uint256 public ghost_minted0;      // token0 总铸造量（守恒基准）
    uint256 public ghost_minted1;
    uint256 public ghost_swapCount;
    uint256 public ghost_lastK;        // 上一次 swap 前的 k（swap 后 k 不得下降）

    modifier useActor(uint256 actorIndex) {
        currentActor = actors[bound(actorIndex, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(ConstantProductAMM _amm, MockERC20 _token0, MockERC20 _token1, uint256 actorCount) {
        amm = _amm;
        token0 = _token0;
        token1 = _token1;

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = makeAddr(vm.toString(i));
            actors.push(actor);
            token0.mint(actor, 1_000_000 ether);
            token1.mint(actor, 1_000_000 ether);
            ghost_minted0 += 1_000_000 ether;
            ghost_minted1 += 1_000_000 ether;
            vm.prank(actor);
            token0.approve(address(amm), type(uint256).max);
            vm.prank(actor);
            token1.approve(address(amm), type(uint256).max);
        }

        // 种子流动性，避免空池
        vm.startPrank(actors[0]);
        amm.addLiquidity(100 ether, 100 ether, 0, actors[0]);
        vm.stopPrank();
    }

    function addLiquidity(uint256 actorIndex, uint256 amount0, uint256 amount1) external useActor(actorIndex) {
        amount0 = bound(amount0, 1_000_000, 10_000 ether);
        amount1 = bound(amount1, 1_000_000, 10_000 ether);
        amm.addLiquidity(amount0, amount1, 0, currentActor);
    }

    function removeLiquidity(uint256 actorIndex, uint256 shares) external useActor(actorIndex) {
        uint256 held = amm.balanceOf(currentActor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        amm.removeLiquidity(shares, 0, 0, currentActor);
    }

    function swap0For1(uint256 actorIndex, uint256 amountIn) external useActor(actorIndex) {
        amountIn = bound(amountIn, 1, 50_000 ether);
        uint256 out = amm.getAmountOut(amountIn, amm.reserve0(), amm.reserve1());
        if (out == 0) return;
        ghost_lastK = amm.k();
        amm.swapExactIn(address(token0), amountIn, out, currentActor);
        // 手续费留存：swap 后 k 不得下降
        assertGe(amm.k(), ghost_lastK);
        ghost_swapCount++;
    }

    function swap1For0(uint256 actorIndex, uint256 amountIn) external useActor(actorIndex) {
        amountIn = bound(amountIn, 1, 50_000 ether);
        uint256 out = amm.getAmountOut(amountIn, amm.reserve1(), amm.reserve0());
        if (out == 0) return;
        ghost_lastK = amm.k();
        amm.swapExactIn(address(token1), amountIn, out, currentActor);
        assertGe(amm.k(), ghost_lastK);
        ghost_swapCount++;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
