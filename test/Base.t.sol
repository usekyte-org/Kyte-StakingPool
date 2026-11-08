// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {CallMarket} from "../src/CallMarket.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {OptionNFT} from "../src/OptionNFT.sol";
import {PutMarket} from "../src/PutMarket.sol";
import {IAssetRegistry} from "../src/interfaces/IAssetRegistry.sol";
import {IOptionNFT} from "../src/interfaces/IOptionNFT.sol";
import {MockERC20, MockRewardSink, MockWETH} from "./mocks/Mocks.sol";

/// @dev Deploys the M1 system in spec §14 order, with one listed token (puts enabled).
abstract contract BaseTest is Test {
    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal opsSafe = makeAddr("opsSafe");
    address internal buyback = makeAddr("buybackBurner");
    address internal router = makeAddr("router");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    MockWETH internal weth;
    MockERC20 internal token;
    AssetRegistry internal registry;
    OptionNFT internal nft;
    FeeVault internal vault;
    MockRewardSink internal pool;
    CallMarket internal calls;
    PutMarket internal puts;

    uint256 internal constant CAP = 1_000_000e18;
    uint256 internal constant MIN_STRIKE = 0.001 ether;
    uint32 internal constant FEE_PREMIUM = 300;
    uint16 internal constant FEE_EXERCISE = 10;

    // default terms
    uint256 internal constant AMOUNT = 1_000e18;
    uint256 internal constant STRIKE = 2 ether;
    uint256 internal constant PREMIUM = 0.1 ether;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        weth = new MockWETH();
        token = new MockERC20("Zephyr", "ZEPH", 18);

        registry = new AssetRegistry(timelock, guardian);
        nft = new OptionNFT();
        vault = new FeeVault(IERC20(address(weth)), timelock, guardian);
        pool = new MockRewardSink(IERC20(address(weth)));
        calls = new CallMarket(
            IAssetRegistry(address(registry)),
            IOptionNFT(address(nft)),
            IERC20(address(weth)),
            address(vault),
            timelock,
            guardian,
            FEE_PREMIUM,
            FEE_EXERCISE
        );
        puts = new PutMarket(
            IAssetRegistry(address(registry)),
            IOptionNFT(address(nft)),
            IERC20(address(weth)),
            address(vault),
            timelock,
            guardian,
            FEE_PREMIUM,
            FEE_EXERCISE
        );
        nft.setMarkets(address(calls), address(puts));

        vm.startPrank(timelock);
        vault.setDestinations(address(pool), buyback, opsSafe);
        registry.addAsset(address(token), CAP, MIN_STRIKE);
        registry.setPutsEnabled(address(token), true);
        calls.setRouter(router);
        puts.setRouter(router);
        vm.stopPrank();

        _fund(seller);
        _fund(buyer);
        _fund(router);
    }

    function _fund(address who) internal {
        token.mint(who, 10_000_000e18);
        weth.mint(who, 1_000 ether);
        vm.startPrank(who);
        token.approve(address(calls), type(uint256).max);
        token.approve(address(puts), type(uint256).max);
        weth.approve(address(calls), type(uint256).max);
        weth.approve(address(puts), type(uint256).max);
        vm.stopPrank();
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _call() internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.createOffer(address(token), AMOUNT, STRIKE, PREMIUM, _expiry(), _deadline());
    }

    function _filledCall() internal returns (uint256 id) {
        id = _call();
        vm.prank(buyer);
        calls.buy(id, PREMIUM);
    }

    function _put() internal returns (uint256 id) {
        vm.prank(seller);
        id = puts.createPutOffer(address(token), AMOUNT, STRIKE, PREMIUM, _expiry(), _deadline());
    }

    function _filledPut() internal returns (uint256 id) {
        id = _put();
        vm.prank(buyer);
        puts.buy(id, PREMIUM);
    }
}
