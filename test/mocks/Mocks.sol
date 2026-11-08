// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal WETH9: deposit/withdraw plus ERC20.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns 1% of every transfer, so the receiver gets less than `amount`.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Taxed", "TAX", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// @dev Stands in for StakingPool (C2): records what FeeVault notified.
contract MockRewardSink {
    IERC20 public immutable weth;
    uint256 public notified;
    uint256 public calls;

    constructor(IERC20 weth_) {
        weth = weth_;
    }

    function notifyReward(uint256 amount) external {
        notified += amount;
        ++calls;
    }
}
