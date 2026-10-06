// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

interface IAttackTarget {
    function removeLiquidity(uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256, uint256);
}

/// @notice 恶意 Token：在 AMM 向外部转账（transfer）时回调重入 removeLiquidity，
///         用于验证 AMM 的重入锁能阻止重复提取流动性。
contract ReentrantToken is MockERC20 {
    IAttackTarget public target;
    uint256 public attackShares;
    bool public armed;
    bool public attackSucceeded;

    constructor() MockERC20("Reentrant Token", "RKT", 18) {}

    function arm(address _target, uint256 _shares) external {
        target = IAttackTarget(_target);
        attackShares = _shares;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // AMM 在 removeLiquidity 中调用本 transfer 向用户付款时触发重入
        if (armed && address(target) != address(0)) {
            armed = false;
            // 若 AMM 没有重入保护，这里会第二次提取流动性
            try target.removeLiquidity(attackShares, 0, 0, msg.sender) {
                attackSucceeded = true;
            } catch {}
        }
        return super.transfer(to, amount);
    }
}
