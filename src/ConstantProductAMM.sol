// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title ConstantProductAMM
/// @notice 完全本地运行的恒定乘积 AMM（x * y = k），自带 LP share ERC20。
///         手续费 0.3%（997/1000），所有除法向下取整，利于池子。
contract ConstantProductAMM {
    // ------------------------------------------------------------------
    // LP share (ERC20)
    // ------------------------------------------------------------------
    string public constant name = "ConstantProduct LP";
    string public constant symbol = "CP-LP";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------
    // Pool state
    // ------------------------------------------------------------------
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    /// @dev 手续费：0.3%，即 997/1000。
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;

    /// @dev 首次加池时永久锁定的最小流动性，防止除零与通胀攻击。
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    // ------------------------------------------------------------------
    // Reentrancy lock
    // ------------------------------------------------------------------
    uint256 private _unlocked = 1;

    modifier lock() {
        if (_unlocked == 0) revert Reentrancy();
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    // ------------------------------------------------------------------
    // Events & errors
    // ------------------------------------------------------------------
    event Mint(address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Burn(address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    error Reentrancy();
    error ZeroAmount();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error InsufficientReserve();
    error InvalidToken();
    error TransferFailed();
    error InvariantViolated();

    constructor(address _token0, address _token1) {
        if (_token0 == address(0) || _token1 == address(0) || _token0 == _token1) revert InvalidToken();
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    // ------------------------------------------------------------------
    // ERC20 (LP share)
    // ------------------------------------------------------------------
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientOutput();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------

    /// @notice 添加流动性。首次铸造 sqrt(x*y) - MINIMUM_LIQUIDITY；
    ///         之后按 min(a0/r0, a1/r1) * totalSupply 铸造，比例失衡的部分视为捐赠，
    ///         不会为调用者铸造多余 share。
    function addLiquidity(uint256 amount0, uint256 amount1, uint256 minShares)
        external
        lock
        returns (uint256 shares)
    {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        // 先转入资产（交互），再基于实际记账储备计算 share。
        _safeTransferFrom(token0, msg.sender, address(this), amount0);
        _safeTransferFrom(token1, msg.sender, address(this), amount1);

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            shares = _sqrt(amount0 * amount1);
            if (shares <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
            _mint(address(0), MINIMUM_LIQUIDITY); // 永久锁定
            shares -= MINIMUM_LIQUIDITY;
        } else {
            uint256 shares0 = (amount0 * _totalSupply) / reserve0;
            uint256 shares1 = (amount1 * _totalSupply) / reserve1;
            shares = shares0 < shares1 ? shares0 : shares1;
            if (shares == 0) revert InsufficientLiquidity();
        }
        if (shares < minShares) revert InsufficientOutput();

        _mint(msg.sender, shares);

        // 状态更新（效果）在资产转移之后、函数结束前完成，重入被 lock 阻断。
        reserve0 += amount0;
        reserve1 += amount1;

        emit Mint(msg.sender, amount0, amount1, shares);
    }

    /// @notice 移除流动性，按 share 占比返还两种资产。
    function removeLiquidity(uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroAmount();
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0 || balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        // 向下取整，误差利于池子。
        amount0 = (shares * reserve0) / _totalSupply;
        amount1 = (shares * reserve1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidity();
        if (amount0 < minAmount0 || amount1 < minAmount1) revert InsufficientOutput();

        // Checks-Effects-Interactions：先销毁 share、更新储备，再转出资产。
        _burn(msg.sender, shares);
        reserve0 -= amount0;
        reserve1 -= amount1;

        _safeTransfer(token0, msg.sender, amount0);
        _safeTransfer(token1, msg.sender, amount1);

        emit Burn(msg.sender, amount0, amount1, shares);
    }

    // ------------------------------------------------------------------
    // Swap
    // ------------------------------------------------------------------

    /// @notice 恒定乘积兑换，收取 0.3% 手续费。输出低于 minAmountOut 时 revert。
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        lock
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        bool zeroForOne;
        if (tokenIn == address(token0)) {
            zeroForOne = true;
        } else if (tokenIn == address(token1)) {
            zeroForOne = false;
        } else {
            revert InvalidToken();
        }

        (uint256 resIn, uint256 resOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        if (resIn == 0 || resOut == 0) revert InsufficientReserve();

        amountOut = getAmountOut(amountIn, resIn, resOut);
        if (amountOut == 0) revert InsufficientOutput();
        if (amountOut < minAmountOut) revert InsufficientOutput();
        if (amountOut >= resOut) revert InsufficientReserve();

        // 先收取输入资产。
        _safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn);

        // 更新储备（效果），再转出输出资产（交互）。
        if (zeroForOne) {
            reserve0 = resIn + amountIn;
            reserve1 = resOut - amountOut;
        } else {
            reserve1 = resIn + amountIn;
            reserve0 = resOut - amountOut;
        }

        IERC20 tokenOut = zeroForOne ? token1 : token0;
        _safeTransfer(tokenOut, msg.sender, amountOut);

        // 手续费后的 invariant 校验：(resIn + amountIn*997/1000) * resOutNew >= resIn*resOut（放大 1000 倍）。
        uint256 adjIn = resIn * FEE_DENOMINATOR + amountIn * FEE_NUMERATOR;
        if (adjIn * (resOut - amountOut) < resIn * resOut * FEE_DENOMINATOR) revert InvariantViolated();

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    /// @notice 含手续费的输出报价：out = (in * 997 * resOut) / (resIn * 1000 + in * 997)。
    function getAmountOut(uint256 amountIn, uint256 resIn, uint256 resOut) public pure returns (uint256) {
        if (amountIn == 0) revert ZeroAmount();
        if (resIn == 0 || resOut == 0) revert InsufficientReserve();
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        return (amountInWithFee * resOut) / (resIn * FEE_DENOMINATOR + amountInWithFee);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (!token.transferFrom(from, to, amount)) revert TransferFailed();
    }

    /// @dev Babylonian 平方根，向下取整。
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
