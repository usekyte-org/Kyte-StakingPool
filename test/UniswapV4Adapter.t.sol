// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {KyteHook} from "../src/hooks/KyteHook.sol";

/// @dev Real v4 PoolManager + pool with liquidity (v4-core's Deployers), both swap directions.
contract UniswapV4AdapterTest is Test, Deployers {
    address internal c0;
    address internal c1;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        c0 = Currency.unwrap(currency0);
        c1 = Currency.unwrap(currency1);
    }

    function _adapter(address wethAddr, address tokenAddr) internal returns (UniswapV4Adapter a) {
        a = new UniswapV4Adapter(manager, IERC20(wethAddr), IERC20(tokenAddr), key, KyteHook(address(0)));
        MockERC20(wethAddr).mint(address(this), 10 ether);
        IERC20(wethAddr).approve(address(a), type(uint256).max);
    }

    function test_swap_wethIsCurrency0() public {
        UniswapV4Adapter a = _adapter(c0, c1);
        assertTrue(a.zeroForOne());
        uint256 amountIn = 1e15;
        uint256 quote = a.quoteWethForToken(amountIn);
        uint256 w0 = IERC20(c0).balanceOf(address(this));
        uint256 t0 = IERC20(c1).balanceOf(address(this));

        uint256 out = a.swapWethForToken(amountIn, quote * 95 / 100, block.timestamp);

        assertGt(out, 0);
        assertLe(out, quote); // price impact only makes it worse than the spot quote
        assertEq(IERC20(c1).balanceOf(address(this)) - t0, out);
        assertEq(w0 - IERC20(c0).balanceOf(address(this)), amountIn); // fully filled, nothing stranded
        assertEq(IERC20(c0).balanceOf(address(a)), 0);
        assertEq(IERC20(c1).balanceOf(address(a)), 0);
    }

    function test_swap_wethIsCurrency1() public {
        UniswapV4Adapter a = _adapter(c1, c0);
        assertFalse(a.zeroForOne());
        uint256 quote = a.quoteWethForToken(1e15);
        uint256 out = a.swapWethForToken(1e15, quote * 95 / 100, block.timestamp);
        assertGt(out, 0);
        assertLe(out, quote);
        assertEq(IERC20(c1).balanceOf(address(a)), 0);
    }

    /// Swap larger than the in-range liquidity: partial fill, unused WETH comes back.
    function test_partialFill_refundsUnused() public {
        UniswapV4Adapter a = _adapter(c0, c1);
        uint256 amountIn = 1 ether;
        uint256 w0 = IERC20(c0).balanceOf(address(this));
        uint256 out = a.swapWethForToken(amountIn, 1, block.timestamp);
        assertGt(out, 0);
        assertLt(w0 - IERC20(c0).balanceOf(address(this)), amountIn);
        assertEq(IERC20(c0).balanceOf(address(a)), 0);
    }

    function test_reverts() public {
        UniswapV4Adapter a = _adapter(c0, c1);
        uint256 quote = a.quoteWethForToken(1e15);
        vm.expectRevert();
        a.swapWethForToken(1e15, quote * 2, block.timestamp); // minOut above what the pool gives
        vm.expectRevert(UniswapV4Adapter.DeadlinePassed.selector);
        a.swapWethForToken(1e15, 1, block.timestamp - 1);
        vm.expectRevert(UniswapV4Adapter.BadPool.selector);
        new UniswapV4Adapter(manager, IERC20(c0), IERC20(address(0xbeef)), key, KyteHook(address(0)));
        // a hook that isn't the pool's hook is a misconfiguration
        vm.expectRevert(UniswapV4Adapter.BadPool.selector);
        new UniswapV4Adapter(manager, IERC20(c0), IERC20(c1), key, KyteHook(address(0xbeef)));
        vm.expectRevert(UniswapV4Adapter.OnlyPoolManager.selector);
        a.unlockCallback("");
    }
}
