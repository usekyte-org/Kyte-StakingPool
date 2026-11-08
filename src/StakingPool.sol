// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRewardSink} from "./interfaces/IRewardSink.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Governed} from "./lib/Governed.sol";

/// @notice Stake $TOKEN, earn the stakers' share of fees in WETH (spec §8).
/// @dev New stake is pending until the next epoch starts, which blocks staking just before a split.
/// Once active it is locked for that whole epoch, so "stake one second before the epoch ends, collect the
/// split, unstake" doesn't work: every reward is earned by stake that stayed through a full epoch.
/// Accounting: a reward-per-share accumulator over active stake, plus a pending bucket.
/// When a pending batch activates, the accumulator value at that moment is recorded so the batch
/// only earns rewards notified afterwards.
contract StakingPool is IRewardSink, Governed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e36;
    uint256 public constant MAX_MIN_CLAIM = 0.1 ether;

    struct Account {
        uint256 active;
        uint256 pending;
        uint64 pendingEpoch; // epoch the pending stake was added in; active from pendingEpoch + 1
        uint256 rewardDebt; // active * acc / PRECISION at the last sync
        uint256 accrued; // settled, unclaimed WETH
        uint256 recent; // active stake that activated recently and can't be unstaked before `recentUnlockEpoch`
        uint64 recentUnlockEpoch;
    }

    IERC20 public immutable stakeToken;
    IERC20 public immutable weth;
    address public immutable feeVault;

    uint256 public accRewardPerShare;
    uint256 public activeSupply;
    uint256 public pendingSupply;
    uint64 public pendingEpoch;
    uint256 public undistributed; // rewards that arrived while nobody was active
    uint256 public minClaim;
    uint256 public totalClaimed;

    mapping(uint64 epoch => uint256) public activationAcc;
    mapping(address user => Account) internal _accounts;

    constructor(IERC20 stakeToken_, IERC20 weth_, address feeVault_, address timelock_, address guardian_)
        Governed(timelock_, guardian_)
    {
        if (address(stakeToken_) == address(0) || address(weth_) == address(0) || feeVault_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        stakeToken = stakeToken_;
        weth = weth_;
        feeVault = feeVault_;
    }

    // ---------------------------------------------------------------- user actions

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.AmountZero();
        _roll();
        Account storage a = _sync(msg.sender);
        uint64 epoch = currentEpoch();

        a.pending += amount;
        a.pendingEpoch = epoch;
        pendingSupply += amount;
        pendingEpoch = epoch;

        uint256 before = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        if (stakeToken.balanceOf(address(this)) - before != amount) revert Errors.FeeOnTransfer();
        emit Events.Staked(msg.sender, amount, epoch + 1);
    }

    /// @notice Immediate. Takes pending stake first, then active. Earned rewards stay claimable. Works while paused.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.AmountZero();
        _roll();
        Account storage a = _sync(msg.sender);
        if (amount > a.active + a.pending) revert Errors.InsufficientStake();

        uint256 fromPending = Math.min(amount, a.pending);
        uint256 fromActive = amount - fromPending;
        if (fromActive > a.active - _lockedActive(a)) revert Errors.StakeLocked();
        a.pending -= fromPending;
        pendingSupply -= fromPending;
        a.active -= fromActive;
        activeSupply -= fromActive;
        a.rewardDebt = _share(a.active);

        stakeToken.safeTransfer(msg.sender, amount);
        emit Events.Unstaked(msg.sender, amount);
    }

    /// @notice Works while paused.
    function claim() external nonReentrant {
        _roll();
        Account storage a = _sync(msg.sender);
        uint256 amount = a.accrued;
        if (amount == 0 || amount < minClaim) revert Errors.BelowMinClaim();
        a.accrued = 0;
        totalClaimed += amount;
        weth.safeTransfer(msg.sender, amount);
        emit Events.Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- fee vault

    /// @dev FeeVault transfers the WETH first, then calls this.
    function notifyReward(uint256 amount) external {
        if (msg.sender != feeVault) revert Errors.NotMarket();
        _roll();
        amount += undistributed;
        if (activeSupply == 0) {
            undistributed = amount;
            return;
        }
        undistributed = 0;
        accRewardPerShare += Math.mulDiv(amount, PRECISION, activeSupply);
    }

    // ---------------------------------------------------------------- admin

    function setMinClaim(uint256 minClaim_) external onlyTimelock {
        if (minClaim_ > MAX_MIN_CLAIM) revert Errors.FeeAboveCap();
        emit Events.ParamChanged("minClaim", minClaim, minClaim_);
        minClaim = minClaim_;
    }

    // ---------------------------------------------------------------- views

    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp / Constants.EPOCH);
    }

    function epochEndsAt() external view returns (uint256) {
        return (uint256(currentEpoch()) + 1) * Constants.EPOCH;
    }

    /// @notice Active + pending stake, as of now (used for voting weight).
    function stakeOf(address user) external view returns (uint256) {
        Account storage a = _accounts[user];
        return a.active + a.pending;
    }

    /// @notice Stake earning rewards right now, and stake waiting for the next epoch.
    function balancesOf(address user) external view returns (uint256 active, uint256 pending) {
        Account storage a = _accounts[user];
        if (a.pending > 0 && currentEpoch() > a.pendingEpoch) return (a.active + a.pending, 0);
        return (a.active, a.pending);
    }

    /// @notice Active stake that can't be unstaked yet, and the epoch it unlocks in. Pending stake is never locked.
    function lockedOf(address user) external view returns (uint256 amount, uint64 unlockEpoch) {
        Account storage a = _accounts[user];
        uint64 epoch = currentEpoch();
        amount = _lockedActive(a);
        unlockEpoch = amount > 0 ? a.recentUnlockEpoch : 0;
        if (a.pending > 0 && epoch > a.pendingEpoch && epoch < a.pendingEpoch + 2) {
            amount += a.pending; // activates on the next touch, locked until pendingEpoch + 2
            unlockEpoch = a.pendingEpoch + 2;
        }
    }

    function pendingRewards(address user) external view returns (uint256) {
        Account storage a = _accounts[user];
        uint256 acc = accRewardPerShare;
        uint256 owed = a.accrued + _share(a.active, acc) - a.rewardDebt;
        if (a.pending > 0 && currentEpoch() > a.pendingEpoch) {
            // Not rolled yet means no reward arrived since activation, so it earned nothing so far.
            bool rolled = !(pendingSupply > 0 && pendingEpoch == a.pendingEpoch);
            if (rolled) owed += _share(a.pending, acc - activationAcc[a.pendingEpoch]);
        }
        return owed;
    }

    // ---------------------------------------------------------------- internal

    /// @dev Activates the global pending batch once its epoch has ended.
    function _roll() internal {
        if (pendingSupply > 0 && currentEpoch() > pendingEpoch) {
            activationAcc[pendingEpoch] = accRewardPerShare;
            activeSupply += pendingSupply;
            pendingSupply = 0;
        }
    }

    /// @dev Settles a user's rewards up to now and activates their pending stake if its epoch passed.
    /// Must run after `_roll`.
    function _sync(address user) internal returns (Account storage a) {
        a = _accounts[user];
        uint256 acc = accRewardPerShare;
        a.accrued += _share(a.active, acc) - a.rewardDebt;
        if (a.pending > 0 && currentEpoch() > a.pendingEpoch) {
            a.accrued += _share(a.pending, acc - activationAcc[a.pendingEpoch]);
            a.active += a.pending;
            // Locked through the epoch it activated in (pendingEpoch + 1); free from pendingEpoch + 2.
            uint64 unlock = a.pendingEpoch + 2;
            if (currentEpoch() < unlock) {
                if (currentEpoch() >= a.recentUnlockEpoch) a.recent = 0;
                a.recent += a.pending;
                a.recentUnlockEpoch = unlock;
            }
            a.pending = 0;
        }
        a.rewardDebt = _share(a.active, acc);
    }

    function _lockedActive(Account storage a) internal view returns (uint256) {
        return currentEpoch() < a.recentUnlockEpoch ? a.recent : 0;
    }

    function _share(uint256 amount) internal view returns (uint256) {
        return _share(amount, accRewardPerShare);
    }

    function _share(uint256 amount, uint256 acc) internal pure returns (uint256) {
        return Math.mulDiv(amount, acc, PRECISION);
    }
}
