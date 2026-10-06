// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ConstantProductAMM
/// @notice 完全本地运行的恒定乘积 AMM（x * y = k），自身即 LP Token（ERC20）。
///         仅面向 Foundry 本地测试 EVM，不依赖任何外部服务、Oracle 或链上价格源。
/// @dev 安全假设：
///      - 两种 Token 均为标准 ERC20（无转账手续费、无 rebasing）；
///      - 所有外部状态变更函数均带重入锁，且遵循 checks-effects-interactions；
///      - 除法一律向下取整（floor），舍入误差永远有利于池子。
contract ConstantProductAMM {
    // ------------------------------------------------------------------
    // 错误
    // ------------------------------------------------------------------
    error Locked();                      // 重入
    error InvalidToken();                // 非法 token 地址
    error IdenticalTokens();             // 两种 token 相同
    error ZeroAmount();                  // 输入为 0
    error InsufficientLiquidity();       // 池子流动性不足 / 首次注入过少
    error InsufficientOutputAmount();    // 计算出的输出为 0
    error SlippageExceeded();            // 实际输出低于 minimum output
    error TransferFailed();              // ERC20 转账失败

    // ------------------------------------------------------------------
    // 事件
    // ------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        address indexed tokenOut,
        uint256 amountOut,
        address to
    );

    // ------------------------------------------------------------------
    // 常量
    // ------------------------------------------------------------------
    uint256 public constant MINIMUM_LIQUIDITY = 1000; // 首次注入时永久锁定的最小流动性
    uint256 public constant FEE_NUMERATOR = 997;      // 0.3% 手续费：997/1000
    uint256 public constant FEE_DENOMINATOR = 1000;
    address public constant LOCKED_LP = address(0xdead); // 最小流动性锁定地址

    // ------------------------------------------------------------------
    // 不可变配置
    // ------------------------------------------------------------------
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------
    uint256 public reserve0;
    uint256 public reserve1;

    string public constant name = "Goleta LP Token";
    string public constant symbol = "gLP";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 private _unlocked = 1;

    modifier nonReentrant() {
        if (_unlocked != 1) revert Locked();
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(address _token0, address _token1) {
        if (_token0 == _token1) revert IdenticalTokens();
        if (_token0 == address(0) || _token1 == address(0)) revert InvalidToken();
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    // ------------------------------------------------------------------
    // 外部入口
    // ------------------------------------------------------------------

    /// @notice 添加流动性，按当前储备比例铸造 LP share。
    /// @param amount0Desired 希望投入的 token0 数量
    /// @param amount1Desired 希望投入的 token1 数量
    /// @param minShares      可接受的最少 LP share（滑点保护）
    /// @param to             LP share 接收地址
    /// @return shares        实际铸造的 LP share
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 minShares,
        address to
    ) external nonReentrant returns (uint256 shares) {
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        uint256 amount0;
        uint256 amount1;
        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0) {
            // 首次注入：shares = sqrt(x * y)，并永久锁定 MINIMUM_LIQUIDITY
            uint256 rootK = _sqrt(amount0Desired * amount1Desired);
            if (rootK <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            shares = rootK - MINIMUM_LIQUIDITY;
            _mint(LOCKED_LP, MINIMUM_LIQUIDITY);
        } else {
            // 后续注入：以储备比例为准，只拉取“最优”数量，多余部分留在用户手中
            (amount0, amount1) = _optimalAmounts(amount0Desired, amount1Desired, _reserve0, _reserve1);
            uint256 shares0 = (amount0 * _totalSupply) / _reserve0;
            uint256 shares1 = (amount1 * _totalSupply) / _reserve1;
            shares = shares0 < shares1 ? shares0 : shares1; // 取 min，比例失衡无法白嫖价值
            if (shares == 0) revert InsufficientLiquidity();
        }

        if (shares < minShares) revert SlippageExceeded();

        // effects：先更新储备与份额
        reserve0 = _reserve0 + amount0;
        reserve1 = _reserve1 + amount1;
        _mint(to, shares);

        // interactions：再与外部 token 交互
        _safeTransferFrom(token0, msg.sender, address(this), amount0);
        _safeTransferFrom(token1, msg.sender, address(this), amount1);

        emit Mint(msg.sender, to, amount0, amount1, shares);
    }

    /// @notice 移除流动性，按 share 占比赎回两种 token。
    function removeLiquidity(
        uint256 shares,
        uint256 minAmount0,
        uint256 minAmount1,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < shares) revert InsufficientLiquidity();

        uint256 _totalSupply = totalSupply;
        amount0 = (shares * reserve0) / _totalSupply;
        amount1 = (shares * reserve1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidity();
        if (amount0 < minAmount0 || amount1 < minAmount1) revert SlippageExceeded();

        // effects：先销毁份额、更新储备
        _burn(msg.sender, shares);
        reserve0 -= amount0;
        reserve1 -= amount1;

        // interactions：再转出 token
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        emit Burn(msg.sender, to, amount0, amount1, shares);
    }

    /// @notice 恒定乘积兑换（exact input），收取 0.3% 手续费。
    /// @param tokenIn  输入 token（必须是 token0 或 token1）
    /// @param amountIn 输入数量（> 0）
    /// @param minAmountOut 可接受的最少输出（滑点保护，超过即 revert）
    /// @param to       输出接收地址
    function swapExactIn(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        bool zeroForOne;
        if (tokenIn == address(token0)) {
            zeroForOne = true;
        } else if (tokenIn == address(token1)) {
            zeroForOne = false;
        } else {
            revert InvalidToken();
        }

        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        if (_reserve0 == 0 || _reserve1 == 0) revert InsufficientLiquidity();

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (amountOut < minAmountOut) revert SlippageExceeded();

        // effects：先更新储备（手续费部分留在池内，k 只会增大）
        if (zeroForOne) {
            reserve0 = _reserve0 + amountIn;
            reserve1 = _reserve1 - amountOut;
        } else {
            reserve0 = _reserve0 - amountOut;
            reserve1 = _reserve1 + amountIn;
        }

        // interactions：再与外部 token 交互
        _safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn);
        _safeTransfer(zeroForOne ? token1 : token0, to, amountOut);

        emit Swap(
            msg.sender,
            tokenIn,
            amountIn,
            zeroForOne ? address(token1) : address(token0),
            amountOut,
            to
        );
    }

    // ------------------------------------------------------------------
    // 视图
    // ------------------------------------------------------------------

    /// @notice 恒定乘积不变量 k = reserve0 * reserve1
    function k() external view returns (uint256) {
        return reserve0 * reserve1;
    }

    /// @notice 含手续费的输出报价：dy = (dx * 997 * ry) / (rx * 1000 + dx * 997)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        return (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    // ------------------------------------------------------------------
    // ERC20（LP Token）
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
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------

    /// @dev 按当前储备比例计算实际应投入的最优数量（Uniswap Router 风格）
    function _optimalAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 _reserve0,
        uint256 _reserve1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint256 amount1Optimal = (amount0Desired * _reserve1) / _reserve0;
        if (amount1Optimal <= amount1Desired) {
            return (amount0Desired, amount1Optimal);
        }
        uint256 amount0Optimal = (amount1Desired * _reserve0) / _reserve1;
        return (amount0Optimal, amount1Desired);
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

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Babylonian 平方根，向下取整
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
