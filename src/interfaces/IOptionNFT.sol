// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IOptionNFT {
    function mint(address to, uint256 id) external;
    function burn(uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
}
