// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingPool} from "../src/StakingPool.sol";
import {Constants} from "../src/lib/Constants.sol";
import {Errors} from "../src/lib/Errors.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";

contract StakingPoolTest is Test {
    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal vault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal draft;
    MockWETH internal weth;
    StakingPool internal pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        draft = new MockERC20("Draft", "DRAFT", 18);
        weth = new MockWETH();
        pool = new StakingPool(IERC20(address(draft)), IERC20(address(weth)), vault, timelock, guardian);
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? alice : bob;
            draft.mint(a, 1_000_000e18);
            vm.prank(a);
            draft.approve(address(pool), type(uint256).max);
        }
    }

    function _reward(uint256 amount) internal {
        weth.mint(address(pool), amount);
        vm.prank(vault);
        pool.notifyReward(amount);
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + Constants.EPOCH);
    }

    function test_stake_isPendingUntilNextEpoch() public {
        vm.prank(alice);
        pool.stake(100e18);
        (uint256 active, uint256 pending) = pool.balancesOf(alice);
        assertEq(active, 0);
        assertEq(pending, 100e18);
        assertEq(pool.stakeOf(alice), 100e18);
        assertEq(pool.pendingSupply(), 100e18);

        _nextEpoch();
        (active, pending) = pool.balancesOf(alice);
        assertEq(active, 100e18);
        assertEq(pending, 0);
    }

    function test_flashStake_earnsNothing() public {
        vm.prank(alice);
        pool.stake(100e18);
        _reward(1 ether); // nobody active yet
        assertEq(pool.undistributed(), 1 ether);
        assertEq(pool.pendingRewards(alice), 0);

        _nextEpoch();
        // alice is active now; bob stakes just before the next reward
        vm.prank(bob);
        pool.stake(100e18);
        _reward(1 ether);
        assertEq(pool.pendingRewards(alice), 2 ether); // includes the undistributed 1 ETH
        assertEq(pool.pendingRewards(bob), 0);
        assertEq(pool.undistributed(), 0);
    }

    function test_proRata() public {
        vm.prank(alice);
        pool.stake(300e18);
        vm.prank(bob);
        pool.stake(100e18);
        _nextEpoch();
        _reward(4 ether);
        assertEq(pool.pendingRewards(alice), 3 ether);
        assertEq(pool.pendingRewards(bob), 1 ether);
    }

    function test_lateJoiner_onlyEarnsAfterActivation() public {
        vm.prank(alice);
        pool.stake(100e18);
        _nextEpoch();
        _reward(1 ether); // alice alone
        vm.prank(bob);
        pool.stake(100e18);
        _nextEpoch();
        _reward(2 ether); // split
        assertEq(pool.pendingRewards(alice), 2 ether);
        assertEq(pool.pendingRewards(bob), 1 ether);

        vm.prank(bob);
        pool.claim();
        assertEq(weth.balanceOf(bob), 1 ether);
        assertEq(pool.pendingRewards(bob), 0);
    }

    function test_unstake_pendingFirst_keepsRewards() public {
        vm.prank(alice);
        pool.stake(100e18);
        _nextEpoch();
        _reward(1 ether);
        _nextEpoch(); // past the activation lock
        vm.prank(alice);
        pool.stake(50e18); // pending
        vm.prank(alice);
        pool.unstake(60e18); // 50 pending + 10 active
        (uint256 active, uint256 pending) = pool.balancesOf(alice);
        assertEq(active, 90e18);
        assertEq(pending, 0);
        assertEq(pool.pendingRewards(alice), 1 ether);
        assertEq(draft.balanceOf(alice), 1_000_000e18 - 90e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientStake.selector);
        pool.unstake(91e18);
    }

    /// Just-in-time staking: stake right before the epoch ends, take the split, leave. Blocked by the lock.
    function test_jitStake_cantLeaveRightAfterSplit() public {
        vm.prank(alice);
        pool.stake(100e18);
        _nextEpoch();
        _nextEpoch(); // alice is a long-term staker, unlocked
        // bob stakes in the last second of the epoch
        vm.warp((block.timestamp / Constants.EPOCH + 1) * Constants.EPOCH - 1);
        vm.prank(bob);
        pool.stake(100e18);
        vm.warp(block.timestamp + 2); // new epoch
        _reward(2 ether); // split
        assertEq(pool.pendingRewards(bob), 1 ether);
        (uint256 locked,) = pool.lockedOf(bob);
        assertEq(locked, 100e18);
        vm.prank(bob);
        vm.expectRevert(Errors.StakeLocked.selector);
        pool.unstake(1);
        // he can still claim what he earned, and leave after staying through the epoch
        vm.prank(bob);
        pool.claim();
        _nextEpoch();
        (locked,) = pool.lockedOf(bob);
        assertEq(locked, 0);
        vm.prank(bob);
        pool.unstake(100e18);
        // alice was never locked
        vm.prank(alice);
        pool.unstake(1e18);
    }

    /// Only the newly activated part is locked; older active stake stays free.
    function test_lock_onlyCoversNewStake() public {
        vm.prank(alice);
        pool.stake(100e18);
        _nextEpoch();
        _nextEpoch();
        vm.prank(alice);
        pool.stake(40e18);
        _nextEpoch(); // 40 activates now and is locked this epoch
        vm.prank(alice);
        pool.unstake(100e18); // the old 100 is free
        vm.prank(alice);
        vm.expectRevert(Errors.StakeLocked.selector);
        pool.unstake(1);
        _nextEpoch();
        vm.prank(alice);
        pool.unstake(40e18);
    }

    function test_claim_minClaim() public {
        vm.prank(timelock);
        pool.setMinClaim(0.01 ether);
        vm.prank(alice);
        pool.stake(100e18);
        _nextEpoch();
        _reward(0.001 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.BelowMinClaim.selector);
        pool.claim();
        _reward(0.01 ether);
        vm.prank(alice);
        pool.claim();
        assertEq(weth.balanceOf(alice), 0.011 ether);
    }

    function test_notifyReward_onlyVault() public {
        vm.expectRevert(Errors.NotMarket.selector);
        pool.notifyReward(1);
    }

    function test_pause_blocksStakeOnly() public {
        vm.prank(alice);
        pool.stake(100e18);
        _nextEpoch();
        _reward(1 ether);
        vm.prank(guardian);
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(Errors.MarketPaused.selector);
        pool.stake(1);
        _nextEpoch(); // past the activation lock
        vm.prank(alice);
        pool.unstake(50e18);
        vm.prank(alice);
        pool.claim();
    }

    function test_stake_reverts_zero() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        pool.stake(0);
    }

    /// Invariant 6: pool WETH >= everything claimable + undistributed; token balance == active + pending.
    function testFuzz_solvency(uint256 a, uint256 b, uint256 r1, uint256 r2) public {
        a = bound(a, 1, 1_000_000e18);
        b = bound(b, 1, 1_000_000e18);
        r1 = bound(r1, 0, 1_000 ether);
        r2 = bound(r2, 0, 1_000 ether);
        vm.prank(alice);
        pool.stake(a);
        if (r1 > 0) _reward(r1);
        _nextEpoch();
        vm.prank(bob);
        pool.stake(b);
        if (r2 > 0) _reward(r2);
        _nextEpoch();
        if (r2 > 0) _reward(r2);

        uint256 owed = pool.pendingRewards(alice) + pool.pendingRewards(bob) + pool.undistributed();
        assertLe(owed, weth.balanceOf(address(pool)));
        assertGe(owed + 2, weth.balanceOf(address(pool))); // dust only
        assertEq(pool.activeSupply() + pool.pendingSupply(), draft.balanceOf(address(pool)));
    }
}
