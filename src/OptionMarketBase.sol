// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAssetRegistry} from "./interfaces/IAssetRegistry.sol";
import {IOptionMarket} from "./interfaces/IOptionMarket.sol";
import {IOptionNFT} from "./interfaces/IOptionNFT.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Governed} from "./lib/Governed.sol";
import {Position, Status} from "./lib/Types.sol";

/// @notice Shared escrow, lifecycle and fee logic for CallMarket and PutMarket (spec §3, §4).
/// @dev Rules every function follows: checks → effects (terminal status first) → token transfers, all
/// `nonReentrant`. Pause blocks only `_open` and buys. Cancel, exercise and expire always work.
/// There is no function that moves collateral anywhere except to its seller or the option holder.
abstract contract OptionMarketBase is IOptionMarket, Governed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IAssetRegistry public immutable registry;
    IOptionNFT public immutable nft;
    IERC20 public immutable weth;
    address public immutable feeVault;
    uint256 internal immutable _tag;

    uint32 public feeBpsPremium;
    uint16 public feeBpsExercise;
    /// @notice Stateless periphery allowed to call the `*For` functions. Zero disables them.
    address public router;

    uint256 public lastLocalId;
    mapping(uint256 id => Position) internal _positions;
    /// @notice Collateral held per token, for Open + Filled positions. Invariant: balance >= locked.
    mapping(address token => uint256) public locked;
    /// @notice Underlying amount in Open + Filled positions, checked against the registry cap.
    mapping(address token => uint256) public exposure;
    mapping(address seller => uint256) public openOffers;

    constructor(
        IAssetRegistry registry_,
        IOptionNFT nft_,
        IERC20 weth_,
        address feeVault_,
        address timelock_,
        address guardian_,
        uint32 feeBpsPremium_,
        uint16 feeBpsExercise_,
        uint256 tag_
    ) Governed(timelock_, guardian_) {
        if (
            address(registry_) == address(0) || address(nft_) == address(0) || address(weth_) == address(0)
                || feeVault_ == address(0)
        ) revert Errors.ZeroAddress();
        registry = registry_;
        nft = nft_;
        weth = weth_;
        feeVault = feeVault_;
        _tag = tag_;
        _setFees(feeBpsPremium_, feeBpsExercise_);
    }

    modifier onlyRouter() {
        if (msg.sender != router || router == address(0)) revert Errors.NotRouter();
        _;
    }

    // ---------------------------------------------------------------- admin (timelock)

    /// @dev Applies to positions created afterwards only; open positions keep their snapshot.
    function setFees(uint32 premiumBps, uint16 exerciseBps) external onlyTimelock {
        _setFees(premiumBps, exerciseBps);
    }

    function setRouter(address router_) external onlyTimelock {
        emit Events.AddressChanged("router", router, router_);
        router = router_;
    }

    // ---------------------------------------------------------------- shared lifecycle

    function buy(uint256 id, uint256 maxPremium) external nonReentrant whenNotPaused {
        _buy(id, maxPremium, msg.sender, msg.sender);
    }

    /// @notice Router pays the premium (wrapped from the user's ETH), the NFT goes to `beneficiary`.
    function buyFor(uint256 id, uint256 maxPremium, address beneficiary)
        external
        nonReentrant
        whenNotPaused
        onlyRouter
    {
        _buy(id, maxPremium, msg.sender, beneficiary);
    }

    /// @notice Seller takes back an unfilled offer. Allowed while paused and after the fill deadline.
    function cancelUnfilled(uint256 id) external nonReentrant {
        Position storage p = _positions[id];
        if (p.status != Status.Open) revert Errors.WrongStatus(p.status);
        if (msg.sender != p.seller) revert Errors.NotSeller();
        p.status = Status.Cancelled;
        --openOffers[p.seller];
        emit Events.OfferCancelled(id);
        _returnCollateral(p);
    }

    /// @notice Anyone can expire a filled option once `now >= expiry`; collateral goes back to the seller.
    function expire(uint256 id) external nonReentrant {
        _expire(id, true);
    }

    /// @notice Keeper convenience: skips ids that can't be expired instead of reverting.
    function expireMany(uint256[] calldata ids) external nonReentrant returns (uint256 expired) {
        if (ids.length > Constants.MAX_BATCH) revert Errors.BatchTooLarge();
        for (uint256 i; i < ids.length; ++i) {
            if (_expire(ids[i], false)) ++expired;
        }
    }

    // ---------------------------------------------------------------- views

    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function idOf(uint256 localId) public view returns (uint256) {
        return (_tag << 248) | localId;
    }

    // ---------------------------------------------------------------- hooks

    /// @dev Which token is escrowed for a position, and how much.
    function _collateral(address token, uint256 amount, uint256 strike)
        internal
        view
        virtual
        returns (IERC20 cToken, uint256 cAmount);

    /// @dev Reverts if new offers on `token` aren't allowed in this market.
    function _checkAsset(address token) internal view virtual;

    // ---------------------------------------------------------------- internal

    function _open(
        address seller,
        address payer,
        address token,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint64 offerDeadline
    ) internal returns (uint256 id) {
        _checkAsset(token);
        if (amount == 0) revert Errors.AmountZero();
        if (strike == 0 || strike < registry.minStrike(token)) revert Errors.StrikeTooLow();
        if (premium < Constants.MIN_PREMIUM) revert Errors.PremiumTooLow();
        if (
            expiry <= block.timestamp || expiry - block.timestamp < Constants.MIN_DURATION
                || expiry - block.timestamp > Constants.MAX_DURATION
        ) revert Errors.BadDuration();
        if (offerDeadline <= block.timestamp || offerDeadline > expiry) revert Errors.BadDeadline();
        if (exposure[token] + amount > registry.cap(token)) revert Errors.CapExceeded();
        if (openOffers[seller] >= Constants.MAX_OPEN_PER_SELLER) revert Errors.TooManyOpen();

        (IERC20 cToken, uint256 cAmount) = _collateral(token, amount, strike);
        id = idOf(++lastLocalId);
        _positions[id] = Position({
            seller: seller,
            expiry: expiry,
            feeBpsPremium: feeBpsPremium,
            token: token,
            offerDeadline: offerDeadline,
            feeBpsExercise: feeBpsExercise,
            status: Status.Open,
            amount: amount,
            strike: strike,
            premium: premium
        });
        locked[address(cToken)] += cAmount;
        exposure[token] += amount;
        ++openOffers[seller];

        _pullExact(cToken, payer, cAmount);
        emit Events.OfferCreated(id, seller, token, amount, strike, premium, expiry, offerDeadline);
    }

    function _buy(uint256 id, uint256 maxPremium, address payer, address beneficiary) internal {
        Position storage p = _positions[id];
        if (p.status != Status.Open) revert Errors.WrongStatus(p.status);
        if (block.timestamp > p.offerDeadline) revert Errors.OfferExpired();
        if (beneficiary == p.seller) revert Errors.SelfTrade();
        if (p.premium > maxPremium) revert Errors.PremiumAboveMax();

        uint256 fee = p.premium * p.feeBpsPremium / Constants.BPS;
        p.status = Status.Filled;
        --openOffers[p.seller];
        nft.mint(beneficiary, id);

        if (fee > 0) weth.safeTransferFrom(payer, feeVault, fee);
        weth.safeTransferFrom(payer, p.seller, p.premium - fee);
        emit Events.OptionBought(id, beneficiary, p.premium, fee);
    }

    function _expire(uint256 id, bool strict) internal returns (bool) {
        Position storage p = _positions[id];
        if (p.status != Status.Filled) {
            if (strict) revert Errors.WrongStatus(p.status);
            return false;
        }
        if (block.timestamp < p.expiry) {
            if (strict) revert Errors.NotExpired();
            return false;
        }
        p.status = Status.Expired;
        nft.burn(id);
        emit Events.Expired(id, msg.sender);
        _returnCollateral(p);
        return true;
    }

    /// @dev Removes a position's collateral from the ledgers. Call after setting a terminal status.
    function _unlock(Position storage p) internal returns (IERC20 cToken, uint256 cAmount) {
        (cToken, cAmount) = _collateral(p.token, p.amount, p.strike);
        locked[address(cToken)] -= cAmount;
        exposure[p.token] -= p.amount;
    }

    function _returnCollateral(Position storage p) internal {
        (IERC20 cToken, uint256 cAmount) = _unlock(p);
        cToken.safeTransfer(p.seller, cAmount);
    }

    /// @dev Rejects fee-on-transfer and similar tokens: the balance must grow by exactly `amount`.
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert Errors.FeeOnTransfer();
    }

    function _setFees(uint32 premiumBps, uint16 exerciseBps) internal {
        if (premiumBps > Constants.MAX_FEE_BPS_PREMIUM || exerciseBps > Constants.MAX_FEE_BPS_EXERCISE) {
            revert Errors.FeeAboveCap();
        }
        emit Events.ParamChanged("feeBpsPremium", feeBpsPremium, premiumBps);
        emit Events.ParamChanged("feeBpsExercise", feeBpsExercise, exerciseBps);
        feeBpsPremium = premiumBps;
        feeBpsExercise = exerciseBps;
    }
}
