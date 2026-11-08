// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Errors} from "./Errors.sol";
import {Events} from "./Events.sol";

/// @notice Two roles (spec §2): the timelock (10 minute minimum delay, behind the admin Safe) changes settings;
/// the guardian can only pause or disable, never enable or unpause.
abstract contract Governed {
    address public immutable timelock;
    address public guardian;
    bool public paused;

    constructor(address timelock_, address guardian_) {
        if (timelock_ == address(0) || guardian_ == address(0)) revert Errors.ZeroAddress();
        timelock = timelock_;
        guardian = guardian_;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Errors.NotTimelock();
        _;
    }

    modifier onlyGuardianOrTimelock() {
        if (msg.sender != guardian && msg.sender != timelock) revert Errors.NotGuardian();
        _;
    }

    /// @dev Only for actions that open new exposure. Exits never check this.
    modifier whenNotPaused() {
        if (paused) revert Errors.MarketPaused();
        _;
    }

    function setGuardian(address guardian_) external onlyTimelock {
        if (guardian_ == address(0)) revert Errors.ZeroAddress();
        emit Events.AddressChanged("guardian", guardian, guardian_);
        guardian = guardian_;
    }

    function pause() external onlyGuardianOrTimelock {
        paused = true;
        emit Events.Paused(msg.sender);
    }

    function unpause() external onlyTimelock {
        paused = false;
        emit Events.Unpaused(msg.sender);
    }
}
