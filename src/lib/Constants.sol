// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Hard bounds from spec §7.1 and §9.1. These can't be changed, even by the timelock.
library Constants {
    uint256 internal constant BPS = 10_000;

    uint256 internal constant MIN_DURATION = 1 hours;
    uint256 internal constant MAX_DURATION = 90 days;
    uint256 internal constant MIN_PREMIUM = 0.0005 ether;

    uint256 internal constant MAX_FEE_BPS_PREMIUM = 1_000; // 10%
    uint256 internal constant MAX_FEE_BPS_EXERCISE = 100; // 1%
    uint256 internal constant MIN_STAKERS_BPS = 2_000; // stakers always get at least 20% of fees

    uint256 internal constant MAX_OPEN_PER_SELLER = 200;
    uint256 internal constant MAX_BATCH = 50;
    uint256 internal constant MAX_ASSETS = 300; // v2: room for every Robinhood Stock Token (25 in v1)

    uint256 internal constant EPOCH = 1 days;

    /// @dev OptionNFT ids are `(tag << 248) | localId`, so call and put ids never collide. v1 used tags 1 and 2;
    /// v2 used 3 and 4; v3 (readable NFT art) uses 5 and 6, so no version's ids collide with another's (indexer,
    /// keeper and UI key by id and route an id to its market set by this tag).
    uint256 internal constant CALL_TAG = 5;
    uint256 internal constant PUT_TAG = 6;
}
