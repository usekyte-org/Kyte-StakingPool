// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAssetRegistry} from "./interfaces/IAssetRegistry.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Governed} from "./lib/Governed.sol";

/// @notice Token whitelist (spec §6). Only the timelock lists or re-enables;
/// the guardian can only switch things off. A token must pass the listing checklist before `addAsset`.
contract AssetRegistry is IAssetRegistry, Governed {
    struct Asset {
        bool listed;
        bool enabled;
        bool putsEnabled;
        uint8 decimals;
        uint256 cap; // max underlying (token units) in open + filled positions, per market
        uint256 minStrike; // min total strike in WETH
    }

    mapping(address token => Asset) internal _assets;
    address[] public listedTokens;

    constructor(address timelock_, address guardian_) Governed(timelock_, guardian_) {}

    // ---------------------------------------------------------------- admin

    function addAsset(address token, uint256 cap_, uint256 minStrike_) external onlyTimelock {
        _add(token, cap_, minStrike_);
    }

    /// @notice Lists many tokens in one timelock operation (v2: the Robinhood Stock Token catalogue), optionally
    /// with puts enabled. Same checks as `addAsset` for every entry; one bad entry reverts the whole batch.
    function addAssets(address[] calldata tokens, uint256[] calldata caps, uint256[] calldata minStrikes, bool putsOn)
        external
        onlyTimelock
    {
        if (tokens.length != caps.length || tokens.length != minStrikes.length) revert Errors.LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) {
            _add(tokens[i], caps[i], minStrikes[i]);
            if (putsOn) {
                _assets[tokens[i]].putsEnabled = true;
                emit Events.PutsEnabled(tokens[i], true);
            }
        }
    }

    function _add(address token, uint256 cap_, uint256 minStrike_) internal {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (_assets[token].listed) revert Errors.AssetExists();
        if (listedTokens.length >= Constants.MAX_ASSETS) revert Errors.TooManyAssets();
        _assets[token] = Asset({
            listed: true,
            enabled: true,
            putsEnabled: false,
            decimals: IERC20Metadata(token).decimals(),
            cap: cap_,
            minStrike: minStrike_
        });
        listedTokens.push(token);
        emit Events.AssetAdded(token, cap_, minStrike_);
    }

    /// @dev Enabling needs the timelock; disabling can be done by the guardian immediately.
    function setEnabled(address token, bool enabled) external {
        _authorizeToggle(enabled);
        Asset storage a = _listed(token);
        a.enabled = enabled;
        emit Events.AssetEnabled(token, enabled);
    }

    function setPutsEnabled(address token, bool enabled) external {
        _authorizeToggle(enabled);
        Asset storage a = _listed(token);
        a.putsEnabled = enabled;
        emit Events.PutsEnabled(token, enabled);
    }

    function setCap(address token, uint256 cap_) external onlyTimelock {
        Asset storage a = _listed(token);
        emit Events.ParamChanged(keccak256(abi.encode("cap", token)), a.cap, cap_);
        a.cap = cap_;
    }

    function setMinStrike(address token, uint256 minStrike_) external onlyTimelock {
        Asset storage a = _listed(token);
        emit Events.ParamChanged(keccak256(abi.encode("minStrike", token)), a.minStrike, minStrike_);
        a.minStrike = minStrike_;
    }

    // ---------------------------------------------------------------- views

    function isEnabled(address token) external view returns (bool) {
        return _assets[token].enabled;
    }

    /// @dev Puts need both flags, so disabling an asset also stops new puts on it.
    function putsEnabled(address token) external view returns (bool) {
        Asset storage a = _assets[token];
        return a.enabled && a.putsEnabled;
    }

    function cap(address token) external view returns (uint256) {
        return _assets[token].cap;
    }

    function minStrike(address token) external view returns (uint256) {
        return _assets[token].minStrike;
    }

    function getAsset(address token) external view returns (Asset memory) {
        return _assets[token];
    }

    function assetCount() external view returns (uint256) {
        return listedTokens.length;
    }

    // ---------------------------------------------------------------- internal

    function _authorizeToggle(bool enabling) internal view {
        if (enabling) {
            if (msg.sender != timelock) revert Errors.NotTimelock();
        } else if (msg.sender != guardian && msg.sender != timelock) {
            revert Errors.NotGuardian();
        }
    }

    function _listed(address token) internal view returns (Asset storage a) {
        a = _assets[token];
        if (!a.listed) revert Errors.UnknownAsset();
    }
}
