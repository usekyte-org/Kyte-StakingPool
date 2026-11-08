// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Status} from "./Types.sol";

/// @dev Every custom error in the protocol (spec §12, plus access and config errors).
library Errors {
    // offers
    error AssetNotEnabled();
    error PutsNotEnabled();
    error AmountZero();
    error StrikeTooLow();
    error PremiumTooLow();
    error BadDuration();
    error BadDeadline();
    error CapExceeded();
    error FeeOnTransfer();
    error TooManyOpen();
    // lifecycle
    error WrongStatus(Status have);
    error OfferExpired();
    error OptionExpired();
    error NotExpired();
    error NotSeller();
    error NotHolder();
    error SelfTrade();
    error PremiumAboveMax();
    error MarketPaused();
    error BatchTooLarge();
    // fees and revenue
    error SplitTooSoon();
    error NothingToSplit();
    error BadSplit();
    error FeeAboveCap();
    error NotConfigured();
    // staking / buyback (C2)
    error BelowMinClaim();
    error InsufficientStake();
    error SlippageTooHigh();
    error StakeLocked();
    error NotKeeper();
    // router
    error InsufficientValue();
    error RefundFailed();
    error RouterHoldsBalance();
    // access and config
    error NotTimelock();
    error NotGuardian();
    error NotRouter();
    error NotMarket();
    error NotDeployer();
    error MarketsAlreadySet();
    error LengthMismatch();
    error ZeroAddress();
    error AssetExists();
    error UnknownAsset();
    error TooManyAssets();
    error UnknownId();
}
