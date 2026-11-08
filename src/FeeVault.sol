// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRewardSink} from "./interfaces/IRewardSink.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Governed} from "./lib/Governed.sol";

/// @notice Collects WETH fees from both markets and splits them once per epoch (spec §7.2):
/// stakers / buy-and-burn / ops. Anyone can call `split`. No fee passes through a team wallet first.
contract FeeVault is Governed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public immutable weth;

    address public stakingPool;
    address public buybackBurner;
    address public opsSafe;

    uint16 public stakersBps = 3_000;
    uint16 public buybackBps = 2_000;
    uint16 public opsBps = 5_000;

    uint64 public lastSplitEpoch;
    uint256 public totalSplit;

    constructor(IERC20 weth_, address timelock_, address guardian_) Governed(timelock_, guardian_) {
        if (address(weth_) == address(0)) revert Errors.ZeroAddress();
        weth = weth_;
    }

    function setDestinations(address stakingPool_, address buybackBurner_, address opsSafe_) external onlyTimelock {
        if (stakingPool_ == address(0) || buybackBurner_ == address(0) || opsSafe_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        emit Events.AddressChanged("stakingPool", stakingPool, stakingPool_);
        emit Events.AddressChanged("buybackBurner", buybackBurner, buybackBurner_);
        emit Events.AddressChanged("opsSafe", opsSafe, opsSafe_);
        stakingPool = stakingPool_;
        buybackBurner = buybackBurner_;
        opsSafe = opsSafe_;
    }

    /// @dev Shares must sum to 100%, and stakers always get at least MIN_STAKERS_BPS.
    function setSplit(uint16 stakers, uint16 buyback, uint16 ops) external onlyTimelock {
        if (uint256(stakers) + buyback + ops != Constants.BPS || stakers < Constants.MIN_STAKERS_BPS) {
            revert Errors.BadSplit();
        }
        emit Events.ParamChanged("stakersBps", stakersBps, stakers);
        emit Events.ParamChanged("buybackBps", buybackBps, buyback);
        emit Events.ParamChanged("opsBps", opsBps, ops);
        stakersBps = stakers;
        buybackBps = buyback;
        opsBps = ops;
    }

    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp / Constants.EPOCH);
    }

    /// @notice Split the whole WETH balance. At most once per epoch; works while paused.
    /// @dev Rounding dust stays in the vault for the next split.
    function split() external nonReentrant {
        uint64 epoch = currentEpoch();
        if (epoch <= lastSplitEpoch) revert Errors.SplitTooSoon();
        address pool = stakingPool;
        if (pool == address(0)) revert Errors.NotConfigured();
        uint256 balance = weth.balanceOf(address(this));
        if (balance == 0) revert Errors.NothingToSplit();

        uint256 toStakers = balance * stakersBps / Constants.BPS;
        uint256 toBuyback = balance * buybackBps / Constants.BPS;
        uint256 toOps = balance * opsBps / Constants.BPS;
        lastSplitEpoch = epoch;
        totalSplit += toStakers + toBuyback + toOps;

        weth.safeTransfer(pool, toStakers);
        IRewardSink(pool).notifyReward(toStakers);
        weth.safeTransfer(buybackBurner, toBuyback);
        weth.safeTransfer(opsSafe, toOps);
        emit Events.FeesSplit(epoch, toStakers, toBuyback, toOps);
    }
}
