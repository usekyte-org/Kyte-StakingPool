// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Position} from "../lib/Types.sol";

interface IOptionMarket {
    function getPosition(uint256 id) external view returns (Position memory);
}
