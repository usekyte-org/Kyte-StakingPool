// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Governed} from "./lib/Governed.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @notice Receives the buyback share of fees and turns it into burned $TOKEN, on-chain (spec §7.3).
/// The WETH here can go nowhere except into a swap whose output is burned. `Burned` events are the proof page.
/// @dev Slippage is bounded on-chain against the adapter quote (KyteHook TWAP) and the last executed price.
/// Per-call size is capped so the keeper spreads buybacks over the epoch.
contract BuybackBurner is Governed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_SLIPPAGE_CAP = 2_000; // 20%

    IERC20 public immutable weth;
    IERC20 public immutable token;

    address public keeper;
    ISwapAdapter public adapter;
    uint256 public maxPerCall;
    uint256 public maxSlippageBps = 500;
    /// @notice Tokens received per 1e18 WETH in the last swap. Zero until the first swap.
    uint256 public lastPrice;

    uint256 public totalWethIn;
    uint256 public totalBurned;

    constructor(IERC20 weth_, IERC20 token_, address keeper_, address timelock_, address guardian_)
        Governed(timelock_, guardian_)
    {
        if (address(weth_) == address(0) || address(token_) == address(0)) revert Errors.ZeroAddress();
        weth = weth_;
        token = token_;
        keeper = keeper_;
        maxPerCall = 1 ether;
    }

    // ---------------------------------------------------------------- admin

    function setKeeper(address keeper_) external onlyTimelock {
        emit Events.AddressChanged("keeper", keeper, keeper_);
        keeper = keeper_;
    }

    function setAdapter(ISwapAdapter adapter_) external onlyTimelock {
        emit Events.AddressChanged("adapter", address(adapter), address(adapter_));
        adapter = adapter_;
    }

    function setBounds(uint256 maxPerCall_, uint256 maxSlippageBps_) external onlyTimelock {
        if (maxSlippageBps_ > MAX_SLIPPAGE_CAP) revert Errors.FeeAboveCap();
        emit Events.ParamChanged("maxPerCall", maxPerCall, maxPerCall_);
        emit Events.ParamChanged("maxSlippageBps", maxSlippageBps, maxSlippageBps_);
        maxPerCall = maxPerCall_;
        maxSlippageBps = maxSlippageBps_;
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Swap `wethIn` for $TOKEN through the adapter and burn everything received. Blocked while paused.
    function buyAndBurn(uint256 wethIn, uint256 minTokenOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 burned)
    {
        if (msg.sender != keeper) revert Errors.NotKeeper();
        ISwapAdapter a = adapter;
        if (address(a) == address(0)) revert Errors.NotConfigured();
        if (wethIn == 0) revert Errors.AmountZero();
        if (wethIn > maxPerCall || wethIn > weth.balanceOf(address(this))) revert Errors.CapExceeded();
        if (minTokenOut == 0) revert Errors.SlippageTooHigh();
        // Two on-chain floors, so even a stolen keeper key can't hand the WETH to a sandwich:
        // 1. the adapter's quote (the KyteHook 10 minute TWAP on mainnet), checked in this transaction;
        // 2. the last executed price, so the floor can't be walked down faster than the TWAP moves.
        uint256 quoteFloor = a.quoteWethForToken(wethIn) * (Constants.BPS - maxSlippageBps) / Constants.BPS;
        if (minTokenOut < quoteFloor) revert Errors.SlippageTooHigh();
        if (lastPrice != 0) {
            uint256 floor = wethIn * lastPrice / 1e18 * (Constants.BPS - maxSlippageBps) / Constants.BPS;
            if (minTokenOut < floor) revert Errors.SlippageTooHigh();
        }

        uint256 before = token.balanceOf(address(this));
        weth.forceApprove(address(a), wethIn);
        a.swapWethForToken(wethIn, minTokenOut, deadline);
        weth.forceApprove(address(a), 0);
        burned = token.balanceOf(address(this)) - before;
        if (burned < minTokenOut) revert Errors.SlippageTooHigh();

        lastPrice = burned * 1e18 / wethIn;
        totalWethIn += wethIn;
        totalBurned += burned;
        _burn(burned);
        emit Events.Burned(wethIn, burned);
    }

    function _burn(uint256 amount) internal {
        try IBurnable(address(token)).burn(amount) {}
        catch {
            token.safeTransfer(DEAD, amount);
        }
    }
}
