// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Implemented by StakingPool (C2). FeeVault transfers WETH first, then calls this.
interface IRewardSink {
    function notifyReward(uint256 amount) external;
}
