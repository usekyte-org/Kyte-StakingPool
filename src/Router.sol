// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CallMarket} from "./CallMarket.sol";
import {PutMarket} from "./PutMarket.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {Errors} from "./lib/Errors.sol";

/// @notice Stateless periphery (spec §3.5): users pay in ETH, the Router wraps exactly what's needed,
/// calls the market on their behalf and refunds the rest. It never holds a balance after a call.
/// @dev The markets only accept these calls from the router set by the timelock, and `exerciseFor` still
/// checks that `holder` owns the NFT, so the Router can't act on anyone else's position.
contract Router is ReentrancyGuardTransient {
    IWETH public immutable weth;
    CallMarket public immutable calls;
    PutMarket public immutable puts;

    constructor(IWETH weth_, CallMarket calls_, PutMarket puts_) {
        if (address(weth_) == address(0) || address(calls_) == address(0) || address(puts_) == address(0)) {
            revert Errors.ZeroAddress();
        }
        weth = weth_;
        calls = calls_;
        puts = puts_;
        weth.approve(address(calls_), type(uint256).max);
        weth.approve(address(puts_), type(uint256).max);
    }

    function buyWithETH(uint256 id, uint256 maxPremium) external payable nonReentrant {
        uint256 need = calls.getPosition(id).premium;
        _wrap(need);
        calls.buyFor(id, maxPremium, msg.sender);
        _finish(need);
    }

    function exerciseWithETH(uint256 id) external payable nonReentrant {
        uint256 need = calls.getPosition(id).strike;
        _wrap(need);
        calls.exerciseFor(id, msg.sender);
        _finish(need);
    }

    function buyPutWithETH(uint256 id, uint256 maxPremium) external payable nonReentrant {
        uint256 need = puts.getPosition(id).premium;
        _wrap(need);
        puts.buyFor(id, maxPremium, msg.sender);
        _finish(need);
    }

    function createPutOfferWithETH(
        address token,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint64 offerDeadline
    ) external payable nonReentrant returns (uint256 id) {
        _wrap(strike);
        id = puts.createPutOfferFor(msg.sender, token, amount, strike, premium, expiry, offerDeadline);
        _finish(strike);
    }

    function _wrap(uint256 need) internal {
        if (msg.value < need) revert Errors.InsufficientValue();
        weth.deposit{value: need}();
    }

    /// @dev Refund excess ETH to the caller (the only native-ETH push, back to who sent it), then prove the
    /// Router is empty.
    function _finish(uint256 need) internal {
        uint256 refund = msg.value - need;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert Errors.RefundFailed();
        }
        if (weth.balanceOf(address(this)) != 0 || address(this).balance != 0) revert Errors.RouterHoldsBalance();
    }
}
