// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title KyteHook: Uniswap v4 hook for Kyte pools
/// @notice Two jobs on every hooked pool (the $KYTE/WETH pool first):
///  1. **TWAP oracle.** Records a tick observation after every swap (ring buffer of 128), so the BuybackBurner
///     can bound slippage against a time-weighted price instead of spot (spec §7.3 and §16 Q5).
///  2. **Protocol fee.** Takes `feeBps` of the swap's unspecified currency and sends it straight to the
///     FeeVault, where it joins the 30 / 20 / 50 split like every other Kyte fee.
/// @dev Permissions: afterInitialize, afterSwap, afterSwapReturnDelta. v4 encodes permissions in the hook's
/// address, so it is deployed at a mined CREATE2 address (see script/DeployDevnet.s.sol). Owner = timelock.
contract KyteHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    error OnlyPoolManager();
    error NotImplemented();
    error NotOwner();
    error FeeTooHigh();
    error NoObservations();
    error ZeroAddress();

    event HookFee(PoolId indexed id, Currency indexed currency, uint256 amount);
    event FeeChanged(uint256 oldBps, uint256 newBps);
    event FeeVaultChanged(address oldVault, address newVault);

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative; // sum of tick * seconds up to blockTimestamp
        int24 tick; // tick in force from blockTimestamp onward
    }

    struct OracleState {
        uint16 index;
        uint16 count;
    }

    uint16 public constant CARDINALITY = 128;
    uint256 public constant MAX_FEE_BPS = 100; // 1%
    uint256 internal constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public feeVault;
    uint256 public feeBps;
    /// @notice When set, the fee is only taken when the swap's unspecified currency is this one (WETH on Kyte),
    /// so the FeeVault only ever receives what it can split. Zero = any currency.
    Currency public feeCurrencyOnly;

    mapping(PoolId id => Observation[128]) internal observations;
    mapping(PoolId id => OracleState) public oracle;

    constructor(
        IPoolManager poolManager_,
        address owner_,
        address feeVault_,
        uint256 feeBps_,
        Currency feeCurrencyOnly_
    ) {
        if (address(poolManager_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        poolManager = poolManager_;
        owner = owner_;
        feeVault = feeVault_;
        feeBps = feeBps_;
        feeCurrencyOnly = feeCurrencyOnly_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setFee(uint256 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeChanged(feeBps, feeBps_);
        feeBps = feeBps_;
    }

    function setFeeVault(address feeVault_) external onlyOwner {
        emit FeeVaultChanged(feeVault, feeVault_);
        feeVault = feeVault_;
    }

    // ---------------------------------------------------------------- hooks

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _write(key.toId(), tick);
        return IHooks.afterInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        _write(id, tick);

        uint256 feeAmount;
        if (feeBps > 0 && feeVault != address(0)) {
            // The fee is taken from the swap's unspecified currency, like Uniswap's reference fee hook.
            bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
            (Currency feeCurrency, int128 amount) =
                specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
            if (amount < 0) amount = -amount;
            bool eligible = Currency.unwrap(feeCurrencyOnly) == address(0) || feeCurrency == feeCurrencyOnly;
            feeAmount = eligible ? uint256(uint128(amount)) * feeBps / BPS : 0;
            if (feeAmount > 0) {
                poolManager.take(feeCurrency, feeVault, feeAmount);
                emit HookFee(id, feeCurrency, feeAmount);
            }
        }
        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    // ---------------------------------------------------------------- oracle

    /// @notice Time-weighted average tick over the last `secondsAgo` seconds (clamped to the stored history).
    function consult(PoolId id, uint32 secondsAgo) public view returns (int24 meanTick) {
        OracleState memory o = oracle[id];
        if (o.count == 0) revert NoObservations();
        Observation[128] storage obs = observations[id];
        Observation memory last = obs[o.index];
        uint32 nowTs = uint32(block.timestamp);
        if (secondsAgo == 0 || nowTs == last.blockTimestamp && o.count == 1) return last.tick;

        uint32 target = nowTs > secondsAgo ? nowTs - secondsAgo : 0;
        // walk back to the newest observation at or before `target`; fall back to the oldest one we have
        Observation memory at = last;
        for (uint16 i = 0; i < o.count; i++) {
            uint16 idx = uint16((uint32(o.index) + CARDINALITY - i) % CARDINALITY);
            Observation memory ob = obs[idx];
            at = ob;
            if (ob.blockTimestamp <= target) break;
        }
        if (at.blockTimestamp > target) target = at.blockTimestamp;
        if (nowTs == target) return last.tick;

        int56 cumNow = last.tickCumulative + int56(last.tick) * int56(uint56(nowTs - last.blockTimestamp));
        int56 cumAt = at.tickCumulative + int56(at.tick) * int56(uint56(target - at.blockTimestamp));
        int56 delta = cumNow - cumAt;
        uint56 span = uint56(nowTs - target);
        meanTick = int24(delta / int56(span));
        if (delta < 0 && delta % int56(span) != 0) meanTick--;
    }

    /// @notice TWAP as sqrtPriceX96, ready for quoting.
    function twapSqrtPriceX96(PoolId id, uint32 secondsAgo) external view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(consult(id, secondsAgo));
    }

    function observationAt(PoolId id, uint16 i) external view returns (Observation memory) {
        return observations[id][i];
    }

    function _write(PoolId id, int24 tick) internal {
        OracleState storage o = oracle[id];
        Observation[128] storage obs = observations[id];
        uint32 ts = uint32(block.timestamp);
        if (o.count == 0) {
            obs[0] = Observation({blockTimestamp: ts, tickCumulative: 0, tick: tick});
            o.count = 1;
            return;
        }
        Observation storage last = obs[o.index];
        if (last.blockTimestamp == ts) {
            last.tick = tick; // same block: the tick in force from this timestamp is the latest one
            return;
        }
        int56 cum = last.tickCumulative + int56(last.tick) * int56(uint56(ts - last.blockTimestamp));
        uint16 next = uint16((uint32(o.index) + 1) % CARDINALITY);
        obs[next] = Observation({blockTimestamp: ts, tickCumulative: cum, tick: tick});
        o.index = next;
        if (o.count < CARDINALITY) o.count++;
    }

    // ---------------------------------------------------------------- unused hook entry points

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }
}
