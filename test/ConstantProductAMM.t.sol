// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract ConstantProductAMMTest is Test {
    ConstantProductAMM internal amm;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant MIN_LIQ = 1000;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob, 1_000_000 ether);
        tokenB.mint(bob, 1_000_000 ether);

        vm.prank(alice);
        tokenA.approve(address(amm), type(uint256).max);
        vm.prank(alice);
        tokenB.approve(address(amm), type(uint256).max);
        vm.prank(bob);
        tokenA.approve(address(amm), type(uint256).max);
        vm.prank(bob);
        tokenB.approve(address(amm), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // 首次添加流动性
    // ---------------------------------------------------------------

    function test_FirstAddMintsSqrtShares() public {
        vm.prank(alice);
        uint256 shares = amm.addLiquidity(1 ether, 4 ether, 0, alice);

        // sqrt(1e18 * 4e18) = 2e18，其中 1000 wei 永久锁定
        assertEq(shares, 2 ether - MIN_LIQ);
        assertEq(amm.balanceOf(alice), 2 ether - MIN_LIQ);
        assertEq(amm.balanceOf(amm.LOCKED_LP()), MIN_LIQ);
        assertEq(amm.totalSupply(), 2 ether);
        assertEq(amm.reserve0(), 1 ether);
        assertEq(amm.reserve1(), 4 ether);
        assertEq(amm.k(), 4 ether * 1 ether);
    }

    function test_FirstAddZeroAmountReverts() public {
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.addLiquidity(0, 1 ether, 0, alice);
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.addLiquidity(1 ether, 0, 0, alice);
    }

    function test_FirstAddTooSmallReverts() public {
        // sqrt(1000 * 1000) = 1000 <= MINIMUM_LIQUIDITY，无法留出锁定份额
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        amm.addLiquidity(MIN_LIQ, MIN_LIQ, 0, alice);
    }

    function test_FirstAddMinSharesSlippageReverts() public {
        vm.expectRevert(ConstantProductAMM.SlippageExceeded.selector);
        amm.addLiquidity(1 ether, 4 ether, 2 ether, alice); // 实际只能铸 2e18 - 1000
    }

    // ---------------------------------------------------------------
    // 追加流动性
    // ---------------------------------------------------------------

    function _seedPool() internal {
        vm.prank(alice);
        amm.addLiquidity(10 ether, 40 ether, 0, alice);
    }

    function test_AddLiquidityProportional() public {
        _seedPool();
        uint256 supplyBefore = amm.totalSupply();

        vm.prank(bob);
        uint256 shares = amm.addLiquidity(5 ether, 20 ether, 0, bob);

        // 按比例：5e18 * S / 10e18 = S / 2
        assertEq(shares, supplyBefore / 2);
        assertEq(amm.reserve0(), 15 ether);
        assertEq(amm.reserve1(), 60 ether);
    }

    function test_AddLiquidityImbalancedOnlyPullsOptimal() public {
        _seedPool();
        uint256 b0Before = tokenA.balanceOf(bob);
        uint256 b1Before = tokenB.balanceOf(bob);

        // tokenB 严重过量：只应按比例拉取最优数量，多余部分留在用户手中
        vm.prank(bob);
        uint256 shares = amm.addLiquidity(5 ether, 100 ether, 0, bob);

        assertEq(tokenA.balanceOf(bob), b0Before - 5 ether);
        assertEq(tokenB.balanceOf(bob), b1Before - 20 ether); // 只拉取 20，而非 100
        assertEq(shares, amm.totalSupply() / 3); // 池子从 10/40 变 15/60，份额占 1/3

        // 反向失衡同样只拉最优数量：(100, 6) -> 实际拉取 (1.5, 6)
        vm.prank(bob);
        amm.addLiquidity(100 ether, 6 ether, 0, bob);
        assertEq(amm.reserve0(), 16.5 ether);
        assertEq(amm.reserve1(), 66 ether);
    }

    function test_AddLiquidityImbalancedNoFreeValue() public {
        _seedPool();
        // 用户存入失衡比例，立即全部撤出，不得获得无成本价值
        uint256 a0Before = tokenA.balanceOf(bob);
        uint256 a1Before = tokenB.balanceOf(bob);

        vm.startPrank(bob);
        uint256 shares = amm.addLiquidity(1 ether, 1000 ether, 0, bob);
        amm.removeLiquidity(amm.balanceOf(bob), 0, 0, bob);
        vm.stopPrank();

        assertGt(shares, 0);
        // 撤出后余额不得超过参与前（无免费价值），损耗仅为取整尘埃
        assertLe(tokenA.balanceOf(bob), a0Before);
        assertLe(tokenB.balanceOf(bob), a1Before);
        assertGe(tokenA.balanceOf(bob) + 100, a0Before);
        assertGe(tokenB.balanceOf(bob) + 100, a1Before);
    }

    function test_AddLiquidityMinSharesReverts() public {
        _seedPool();
        vm.expectRevert(ConstantProductAMM.SlippageExceeded.selector);
        vm.prank(bob);
        amm.addLiquidity(5 ether, 20 ether, type(uint256).max, bob);
    }

    // ---------------------------------------------------------------
    // 移除流动性
    // ---------------------------------------------------------------

    function test_RemoveLiquidityProportional() public {
        _seedPool();
        uint256 shares = amm.balanceOf(alice);
        uint256 supply = amm.totalSupply();

        vm.prank(alice);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(shares / 2, 0, 0, alice);

        assertEq(out0, (shares / 2) * 10 ether / supply);
        assertEq(out1, (shares / 2) * 40 ether / supply);
        assertEq(amm.reserve0(), 10 ether - out0);
        assertEq(amm.reserve1(), 40 ether - out1);
    }

    function test_RemoveLiquidityMinAmountsReverts() public {
        _seedPool();
        uint256 shares = amm.balanceOf(alice);
        vm.expectRevert(ConstantProductAMM.SlippageExceeded.selector);
        vm.prank(alice);
        amm.removeLiquidity(shares, type(uint256).max, 0, alice);
    }

    function test_RemoveLiquidityZeroReverts() public {
        _seedPool();
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        vm.prank(alice);
        amm.removeLiquidity(0, 0, 0, alice);
    }

    function test_RemoveMoreThanBalanceReverts() public {
        _seedPool();
        uint256 shares = amm.balanceOf(alice);
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        vm.prank(alice);
        amm.removeLiquidity(shares + 1, 0, 0, alice);
    }

    // ---------------------------------------------------------------
    // Swap：双向、手续费、滑点
    // ---------------------------------------------------------------

    function test_SwapToken0ForToken1() public {
        _seedPool();
        uint256 kBefore = amm.k();

        uint256 expected = amm.getAmountOut(1 ether, 10 ether, 40 ether);
        vm.prank(bob);
        uint256 out = amm.swapExactIn(address(tokenA), 1 ether, expected, bob);

        assertEq(out, expected);
        assertEq(tokenB.balanceOf(bob), 1_000_000 ether + out); // bob 未加池，仅付出 1 ether tokenA
        assertEq(amm.reserve0(), 11 ether);
        assertEq(amm.reserve1(), 40 ether - out);
        // 手续费留存：k 严格增大
        assertGt(amm.k(), kBefore);
    }

    function test_SwapToken1ForToken0() public {
        _seedPool();
        uint256 kBefore = amm.k();

        uint256 expected = amm.getAmountOut(4 ether, 40 ether, 10 ether);
        vm.prank(bob);
        uint256 out = amm.swapExactIn(address(tokenB), 4 ether, expected, bob);

        assertEq(out, expected);
        assertEq(amm.reserve1(), 44 ether);
        assertEq(amm.reserve0(), 10 ether - out);
        assertGt(amm.k(), kBefore);
    }

    function test_SwapFeeMatchesFormula() public {
        _seedPool();
        // dy = dx*997*ry / (rx*1000 + dx*997)
        uint256 dx = 3 ether;
        uint256 expected = (dx * 997 * 40 ether) / (10 ether * 1000 + dx * 997);
        vm.prank(bob);
        uint256 out = amm.swapExactIn(address(tokenA), dx, 0, bob);
        assertEq(out, expected);
    }

    function test_SwapZeroAmountReverts() public {
        _seedPool();
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        vm.prank(bob);
        amm.swapExactIn(address(tokenA), 0, 0, bob);
    }

    function test_SwapTinyInputReverts() public {
        // tokenA 相对极便宜的池子：1 wei 输入按公式输出为 0（向下取整），必须 revert 而非白送 0 输出
        vm.prank(alice);
        amm.addLiquidity(1000 ether, 1 ether, 0, alice);
        assertEq(amm.getAmountOut(1, 1000 ether, 1 ether), 0);
        vm.expectRevert(ConstantProductAMM.InsufficientOutputAmount.selector);
        vm.prank(bob);
        amm.swapExactIn(address(tokenA), 1, 0, bob);
    }

    function test_SwapSlippageReverts() public {
        _seedPool();
        uint256 expected = amm.getAmountOut(1 ether, 10 ether, 40 ether);
        vm.expectRevert(ConstantProductAMM.SlippageExceeded.selector);
        vm.prank(bob);
        amm.swapExactIn(address(tokenA), 1 ether, expected + 1, bob);
    }

    function test_SwapInvalidTokenReverts() public {
        _seedPool();
        vm.expectRevert(ConstantProductAMM.InvalidToken.selector);
        vm.prank(bob);
        amm.swapExactIn(address(0x1234), 1 ether, 0, bob);
    }

    function test_SwapNeverDrainsReserve() public {
        _seedPool();
        // 巨大输入也只能渐近接近储备，永远换不光
        vm.prank(bob);
        uint256 out = amm.swapExactIn(address(tokenA), 900_000 ether, 0, bob);
        assertLt(out, 40 ether);
        assertGt(amm.reserve1(), 0);
    }

    function test_SwapOnEmptyPoolReverts() public {
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        vm.prank(bob);
        amm.swapExactIn(address(tokenA), 1 ether, 0, bob);
    }

    // ---------------------------------------------------------------
    // 重入防护
    // ---------------------------------------------------------------

    function test_ReentrancyOnRemoveLiquidityBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        ConstantProductAMM amm2 = new ConstantProductAMM(address(evil), address(tokenA));

        evil.mint(alice, 100 ether);
        vm.prank(alice);
        evil.approve(address(amm2), type(uint256).max);
        vm.prank(alice);
        tokenA.approve(address(amm2), type(uint256).max);

        vm.prank(alice);
        uint256 shares = amm2.addLiquidity(10 ether, 10 ether, 0, alice);

        // 武装恶意 token：AMM 付款时回调重入 removeLiquidity
        evil.arm(address(amm2), shares / 2);

        // 正常提取一半流动性成功；重入尝试被 Locked() 阻止，无法重复提取
        uint256 evilBefore = evil.balanceOf(alice);
        vm.prank(alice);
        amm2.removeLiquidity(shares / 2, 0, 0, alice);

        assertFalse(evil.attackSucceeded()); // 重入未成功
        assertEq(evil.balanceOf(alice) - evilBefore, shares / 2); // 只拿到一次付款
        assertEq(amm2.reserve0(), 10 ether - shares / 2);
        assertEq(amm2.reserve1(), 10 ether - shares / 2);
    }

    // ---------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------

    function testFuzz_FirstAddThenValueConserved(uint128 x, uint128 y) public {
        // 下限 1e5 远大于 MINIMUM_LIQUIDITY，保证全额撤出时两侧数量取整后仍为正
        x = uint128(bound(x, 100_000, 1_000_000 ether));
        y = uint128(bound(y, 100_000, 1_000_000 ether));
        uint256 prod = uint256(x) * uint256(y);
        vm.assume(prod > MIN_LIQ * MIN_LIQ);

        vm.prank(alice);
        uint256 shares = amm.addLiquidity(x, y, 0, alice);
        assertEq(amm.totalSupply(), shares + MIN_LIQ);
        // k 与储备一致
        assertEq(amm.k(), prod);

        // 立即全部撤出（除锁定部分），不得凭空增值
        vm.prank(alice);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(shares, 0, 0, alice);
        assertLe(out0, x);
        assertLe(out1, y);
        assertGe(out0 + 1, uint256(x) * shares / (shares + MIN_LIQ)); // 取整损耗有界
    }

    function testFuzz_SwapKeepsInvariantNonDecreasing(uint112 amountIn, bool zeroForOne) public {
        _seedPool();
        amountIn = uint112(bound(amountIn, 1, 100_000 ether));
        uint256 kBefore = amm.k();

        address tokenIn = zeroForOne ? address(tokenA) : address(tokenB);
        uint256 expected = zeroForOne
            ? amm.getAmountOut(amountIn, 10 ether, 40 ether)
            : amm.getAmountOut(amountIn, 40 ether, 10 ether);
        vm.assume(expected > 0);

        vm.prank(bob);
        uint256 out = amm.swapExactIn(tokenIn, amountIn, expected, bob);
        assertEq(out, expected);
        assertGe(amm.k(), kBefore); // 含手续费后 invariant 不得下降
    }

    function testFuzz_AddRemoveRoundTrip(uint64 x, uint64 y) public {
        _seedPool();
        // 下限 1000 wei 保证最优投入数量与份额均不为 0
        x = uint64(bound(x, 1000, 10 ether));
        y = uint64(bound(y, 1000, 10 ether));

        uint256 a0 = tokenA.balanceOf(bob);
        uint256 a1 = tokenB.balanceOf(bob);

        vm.prank(bob);
        uint256 shares = amm.addLiquidity(x, y, 0, bob);
        vm.assume(shares > 0);

        vm.prank(bob);
        amm.removeLiquidity(shares, 0, 0, bob);

        // 往返后余额不得超过参与前（无免费价值），且损耗仅为取整尘埃
        assertLe(tokenA.balanceOf(bob), a0);
        assertLe(tokenB.balanceOf(bob), a1);
        assertGe(tokenA.balanceOf(bob) + 100, a0);
        assertGe(tokenB.balanceOf(bob) + 100, a1);
    }

    function testFuzz_SlippageBoundary(uint112 amountIn) public {
        _seedPool();
        amountIn = uint112(bound(amountIn, 1, 10_000 ether));
        uint256 expected = amm.getAmountOut(amountIn, 10 ether, 40 ether);
        vm.assume(expected > 0);

        // minOut == expected：成交
        vm.prank(bob);
        amm.swapExactIn(address(tokenA), amountIn, expected, bob);

        // minOut == expected + 1：必须 revert
        vm.expectRevert(ConstantProductAMM.SlippageExceeded.selector);
        vm.prank(bob);
        amm.swapExactIn(address(tokenA), amountIn, expected + 1, bob);
    }
}
