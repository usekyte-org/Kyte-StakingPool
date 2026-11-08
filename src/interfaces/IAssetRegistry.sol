// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAssetRegistry {
    function isEnabled(address token) external view returns (bool);
    function putsEnabled(address token) external view returns (bool);
    function cap(address token) external view returns (uint256);
    function minStrike(address token) external view returns (uint256);
}
