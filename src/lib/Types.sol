// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Status only moves forward: None → Open → {Cancelled | Filled → {Exercised | Expired}}.
enum Status {
    None,
    Open,
    Filled,
    Exercised,
    Expired,
    Cancelled
}

/// @notice One option position. Calls and puts share the layout (spec §3.1, §4).
/// @dev `strike` and `premium` are totals for the whole lot, in WETH, so decimals never cause per-unit rounding.
struct Position {
    // slot 0
    address seller;
    uint64 expiry;
    uint32 feeBpsPremium; // snapshotted at creation
    // slot 1
    address token; // the underlying ERC-20
    uint64 offerDeadline; // last moment the offer can be filled, <= expiry
    uint16 feeBpsExercise; // snapshotted at creation
    Status status;
    // slots 2..4
    uint256 amount; // underlying tokens covered by the option
    uint256 strike; // total WETH exchanged on exercise
    uint256 premium; // total WETH the buyer pays to fill
}
