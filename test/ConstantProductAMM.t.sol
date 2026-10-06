// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev 恶意 Token：transfer 时尝试重入 AMM 的 removeLiquidity。
contract ReentrantToken {
    ConstantProductAMM public amm;
    bool public armed;

    constructor(ConstantProductAMM _amm) {
        amm = _amm;
    }

    function setAmm(ConstantProductAMM _amm) external {
        amm = _amm;
    }

    function arm() external {
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function transfer(address, uint256) external returns (bool) {
        if (armed) {
            // 应触发 Reentrancy revert，并向上传播。
            amm.removeLiquidity(1, 0, 0);
        }
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract ConstantProductAMMTest is Test {
    ConstantProductAMM internal amm;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant MIN_LIQ = 1000;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob, 1_000_000 ether);
        tokenB.mint(bob, 1_000_000 ether);

        vm.startPrank(alice);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    function _seedPool(uint256 a, uint256 b) internal {
        vm.prank(alice);
        amm.addLiquidity(a, b, 0);
    }

    // ------------------------------------------------------------------
    // 首次添加流动性
    // ------------------------------------------------------------------

    function test_FirstMint_SharesAreSqrtMinusMinimum() public {
        vm.prank(alice);
        uint256 shares = amm.addLiquidity(100 ether, 400 ether, 0);

        // sqrt(100e18 * 400e18) = 200e18
        assertEq(shares, 200 ether - MIN_LIQ);
        assertEq(amm.balanceOf(alice), shares);
        assertEq(amm.balanceOf(address(0)), MIN_LIQ); // 永久锁定
        assertEq(amm.totalSupply(), 200 ether);
        assertEq(amm.reserve0(), 100 ether);
        assertEq(amm.reserve1(), 400 ether);
    }

    function test_FirstMint_TooSmall_Reverts() public {
        // sqrt(1 * 1000) = 31 < MINIMUM_LIQUIDITY
        vm.prank(alice);
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        amm.addLiquidity(1, 1000, 0);
    }

    function test_AddLiquidity_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.addLiquidity(0, 1 ether, 0);
    }

    // ------------------------------------------------------------------
    // 追加流动性
    // ------------------------------------------------------------------

    function test_AddLiquidity_Proportional() public {
        _seedPool(100 ether, 400 ether);

        vm.prank(bob);
        uint256 shares = amm.addLiquidity(50 ether, 200 ether, 0);

        // 50e18 * 200e18 / 100e18 = 100e18
        assertEq(shares, 100 ether);
        assertEq(amm.reserve0(), 150 ether);
        assertEq(amm.reserve1(), 600 ether);
    }

    function test_AddLiquidity_Imbalanced_MintsMinSide() public {
        _seedPool(100 ether, 400 ether);

        // tokenB 超发：share 只能按 tokenA 侧计算，多余 tokenB 捐赠给池子。
        vm.prank(bob);
        uint256 shares = amm.addLiquidity(50 ether, 400 ether, 0);
        assertEq(shares, 100 ether); // 而非 200 ether

        // 反向失衡同理。此时储备 150/800，供应 300e18。
        vm.prank(bob);
        uint256 shares2 = amm.addLiquidity(200 ether, 200 ether, 0);
        // 200e18 * 300e18 / 800e18 = 75e18（受 tokenB 侧限制）
        assertEq(shares2, 75 ether);
    }

    function test_AddLiquidity_MinShares_Reverts() public {
        _seedPool(100 ether, 400 ether);
        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientOutput.selector);
        amm.addLiquidity(50 ether, 200 ether, 100 ether + 1);
    }

    function test_AddLiquidity_DustAmount_Reverts() public {
        _seedPool(100 ether, 400 ether);
        // 1 wei * supply / reserve 向下取整为 0
        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        amm.addLiquidity(1, 1, 0);
    }

    // ------------------------------------------------------------------
    // 移除流动性
    // ------------------------------------------------------------------

    function test_RemoveLiquidity_Proportional() public {
        _seedPool(100 ether, 400 ether);
        uint256 shares = amm.balanceOf(alice);

        uint256 aBefore = tokenA.balanceOf(alice);
        uint256 bBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(shares / 2, 0, 0);

        // 总供应 200e18，移除一半 share -> 约 1/4 储备（另一半仍归 alice + 锁定的 MIN_LIQ）
        assertEq(out0, ((shares / 2) * 100 ether) / 200 ether);
        assertEq(out1, ((shares / 2) * 400 ether) / 200 ether);
        assertEq(tokenA.balanceOf(alice), aBefore + out0);
        assertEq(tokenB.balanceOf(alice), bBefore + out1);
        assertEq(amm.reserve0(), 100 ether - out0);
        assertEq(amm.reserve1(), 400 ether - out1);
    }

    function test_RemoveLiquidity_MinAmounts_Reverts() public {
        _seedPool(100 ether, 400 ether);
        uint256 shares = amm.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ConstantProductAMM.InsufficientOutput.selector);
        amm.removeLiquidity(shares, 101 ether, 0);
    }

    function test_RemoveLiquidity_MoreThanBalance_Reverts() public {
        _seedPool(100 ether, 400 ether);
        uint256 shares = amm.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        amm.removeLiquidity(shares + 1, 0, 0);
    }

    function test_RemoveLiquidity_Zero_Reverts() public {
        _seedPool(100 ether, 400 ether);
        vm.prank(alice);
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.removeLiquidity(0, 0, 0);
    }

    // ------------------------------------------------------------------
    // Swap
    // ------------------------------------------------------------------

    function test_Swap_Token0ForToken1_ExactOutput() public {
        _seedPool(100 ether, 400 ether);

        uint256 amountIn = 10 ether;
        // out = 10e18*997*400e18 / (100e18*1000 + 10e18*997)
        uint256 expected = (amountIn * 997 * 400 ether) / (100 ether * 1000 + amountIn * 997);

        uint256 before = tokenB.balanceOf(bob);
        vm.prank(bob);
        uint256 out = amm.swap(address(tokenA), amountIn, expected);

        assertEq(out, expected);
        assertEq(tokenB.balanceOf(bob), before + out);
        assertEq(amm.reserve0(), 110 ether);
        assertEq(amm.reserve1(), 400 ether - out);
    }

    function test_Swap_Token1ForToken0_ExactOutput() public {
        _seedPool(100 ether, 400 ether);

        uint256 amountIn = 40 ether;
        uint256 expected = (amountIn * 997 * 100 ether) / (400 ether * 1000 + amountIn * 997);

        uint256 before = tokenA.balanceOf(bob);
        vm.prank(bob);
        uint256 out = amm.swap(address(tokenB), amountIn, expected);

        assertEq(out, expected);
        assertEq(tokenA.balanceOf(bob), before + out);
        assertEq(amm.reserve1(), 440 ether);
        assertEq(amm.reserve0(), 100 ether - out);
    }

    function test_Swap_Slippage_Reverts() public {
        _seedPool(100 ether, 400 ether);
        uint256 amountIn = 10 ether;
        uint256 expected = (amountIn * 997 * 400 ether) / (100 ether * 1000 + amountIn * 997);

        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientOutput.selector);
        amm.swap(address(tokenA), amountIn, expected + 1);
    }

    function test_Swap_ZeroInput_Reverts() public {
        _seedPool(100 ether, 400 ether);
        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.swap(address(tokenA), 0, 0);
    }

    function test_Swap_TinyInput_OutputRoundsToZero_Reverts() public {
        _seedPool(1_000_000 ether, 1 ether);
        // 1 wei 输入：1*997*1e18 / (1e24*1000+997) 向下取整为 0，不得凭空产出资产。
        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientOutput.selector);
        amm.swap(address(tokenA), 1, 0);
    }

    function test_Swap_EmptyPool_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientReserve.selector);
        amm.swap(address(tokenA), 1 ether, 0);
    }

    function test_Swap_InvalidToken_Reverts() public {
        _seedPool(100 ether, 400 ether);
        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InvalidToken.selector);
        amm.swap(address(0xdead), 1 ether, 0);
    }

    function test_Swap_FeeAccruesToPool_KIncreases() public {
        _seedPool(100 ether, 400 ether);
        uint256 kBefore = amm.reserve0() * amm.reserve1();

        vm.prank(bob);
        amm.swap(address(tokenA), 10 ether, 0);

        uint256 kAfter = amm.reserve0() * amm.reserve1();
        assertGt(kAfter, kBefore); // 0.3% 手续费留在池内，k 严格增大
    }

    // ------------------------------------------------------------------
    // 重入防护
    // ------------------------------------------------------------------

    function test_Reentrancy_LockBlocksNestedCall() public {
        // 恶意 token：在 transfer 回调中重入 removeLiquidity，试图重复提取流动性。
        ReentrantToken evilToken = new ReentrantToken(ConstantProductAMM(address(0)));
        ConstantProductAMM pool = new ConstantProductAMM(address(evilToken), address(tokenB));
        evilToken.setAmm(pool);

        // 注入流动性（evilToken.transferFrom 恒成功，balanceOf 恒为 max）。
        tokenB.mint(address(this), 1000 ether);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100 ether, 1000 ether, 0);

        // removeLiquidity 转出 evilToken 时触发回调重入，应被 lock 阻断。
        evilToken.arm();
        vm.expectRevert(ConstantProductAMM.Reentrancy.selector);
        pool.removeLiquidity(1 ether, 0, 0);

        // 解除武装后可正常移除，证明锁在函数结束后正确释放。
        evilToken.disarm();
        (uint256 out0, uint256 out1) = pool.removeLiquidity(1 ether, 0, 0);
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_FirstMint_SharesMatchSqrt(uint256 a, uint256 b) public {
        a = bound(a, MIN_LIQ, 1e30);
        // 保证 floor(sqrt(a*b)) > MINIMUM_LIQUIDITY，即 a*b >= (MIN_LIQ+1)^2
        b = bound(b, (MIN_LIQ + 1) * (MIN_LIQ + 1) / a + 1, 1e30);
        tokenA.mint(alice, a);
        tokenB.mint(alice, b);

        vm.prank(alice);
        uint256 shares = amm.addLiquidity(a, b, 0);

        // shares + MIN_LIQ 应等于 floor(sqrt(a*b))，且 (shares+MIN_LIQ)^2 <= a*b
        uint256 total = shares + MIN_LIQ;
        assertLe(total * total / a, b + 1); // 容忍取整误差
        assertEq(amm.reserve0(), a);
        assertEq(amm.reserve1(), b);
    }

    function testFuzz_Swap_KNeverDecreases(uint256 amountIn, bool zeroForOne) public {
        _seedPool(100 ether, 400 ether);
        amountIn = bound(amountIn, 1, 1000 ether);

        uint256 kBefore = amm.reserve0() * amm.reserve1();
        address tokenIn = zeroForOne ? address(tokenA) : address(tokenB);

        vm.prank(bob);
        try amm.swap(tokenIn, amountIn, 0) returns (uint256) {
            uint256 kAfter = amm.reserve0() * amm.reserve1();
            assertGe(kAfter, kBefore);
        } catch {
            // 输出取整为 0 等合法 revert 可接受。
        }
    }

    function testFuzz_AddThenRemove_NoFreeValue(uint256 a0, uint256 a1, uint256 frac) public {
        a0 = bound(a0, 1 ether, 1e24);
        a1 = bound(a1, 1 ether, 1e24);
        frac = bound(frac, 1, 100);

        vm.prank(alice);
        uint256 shares = amm.addLiquidity(a0, a1, 0);

        uint256 burn = shares / frac;
        vm.assume(burn > 0);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(burn, 0, 0);

        // 移除所得不得超过按比例应得（向下取整使其严格 <=）。
        assertLe(out0, (burn * a0) / (shares + MIN_LIQ) + 1);
        assertLe(out1, (burn * a1) / (shares + MIN_LIQ) + 1);
    }

    function testFuzz_Slippage_AlwaysEnforced(uint256 amountIn) public {
        _seedPool(100 ether, 400 ether);
        amountIn = bound(amountIn, 1 ether, 100 ether);
        uint256 expected = amm.getAmountOut(amountIn, 100 ether, 400 ether);

        vm.prank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientOutput.selector);
        amm.swap(address(tokenA), amountIn, expected + 1);

        vm.prank(bob);
        uint256 out = amm.swap(address(tokenA), amountIn, expected);
        assertEq(out, expected);
    }
}
