// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../../src/ConstantProductAMM.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AMMHandler} from "./AMMHandler.sol";

contract AMMInvariantTest is Test {
    ConstantProductAMM internal amm;
    MockERC20 internal token0;
    MockERC20 internal token1;
    AMMHandler internal handler;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        amm = new ConstantProductAMM(address(token0), address(token1));
        handler = new AMMHandler(amm, token0, token1, 4);

        targetContract(address(handler));
    }

    /// @notice 储备永远等于 AMM 合约实际持有的 token 余额（记账一致性）
    function invariant_reservesMatchBalances() public view {
        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @notice LP 总份额 == 所有持有者份额之和（含永久锁定部分）
    function invariant_lpSupplyConserved() public view {
        uint256 sum = amm.balanceOf(amm.LOCKED_LP());
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            sum += amm.balanceOf(handler.actorAt(i));
        }
        assertEq(amm.totalSupply(), sum);
    }

    /// @notice token 总量守恒：铸造总量 == AMM 持有 + 所有 actor 持有（无人凭空获利）
    function invariant_tokenConservation() public view {
        uint256 sum0 = token0.balanceOf(address(amm));
        uint256 sum1 = token1.balanceOf(address(amm));
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            sum0 += token0.balanceOf(handler.actorAt(i));
            sum1 += token1.balanceOf(handler.actorAt(i));
        }
        assertEq(sum0, handler.ghost_minted0());
        assertEq(sum1, handler.ghost_minted1());
    }

    /// @notice 池子非空时，每份 LP 对应的 k（k / totalSupply^2 量级）不因取整被显著稀释：
    ///         k * 1e18 / totalSupply^2 不得跌破首次注入时锁定流动性对应的下界。
    function invariant_kPerShareBoundedBelow() public view {
        uint256 supply = amm.totalSupply();
        assertGt(supply, 0);
        // 种子池为 100e18/100e18：初始 kPerShare = k/S^2 = 1（无量纲）。
        // 手续费只会推高 k，取整误差相对量级可忽略，这里允许 1% 的宽松下界。
        uint256 kPerShareScaled = (amm.k() * 1e18) / (supply * supply);
        assertGe(kPerShareScaled, 0.99e18);
    }

    /// @notice 储备永远为正（池子一旦建立就不会被掏空）
    function invariant_reservesAlwaysPositive() public view {
        assertGt(amm.reserve0(), 0);
        assertGt(amm.reserve1(), 0);
    }
}
