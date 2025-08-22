// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Project is ERC20, ReentrancyGuard, Ownable {
    struct Pool {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalLiquidity;
        bool exists;
    }
    
    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => mapping(address => uint256)) public liquidityBalances;
    
    uint256 public constant FEE_RATE = 3; // 0.3% fee
    uint256 public constant FEE_DENOMINATOR = 1000;
    
    event PoolCreated(address indexed tokenA, address indexed tokenB, bytes32 indexed poolId);
    event LiquidityAdded(bytes32 indexed poolId, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event LiquidityRemoved(bytes32 indexed poolId, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event TokensSwapped(bytes32 indexed poolId, address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut);
    
    constructor() ERC20("DEX LP Token", "DLP") Ownable(msg.sender) {}
    
    function getPoolId(address tokenA, address tokenB) public pure returns (bytes32) {
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }
    
    // Core Function 1: Create and manage liquidity pools
    function createPool(address tokenA, address tokenB) external returns (bytes32 poolId) {
        require(tokenA != tokenB, "Identical tokens");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        
        poolId = getPoolId(tokenA, tokenB);
        require(!pools[poolId].exists, "Pool already exists");
        
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        
        pools[poolId] = Pool({
            tokenA: tokenA,
            tokenB: tokenB,
            reserveA: 0,
            reserveB: 0,
            totalLiquidity: 0,
            exists: true
        });
        
        emit PoolCreated(tokenA, tokenB, poolId);
    }
    
    // Core Function 2: Add/Remove liquidity with LP token rewards
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) external nonReentrant returns (uint256 liquidity) {
        bytes32 poolId = getPoolId(tokenA, tokenB);
        require(pools[poolId].exists, "Pool does not exist");
        
        Pool storage pool = pools[poolId];
        
        // Transfer tokens from user
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountB);
        
        if (pool.totalLiquidity == 0) {
            // First liquidity provider
            liquidity = sqrt(amountA * amountB);
        } else {
            // Calculate liquidity based on existing reserves
            uint256 liquidityA = (amountA * pool.totalLiquidity) / pool.reserveA;
            uint256 liquidityB = (amountB * pool.totalLiquidity) / pool.reserveB;
            liquidity = liquidityA < liquidityB ? liquidityA : liquidityB;
        }
        
        require(liquidity > 0, "Insufficient liquidity");
        
        pool.reserveA += amountA;
        pool.reserveB += amountB;
        pool.totalLiquidity += liquidity;
        liquidityBalances[poolId][msg.sender] += liquidity;
        
        _mint(msg.sender, liquidity);
        
        emit LiquidityAdded(poolId, msg.sender, amountA, amountB, liquidity);
    }
    
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        bytes32 poolId = getPoolId(tokenA, tokenB);
        require(pools[poolId].exists, "Pool does not exist");
        require(liquidityBalances[poolId][msg.sender] >= liquidity, "Insufficient liquidity balance");
        
        Pool storage pool = pools[poolId];
        
        amountA = (liquidity * pool.reserveA) / pool.totalLiquidity;
        amountB = (liquidity * pool.reserveB) / pool.totalLiquidity;
        
        require(amountA > 0 && amountB > 0, "Insufficient liquidity burned");
        
        liquidityBalances[poolId][msg.sender] -= liquidity;
        pool.reserveA -= amountA;
        pool.reserveB -= amountB;
        pool.totalLiquidity -= liquidity;
        
        _burn(msg.sender, liquidity);
        
        IERC20(tokenA).transfer(msg.sender, amountA);
        IERC20(tokenB).transfer(msg.sender, amountB);
        
        emit LiquidityRemoved(poolId, msg.sender, amountA, amountB, liquidity);
    }
    
    // Core Function 3: Token swapping with automated market making
    function swapTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(tokenIn != tokenOut, "Identical tokens");
        require(amountIn > 0, "Amount must be greater than 0");
        
        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        require(pools[poolId].exists, "Pool does not exist");
        
        Pool storage pool = pools[poolId];
        
        bool isTokenAIn = tokenIn == pool.tokenA;
        uint256 reserveIn = isTokenAIn ? pool.reserveA : pool.reserveB;
        uint256 reserveOut = isTokenAIn ? pool.reserveB : pool.reserveA;
        
        // Calculate output amount using constant product formula with fees
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_RATE);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
        require(amountOut < reserveOut, "Insufficient liquidity");
        
        // Transfer tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        
        // Update reserves
        if (isTokenAIn) {
            pool.reserveA += amountIn;
            pool.reserveB -= amountOut;
        } else {
            pool.reserveB += amountIn;
            pool.reserveA -= amountOut;
        }
        
        emit TokensSwapped(poolId, msg.sender, tokenIn, amountIn, amountOut);
    }
    
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) 
        external view returns (uint256 amountOut) {
        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        require(pools[poolId].exists, "Pool does not exist");
        
        Pool memory pool = pools[poolId];
        bool isTokenAIn = tokenIn == pool.tokenA;
        uint256 reserveIn = isTokenAIn ? pool.reserveA : pool.reserveB;
        uint256 reserveOut = isTokenAIn ? pool.reserveB : pool.reserveA;
        
        if (reserveIn == 0 || reserveOut == 0) return 0;
        
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_RATE);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }
    
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return pools[poolId];
    }
    
    function getUserLiquidity(bytes32 poolId, address user) external view returns (uint256) {
        return liquidityBalances[poolId][user];
    }
}








