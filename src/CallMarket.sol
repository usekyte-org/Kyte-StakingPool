// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAssetRegistry} from "./interfaces/IAssetRegistry.sol";
import {IOptionNFT} from "./interfaces/IOptionNFT.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {OptionMarketBase} from "./OptionMarketBase.sol";
import {Position, Status} from "./lib/Types.sol";

/// @notice Covered calls (spec §3). The seller escrows `amount` tokens; the holder can pay `strike`
/// WETH before expiry to receive them.
contract CallMarket is OptionMarketBase {
    using SafeERC20 for IERC20;

    constructor(
        IAssetRegistry registry_,
        IOptionNFT nft_,
        IERC20 weth_,
        address feeVault_,
        address timelock_,
        address guardian_,
        uint32 feeBpsPremium_,
        uint16 feeBpsExercise_
    )
        OptionMarketBase(
            registry_, nft_, weth_, feeVault_, timelock_, guardian_, feeBpsPremium_, feeBpsExercise_, Constants.CALL_TAG
        )
    {}

    function createOffer(
        address token,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint64 offerDeadline
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _open(msg.sender, msg.sender, token, amount, strike, premium, expiry, offerDeadline);
    }

    /// @notice Pay the strike in WETH and receive the tokens. Works while paused; never at or after expiry.
    function exercise(uint256 id) external nonReentrant {
        _exercise(id, msg.sender, msg.sender);
    }

    /// @notice Router pays the strike (wrapped ETH); `holder` must own the NFT and receives the tokens.
    function exerciseFor(uint256 id, address holder) external nonReentrant onlyRouter {
        _exercise(id, holder, msg.sender);
    }

    function _exercise(uint256 id, address holder, address payer) internal {
        Position storage p = _positions[id];
        if (p.status != Status.Filled) revert Errors.WrongStatus(p.status);
        if (block.timestamp >= p.expiry) revert Errors.OptionExpired();
        if (nft.ownerOf(id) != holder) revert Errors.NotHolder();

        uint256 fee = p.strike * p.feeBpsExercise / Constants.BPS;
        p.status = Status.Exercised;
        _unlock(p);
        nft.burn(id);

        if (fee > 0) weth.safeTransferFrom(payer, feeVault, fee);
        weth.safeTransferFrom(payer, p.seller, p.strike - fee);
        IERC20(p.token).safeTransfer(holder, p.amount);
        emit Events.Exercised(id, holder, p.strike, fee);
    }

    function _collateral(address token, uint256 amount, uint256) internal pure override returns (IERC20, uint256) {
        return (IERC20(token), amount);
    }

    function _checkAsset(address token) internal view override {
        if (!registry.isEnabled(token)) revert Errors.AssetNotEnabled();
    }
}
