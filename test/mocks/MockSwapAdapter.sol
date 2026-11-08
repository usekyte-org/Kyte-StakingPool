// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {MockERC20} from "./Mocks.sol";

/// @dev Fixed-rate venue: pulls WETH, mints `rate` tokens per 1e18 WETH to the caller.
contract MockSwapAdapter is ISwapAdapter {
    IERC20 public immutable weth;
    MockERC20 public immutable token;
    uint256 public rate; // tokens (raw) per 1e18 WETH
    uint256 public quoteRate; // when set, quotes use this (an oracle the fill price can't move)

    constructor(IERC20 weth_, MockERC20 token_, uint256 rate_) {
        weth = weth_;
        token = token_;
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setQuoteRate(uint256 quoteRate_) external {
        quoteRate = quoteRate_;
    }

    function quoteWethForToken(uint256 wethIn) external view returns (uint256) {
        return wethIn * (quoteRate == 0 ? rate : quoteRate) / 1e18;
    }

    function swapWethForToken(uint256 wethIn, uint256 minOut, uint256 deadline) external returns (uint256 out) {
        require(block.timestamp <= deadline, "deadline");
        weth.transferFrom(msg.sender, address(this), wethIn);
        out = wethIn * rate / 1e18;
        require(out >= minOut, "slippage");
        token.mint(msg.sender, out);
    }
}
