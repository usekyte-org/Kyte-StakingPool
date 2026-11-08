// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// Swap venue for BuybackBurner on Robinhood Chain: a direct Uniswap v4 PoolManager swap (unlock → swap →
// settle/take), the same pattern Kyte-rewards' PlatformRouter uses against the verified Robinhood PoolManager
// (0x8366a39CC670B4001A1121B8F6A443A643e40951). Compiled with v4-core's solc (0.8.26); it implements the
// ISwapAdapter ABI without importing the 0.8.28 interface.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {KyteHook} from "../hooks/KyteHook.sol";

contract UniswapV4Adapter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error OnlyPoolManager();
    error DeadlinePassed();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error UnexpectedDelta();
    error BadPool();

    IPoolManager public immutable poolManager;
    IERC20 public immutable weth;
    IERC20 public immutable token;
    bool public immutable zeroForOne; // true when WETH is currency0 of the pool
    /// @notice Optional KyteHook on the pool: when set, quotes use its 10 minute TWAP instead of spot.
    KyteHook public immutable hook;
    uint32 public constant TWAP_WINDOW = 10 minutes;
    PoolKey internal _key;

    struct CallbackData {
        address recipient;
        uint256 amountIn;
    }

    constructor(IPoolManager poolManager_, IERC20 weth_, IERC20 token_, PoolKey memory key_, KyteHook hook_) {
        address c0 = Currency.unwrap(key_.currency0);
        address c1 = Currency.unwrap(key_.currency1);
        bool wethIs0 = c0 == address(weth_) && c1 == address(token_);
        bool wethIs1 = c1 == address(weth_) && c0 == address(token_);
        if (!wethIs0 && !wethIs1) revert BadPool();
        // A hook given here must be the pool's own hook, or its TWAP would describe some other pool.
        if (address(hook_) != address(0) && address(key_.hooks) != address(hook_)) revert BadPool();
        poolManager = poolManager_;
        weth = weth_;
        token = token_;
        zeroForOne = wethIs0;
        _key = key_;
        hook = hook_;
    }

    function key() external view returns (PoolKey memory) {
        return _key;
    }

    /// @notice Pull `wethIn` from the caller, swap it in the pool, send the tokens to the caller.
    function swapWethForToken(uint256 wethIn, uint256 minOut, uint256 deadline) external returns (uint256 out) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        weth.safeTransferFrom(msg.sender, address(this), wethIn);
        out = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, wethIn))), (uint256));
        if (out < minOut) revert InsufficientOutput(out, minOut);
    }

    /// @notice Quote net of the LP fee. With a KyteHook on the pool this is the 10 minute TWAP, which a single
    /// block can't move; otherwise the spot price (devnet/tests only). BuybackBurner enforces this on-chain.
    /// @dev Hooked pools never fall back to spot: if the oracle can't answer, the quote reverts, so a
    /// manipulated spot price can never become the buyback's slippage floor.
    function quoteWethForToken(uint256 wethIn) external view returns (uint256 out) {
        if (address(hook) != address(0)) return _quote(wethIn, hook.twapSqrtPriceX96(_key.toId(), TWAP_WINDOW));
        return quoteSpot(wethIn);
    }

    /// @notice Spot-price quote net of the LP fee (ignores price impact).
    function quoteSpot(uint256 wethIn) public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_key.toId());
        return _quote(wethIn, sqrtPriceX96);
    }

    function _quote(uint256 wethIn, uint160 sqrtPriceX96) internal view returns (uint256 out) {
        // price of currency0 in currency1, Q96
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        out = zeroForOne ? FullMath.mulDiv(wethIn, priceX96, 1 << 96) : FullMath.mulDiv(wethIn, 1 << 96, priceX96);
        out = out * (1_000_000 - _key.fee) / 1_000_000;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        BalanceDelta delta = poolManager.swap(
            _key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(d.amountIn), // negative = exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inDelta > 0 || outDelta < 0) revert UnexpectedDelta();

        uint256 paid = uint256(uint128(-inDelta));
        uint256 out = uint256(uint128(outDelta));
        Currency cIn = zeroForOne ? _key.currency0 : _key.currency1;
        Currency cOut = zeroForOne ? _key.currency1 : _key.currency0;

        poolManager.sync(cIn);
        weth.safeTransfer(address(poolManager), paid);
        poolManager.settle();
        if (out > 0) poolManager.take(cOut, d.recipient, out);
        // A partial fill (pool ran out of range) leaves WETH here; return it to the caller.
        if (paid < d.amountIn) weth.safeTransfer(d.recipient, d.amountIn - paid);
        return abi.encode(out);
    }
}
