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

/// @notice Cash-secured puts (spec §4). The seller escrows `strike` WETH; the holder can deliver exactly
/// `amount` tokens before expiry and receive the strike minus the exercise fee.
/// @dev A separate contract from CallMarket, so each keeps its own escrow.
contract PutMarket is OptionMarketBase {
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
            registry_, nft_, weth_, feeVault_, timelock_, guardian_, feeBpsPremium_, feeBpsExercise_, Constants.PUT_TAG
        )
    {}

    function createPutOffer(
        address token,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint64 offerDeadline
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _open(msg.sender, msg.sender, token, amount, strike, premium, expiry, offerDeadline);
    }

    /// @notice Router escrows the strike (wrapped from the seller's ETH) on the seller's behalf.
    function createPutOfferFor(
        address seller,
        address token,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint64 offerDeadline
    ) external nonReentrant whenNotPaused onlyRouter returns (uint256) {
        return _open(seller, msg.sender, token, amount, strike, premium, expiry, offerDeadline);
    }

    /// @notice Deliver `amount` tokens (approve this market first) and receive the strike in WETH, minus the fee.
    function exercisePut(uint256 id) external nonReentrant {
        Position storage p = _positions[id];
        if (p.status != Status.Filled) revert Errors.WrongStatus(p.status);
        if (block.timestamp >= p.expiry) revert Errors.OptionExpired();
        if (nft.ownerOf(id) != msg.sender) revert Errors.NotHolder();

        uint256 fee = p.strike * p.feeBpsExercise / Constants.BPS;
        p.status = Status.Exercised;
        _unlock(p);
        nft.burn(id);

        // Pull through the market so the exact-amount check holds even if holder == seller.
        IERC20 token = IERC20(p.token);
        _pullExact(token, msg.sender, p.amount);
        token.safeTransfer(p.seller, p.amount);

        if (fee > 0) weth.safeTransfer(feeVault, fee);
        weth.safeTransfer(msg.sender, p.strike - fee);
        emit Events.Exercised(id, msg.sender, p.strike, fee);
    }

    function _collateral(address, uint256, uint256 strike) internal view override returns (IERC20, uint256) {
        return (weth, strike);
    }

    function _checkAsset(address token) internal view override {
        if (!registry.putsEnabled(token)) revert Errors.PutsNotEnabled();
    }
}
