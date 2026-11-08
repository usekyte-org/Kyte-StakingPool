// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Governed} from "./lib/Governed.sol";

/// @notice Minimal view of the Pons launchpad factory (ponsfamily.com, Robinhood Chain).
interface IPonsFactory {
    struct Launched {
        address token;
        address deployer;
        address pairedToken;
        address positionManager;
        uint256 positionId;
        uint256 dexId;
        uint256 launchConfigId;
        uint256 restrictionsEndBlock;
        uint256 supply;
        bool isToken0;
        uint24 poolFee;
        bool exists;
        uint256 initialBuyAmount;
    }

    function getLaunchedToken(address token) external view returns (Launched memory launched);
    function graduationStatus(address token)
        external
        view
        returns (uint256 pairedPrincipal, uint256 threshold, bool graduated);
}

interface IRegistryListed {
    function getAsset(address token)
        external
        view
        returns (bool listed, bool enabled, bool putsEnabled, uint8 decimals, uint256 cap, uint256 minStrike);
}

/// @title PonsLister
/// @notice Permissionless listing of graduated Pons launchpad tokens on Kyte. Anyone calls `list(token)`; the
/// contract verifies on chain that the token came from a Pons factory, has graduated, is paired with WETH, keeps its
/// liquidity position in a Pons locker and has 18 decimals, then schedules `AssetRegistry.addAsset` through the
/// protocol timelock with a cap derived from supply. After the timelock delay anyone calls `execute(token)`.
///
/// The lister holds the timelock's proposer and executor roles, but the only call it can ever propose is the
/// `addAsset` it builds itself, so the roles grant nothing beyond "list a graduated Pons token". The timelock keeps
/// every other right (cap formula, factories, lockers, minimum strike) and the guardian can pause new listings.
contract PonsLister is Governed {
    TimelockController public immutable timelockController;
    address public immutable registry;
    address public immutable weth;

    /// @notice Cap per listing as a share of total supply, in basis points (200 = 2%).
    uint256 public capBps;
    /// @notice Minimum total strike (wei) written into each listing.
    uint256 public minStrike;
    /// @notice Pons factories whose launches qualify (active and legacy).
    address[] public factories;
    /// @notice Pons lockers that must own the liquidity position.
    mapping(address locker => bool) public lockers;

    /// @notice Timelock operation id per token once scheduled; zero until then.
    mapping(address token => bytes32) public operationOf;
    mapping(address token => bytes32) public saltOf;
    /// @notice Cap and minimum strike frozen at scheduling; execution replays exactly what was scheduled.
    mapping(address token => uint256) public capOf;
    mapping(address token => uint256) public minStrikeOf;
    /// @dev Makes every scheduled operation id unique, even for the same token after a reset.
    uint256 public nonce;

    event ListingScheduled(
        address indexed token, bytes32 indexed operationId, uint256 cap, uint256 minStrike, uint256 readyAt
    );
    event ListingExecuted(address indexed token, bytes32 indexed operationId);
    event CapBpsChanged(uint256 oldValue, uint256 newValue);
    event MinStrikeChanged(uint256 oldValue, uint256 newValue);
    event FactoryAdded(address indexed factory);
    event FactoryRemoved(address indexed factory);
    event LockerSet(address indexed locker, bool allowed);

    error NotPonsToken();
    error NotGraduated();
    error NotWethPair();
    error PositionNotLocked();
    error BadDecimals();
    error AlreadyListed();
    error AlreadyScheduled();
    error NotScheduled();
    error BadBps();

    constructor(
        address timelock_,
        address guardian_,
        address registry_,
        address weth_,
        address[] memory factories_,
        address[] memory lockers_,
        uint256 capBps_,
        uint256 minStrike_
    ) Governed(timelock_, guardian_) {
        if (registry_ == address(0) || weth_ == address(0)) revert Errors.ZeroAddress();
        if (capBps_ == 0 || capBps_ > 10_000) revert BadBps();
        timelockController = TimelockController(payable(timelock_));
        registry = registry_;
        weth = weth_;
        for (uint256 i; i < factories_.length; i++) {
            _addFactory(factories_[i]);
        }
        for (uint256 i; i < lockers_.length; i++) {
            if (lockers_[i] == address(0)) revert Errors.ZeroAddress();
            lockers[lockers_[i]] = true;
            emit LockerSet(lockers_[i], true);
        }
        capBps = capBps_;
        minStrike = minStrike_;
    }

    // ---------------------------------------------------------------- listing

    /// @notice Checks a graduated Pons token and schedules its listing through the timelock. Anyone may call.
    /// @return operationId the timelock operation; `execute(token)` runs it after the delay.
    function list(address token) external whenNotPaused returns (bytes32 operationId) {
        if (operationOf[token] != bytes32(0)) revert AlreadyScheduled();
        (uint256 cap,) = check(token);
        bytes memory data = abi.encodeWithSignature("addAsset(address,uint256,uint256)", token, cap, minStrike);
        bytes32 salt = keccak256(abi.encodePacked("pons-lister", token, ++nonce));
        uint256 delay = timelockController.getMinDelay();
        operationId = timelockController.hashOperation(registry, 0, data, bytes32(0), salt);
        timelockController.schedule(registry, 0, data, bytes32(0), salt, delay);
        operationOf[token] = operationId;
        saltOf[token] = salt;
        capOf[token] = cap;
        minStrikeOf[token] = minStrike;
        emit ListingScheduled(token, operationId, cap, minStrike, block.timestamp + delay);
    }

    /// @notice Executes a scheduled listing once the timelock delay has passed. Anyone may call.
    function execute(address token) external {
        bytes32 operationId = operationOf[token];
        if (operationId == bytes32(0)) revert NotScheduled();
        bytes memory data =
            abi.encodeWithSignature("addAsset(address,uint256,uint256)", token, capOf[token], minStrikeOf[token]);
        timelockController.execute(registry, 0, data, bytes32(0), saltOf[token]);
        emit ListingExecuted(token, operationId);
    }

    /// @notice Every condition a token must meet, as a view. Reverts with the first failing one.
    /// @return cap the listing cap in token units; @return factory the Pons factory that launched it.
    function check(address token) public view returns (uint256 cap, address factory) {
        IPonsFactory.Launched memory l;
        for (uint256 i; i < factories.length; i++) {
            l = IPonsFactory(factories[i]).getLaunchedToken(token);
            if (l.exists) {
                factory = factories[i];
                break;
            }
        }
        if (factory == address(0)) revert NotPonsToken();
        (,, bool graduated) = IPonsFactory(factory).graduationStatus(token);
        if (!graduated) revert NotGraduated();
        if (l.pairedToken != weth) revert NotWethPair();
        address owner = IERC721(l.positionManager).ownerOf(l.positionId);
        if (!lockers[owner]) revert PositionNotLocked();
        if (IERC20Metadata(token).decimals() != 18) revert BadDecimals();
        (bool listed,,,,,) = IRegistryListed(registry).getAsset(token);
        if (listed) revert AlreadyListed();
        cap = (IERC20Metadata(token).totalSupply() * capBps) / 10_000;
        if (cap == 0) revert Errors.AmountZero();
    }

    function factoryCount() external view returns (uint256) {
        return factories.length;
    }

    // ---------------------------------------------------------------- admin (timelock)

    /// @notice Forgets a scheduled listing that can never execute (the timelock cancelled it, or the registry is
    /// full), so `list` can be called again later. Does not touch the timelock itself.
    function reset(address token) external onlyTimelock {
        delete operationOf[token];
        delete saltOf[token];
        delete capOf[token];
        delete minStrikeOf[token];
    }

    function setCapBps(uint256 capBps_) external onlyTimelock {
        if (capBps_ == 0 || capBps_ > 10_000) revert BadBps();
        emit CapBpsChanged(capBps, capBps_);
        capBps = capBps_;
    }

    function setMinStrike(uint256 minStrike_) external onlyTimelock {
        emit MinStrikeChanged(minStrike, minStrike_);
        minStrike = minStrike_;
    }

    function addFactory(address factory) external onlyTimelock {
        _addFactory(factory);
    }

    function removeFactory(address factory) external onlyTimelock {
        uint256 n = factories.length;
        for (uint256 i; i < n; i++) {
            if (factories[i] == factory) {
                factories[i] = factories[n - 1];
                factories.pop();
                emit FactoryRemoved(factory);
                return;
            }
        }
        revert Errors.NotConfigured();
    }

    function setLocker(address locker, bool allowed) external onlyTimelock {
        if (locker == address(0)) revert Errors.ZeroAddress();
        lockers[locker] = allowed;
        emit LockerSet(locker, allowed);
    }

    function _addFactory(address factory) internal {
        if (factory == address(0)) revert Errors.ZeroAddress();
        for (uint256 i; i < factories.length; i++) {
            if (factories[i] == factory) revert Errors.MarketsAlreadySet();
        }
        factories.push(factory);
        emit FactoryAdded(factory);
    }
}
