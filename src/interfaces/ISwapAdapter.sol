// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Swap venue behind BuybackBurner. The mainnet adapter wraps the Robinhood-modified Universal Router
/// (Uniswap v4); tests and the devnet use a fixed-rate mock. The adapter pulls `wethIn` from the caller
/// and must send at least `minOut` of the buyback token back to the caller.
interface ISwapAdapter {
    function swapWethForToken(uint256 wethIn, uint256 minOut, uint256 deadline) external returns (uint256 out);
    /// @notice Expected output for `wethIn`, for the keeper to derive `minOut`. Display/keeper use only.
    function quoteWethForToken(uint256 wethIn) external view returns (uint256 out);
}
