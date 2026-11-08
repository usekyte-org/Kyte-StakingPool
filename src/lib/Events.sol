// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Every event the indexer reads (spec §12). Ids are OptionNFT token ids.
library Events {
    // markets (calls and puts share these; the id's tag says which market)
    event OfferCreated(
        uint256 indexed id,
        address indexed seller,
        address indexed token,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint64 offerDeadline
    );
    event OfferCancelled(uint256 indexed id);
    event OptionBought(uint256 indexed id, address indexed buyer, uint256 premium, uint256 fee);
    event Exercised(uint256 indexed id, address indexed holder, uint256 strike, uint256 fee);
    event Expired(uint256 indexed id, address indexed caller);

    // revenue
    event FeesSplit(uint64 indexed epoch, uint256 stakers, uint256 buyback, uint256 ops);
    event Burned(uint256 wethIn, uint256 tokenOut);

    // staking
    event Staked(address indexed user, uint256 amount, uint64 activeFromEpoch);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    // governance
    event ParamChanged(bytes32 indexed key, uint256 oldValue, uint256 newValue);
    event AddressChanged(bytes32 indexed key, address oldValue, address newValue);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // registry
    event AssetAdded(address indexed token, uint256 cap, uint256 minStrike);
    event AssetEnabled(address indexed token, bool enabled);
    event PutsEnabled(address indexed token, bool enabled);
}
