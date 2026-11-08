// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {Errors} from "../src/lib/Errors.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";

contract BuybackBurnerTest is Test {
    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockWETH internal weth;
    MockERC20 internal draft;
    MockSwapAdapter internal adapter;
    BuybackBurner internal burner;

    function setUp() public {
        weth = new MockWETH();
        draft = new MockERC20("Draft", "DRAFT", 18);
        adapter = new MockSwapAdapter(IERC20(address(weth)), draft, 1_000_000e18); // 1M DRAFT per ETH
        burner = new BuybackBurner(IERC20(address(weth)), IERC20(address(draft)), keeper, timelock, guardian);
        vm.prank(timelock);
        burner.setAdapter(ISwapAdapter(address(adapter)));
        weth.mint(address(burner), 5 ether);
    }

    function test_buyAndBurn() public {
        vm.prank(keeper);
        uint256 burned = burner.buyAndBurn(1 ether, 950_000e18, block.timestamp + 60);
        assertEq(burned, 1_000_000e18);
        assertEq(draft.balanceOf(DEAD), 1_000_000e18);
        assertEq(draft.balanceOf(address(burner)), 0);
        assertEq(weth.balanceOf(address(burner)), 4 ether);
        assertEq(burner.lastPrice(), 1_000_000e18);
        assertEq(burner.totalBurned(), 1_000_000e18);
    }

    function test_reverts() public {
        vm.prank(address(0xbad));
        vm.expectRevert(Errors.NotKeeper.selector);
        burner.buyAndBurn(1 ether, 1, block.timestamp);

        vm.startPrank(keeper);
        vm.expectRevert(Errors.CapExceeded.selector);
        burner.buyAndBurn(1 ether + 1, 1, block.timestamp); // > maxPerCall
        vm.expectRevert(Errors.AmountZero.selector);
        burner.buyAndBurn(0, 1, block.timestamp);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        burner.buyAndBurn(1 ether, 0, block.timestamp);
        vm.stopPrank();

        vm.prank(timelock);
        burner.setBounds(10 ether, 500);
        vm.prank(keeper);
        vm.expectRevert(Errors.CapExceeded.selector);
        burner.buyAndBurn(6 ether, 1, block.timestamp); // > balance
    }

    function test_slippageBoundAgainstLastPrice() public {
        vm.prank(keeper);
        burner.buyAndBurn(1 ether, 950_000e18, block.timestamp);
        // 5% bound: minOut must be >= 950k
        vm.prank(keeper);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        burner.buyAndBurn(1 ether, 949_999e18, block.timestamp);

        adapter.setRate(900_000e18); // venue got worse than the bound allows
        vm.prank(keeper);
        vm.expectRevert("slippage");
        burner.buyAndBurn(1 ether, 950_000e18, block.timestamp);
    }

    /// A stolen keeper key can't sell the WETH cheap, not even on the very first buyback (no lastPrice yet).
    function test_quoteFloor_firstBuybackAndStolenKey() public {
        assertEq(burner.lastPrice(), 0);
        vm.prank(keeper);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        burner.buyAndBurn(1 ether, 1, block.timestamp); // minOut far below quote - 5%
        vm.prank(keeper);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        burner.buyAndBurn(1 ether, 949_999e18, block.timestamp);
        vm.prank(keeper);
        burner.buyAndBurn(1 ether, 950_000e18, block.timestamp);
    }

    /// The last-price floor can't be walked down call after call: the oracle quote (TWAP) is a fixed floor.
    function test_quoteFloor_blocksRatchet() public {
        adapter.setQuoteRate(1_000_000e18); // TWAP says 1M/ETH
        adapter.setRate(950_000e18); // a sandwich makes the fill 5% worse
        vm.prank(keeper);
        burner.buyAndBurn(0.5 ether, 475_000e18, block.timestamp); // allowed: exactly at the 5% bound
        assertEq(burner.lastPrice(), 950_000e18);
        // next call: lastPrice alone would now allow 5% below 950k, the quote floor doesn't
        adapter.setRate(902_500e18);
        vm.prank(keeper);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        burner.buyAndBurn(0.5 ether, 451_250e18, block.timestamp);
    }

    function test_pauseBlocks() public {
        vm.prank(guardian);
        burner.pause();
        vm.prank(keeper);
        vm.expectRevert(Errors.MarketPaused.selector);
        burner.buyAndBurn(1 ether, 1, block.timestamp);
    }

    function test_noAdapter() public {
        BuybackBurner fresh =
            new BuybackBurner(IERC20(address(weth)), IERC20(address(draft)), keeper, timelock, guardian);
        weth.mint(address(fresh), 1 ether);
        vm.prank(keeper);
        vm.expectRevert(Errors.NotConfigured.selector);
        fresh.buyAndBurn(1 ether, 1, block.timestamp);
    }
}
