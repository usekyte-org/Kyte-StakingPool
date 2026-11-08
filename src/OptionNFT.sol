// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IOptionMarket} from "./interfaces/IOptionMarket.sol";
import {IOptionNFT} from "./interfaces/IOptionNFT.sol";
import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {Position} from "./lib/Types.sol";

/// @notice One NFT per filled option (spec §5). Whoever holds it at exercise time gets the payout.
/// @dev Only the two markets mint and burn, each only within its own id tag. `_mint`, never `_safeMint`,
/// so a buyer contract can't reenter during `buy`. Markets are set once by the deployer and then locked.
contract OptionNFT is ERC721, IOptionNFT {
    using Strings for uint256;

    address public immutable deployer;
    address public callMarket;
    address public putMarket;

    constructor() ERC721("Option", "OPTION") {
        deployer = msg.sender;
    }

    function setMarkets(address callMarket_, address putMarket_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (callMarket != address(0)) revert Errors.MarketsAlreadySet();
        if (callMarket_ == address(0) || putMarket_ == address(0)) revert Errors.ZeroAddress();
        callMarket = callMarket_;
        putMarket = putMarket_;
    }

    function mint(address to, uint256 id) external {
        _onlyMarketFor(id);
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _onlyMarketFor(id);
        _burn(id);
    }

    function ownerOf(uint256 id) public view override(ERC721, IOptionNFT) returns (address) {
        return super.ownerOf(id);
    }

    function marketOf(uint256 id) public view returns (address) {
        uint256 tag = id >> 248;
        if (tag == Constants.CALL_TAG) return callMarket;
        if (tag == Constants.PUT_TAG) return putMarket;
        return address(0);
    }

    /// @notice On-chain JSON + SVG with the option's terms, in human units: token amount, strike and premium in
    /// ETH, expiry as a UTC date. Everything is computed from the position, so nothing off-chain can drift.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Position memory p = IOptionMarket(marketOf(id)).getPosition(id);
        Terms memory t = Terms({
            isCall: (id >> 248) == Constants.CALL_TAG,
            symbol: _symbolOf(p.token),
            local: (id & ((uint256(1) << 248) - 1)).toString(),
            amount: _fmt(p.amount, _decimalsOf(p.token)),
            strike: _fmt(p.strike, 18),
            premium: _fmt(p.premium, 18),
            expiry: _date(p.expiry)
        });
        string memory kind = t.isCall ? "CALL" : "PUT";
        string memory json = string.concat(
            '{"name":"',
            t.symbol,
            " ",
            kind,
            " #",
            t.local,
            '","description":"Kyte option: the right to ',
            t.isCall ? "buy " : "sell ",
            t.amount,
            " ",
            t.symbol,
            " for ",
            t.strike,
            " ETH until ",
            t.expiry,
            '. Physically settled on Robinhood Chain. Exercise before expiry.","external_url":"https://kyte.sh",',
            _attributes(t, p),
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(t))),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    struct Terms {
        bool isCall;
        string symbol;
        string local;
        string amount;
        string strike;
        string premium;
        string expiry;
    }

    function _attributes(Terms memory t, Position memory p) internal pure returns (string memory) {
        return string.concat(
            '"attributes":[{"trait_type":"Type","value":"',
            t.isCall ? "CALL" : "PUT",
            '"},{"trait_type":"Underlying","value":"',
            t.symbol,
            '"},{"trait_type":"Underlying address","value":"',
            Strings.toHexString(p.token),
            '"},{"trait_type":"Amount","value":"',
            t.amount,
            '"},{"trait_type":"Strike (ETH)","value":"',
            t.strike,
            '"},{"trait_type":"Premium (ETH)","value":"',
            t.premium,
            '"},{"display_type":"date","trait_type":"Expiry","value":',
            uint256(p.expiry).toString(),
            "}]"
        );
    }

    /// @dev 400x400 card in the Kyte look: black, green-to-teal glow, mint for calls, coral for puts.
    function _svg(Terms memory t) internal pure returns (string memory) {
        string memory accent = t.isCall ? "#4dfca9" : "#ff9a7a";
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" font-family="Helvetica,Arial,sans-serif">',
            '<defs><radialGradient id="g" cx="0.9" cy="0.05" r="0.9"><stop offset="0" stop-color="#2ee6d6" stop-opacity=".45"/>',
            '<stop offset=".45" stop-color="#4dfca9" stop-opacity=".12"/><stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>',
            '<linearGradient id="k" x1="0" x2="1"><stop offset="0" stop-color="#4dfca9"/><stop offset="1" stop-color="#2ee6d6"/></linearGradient></defs>',
            '<rect width="400" height="400" rx="28" fill="#050607"/><rect width="400" height="400" rx="28" fill="url(#g)"/>',
            '<rect x=".5" y=".5" width="399" height="399" rx="27.5" fill="none" stroke="#ffffff" stroke-opacity=".08"/>',
            '<text x="32" y="52" fill="url(#k)" font-size="22" font-weight="700">Kyte</text>',
            _header(t, accent),
            _row(214, "Amount", string.concat(t.amount, " ", t.symbol)),
            _row(262, "Strike", string.concat(t.strike, " ETH")),
            _row(310, "Premium", string.concat(t.premium, " ETH")),
            _row(358, "Expires", t.expiry),
            "</svg>"
        );
    }

    function _header(Terms memory t, string memory accent) internal pure returns (string memory) {
        return string.concat(
            '<rect x="',
            t.isCall ? "300" : "312",
            '" y="30" width="',
            t.isCall ? "68" : "56",
            '" height="28" rx="14" fill="',
            accent,
            '" fill-opacity=".14" stroke="',
            accent,
            '" stroke-opacity=".5"/><text x="',
            t.isCall ? "334" : "340",
            '" y="49" text-anchor="middle" fill="',
            accent,
            '" font-size="13" font-weight="700" letter-spacing="1.5">',
            t.isCall ? "CALL" : "PUT",
            '</text><text x="32" y="138" fill="#ffffff" font-size="',
            _symbolSize(bytes(t.symbol).length),
            '" font-weight="300" letter-spacing="-1.5">',
            t.symbol,
            '</text><text x="32" y="168" fill="#8b98a8" font-size="14">Option #',
            t.local,
            " \u00b7 Robinhood Chain</text>"
        );
    }

    /// @dev Big symbol that still fits the 336px card width (symbols are at most 16 characters).
    function _symbolSize(uint256 len) internal pure returns (string memory) {
        if (len <= 7) return "54";
        if (len <= 10) return "40";
        if (len <= 13) return "31";
        return "25";
    }

    function _row(uint256 y, string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(
            '<line x1="32" x2="368" y1="',
            (y - 26).toString(),
            '" y2="',
            (y - 26).toString(),
            '" stroke="#ffffff" stroke-opacity=".07"/><text x="32" y="',
            y.toString(),
            '" fill="#8b98a8" font-size="14">',
            k,
            '</text><text x="368" y="',
            y.toString(),
            '" text-anchor="end" fill="#eef3f7" font-size="17" font-family="ui-monospace,Menlo,monospace">',
            v,
            "</text>"
        );
    }

    /// @dev `value / 10**decimals` with thousands separators and at most 6 decimals (truncated, trailing zeros cut).
    function _fmt(uint256 value, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** uint256(decimals);
        string memory whole = _commas(value / unit);
        uint256 frac = value % unit;
        uint256 shown = decimals > 6 ? 6 : decimals;
        if (decimals > 6) frac /= 10 ** (uint256(decimals) - 6);
        if (frac == 0) {
            if (value != 0 && value < unit && value / (10 ** (uint256(decimals) - shown)) == 0) {
                return string.concat("<0.", _zeros(shown - 1), "1");
            }
            return whole;
        }
        while (frac % 10 == 0) {
            frac /= 10;
            --shown;
        }
        string memory digits = frac.toString();
        return string.concat(whole, ".", _zeros(shown - bytes(digits).length), digits);
    }

    function _zeros(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "0";
        }
        return string(b);
    }

    function _commas(uint256 v) internal pure returns (string memory) {
        bytes memory d = bytes(v.toString());
        uint256 n = d.length;
        bytes memory out = new bytes(n + (n - 1) / 3);
        uint256 j = out.length;
        for (uint256 i; i < n; ++i) {
            if (i > 0 && i % 3 == 0) out[--j] = ",";
            out[--j] = d[n - 1 - i];
        }
        return string(out);
    }

    /// @dev Unix seconds to "YYYY-MM-DD HH:MM UTC" (civil-from-days, Howard Hinnant).
    function _date(uint256 ts) internal pure returns (string memory) {
        uint256 z = ts / 1 days + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);
        uint256 secs = ts % 1 days;
        return string.concat(
            year.toString(),
            "-",
            _two(month),
            "-",
            _two(day),
            " ",
            _two(secs / 1 hours),
            ":",
            _two((secs % 1 hours) / 60),
            " UTC"
        );
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", v.toString()) : v.toString();
    }

    function _onlyMarketFor(uint256 id) internal view {
        address m = marketOf(id);
        if (m == address(0) || msg.sender != m) revert Errors.NotMarket();
    }

    function _line(uint256 y, string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(
            '<text x="32" y="',
            y.toString(),
            '" fill="#8b98a8" font-family="monospace" font-size="13">',
            k,
            '</text><text x="32" y="',
            (y + 24).toString(),
            '" fill="#eef3f7" font-family="monospace" font-size="16">',
            v,
            "</text>"
        );
    }

    /// @dev Listed tokens only, but a weird `symbol()` must never break tokenURI.
    /// Only plain alphanumeric symbols are embedded, so a symbol can't inject JSON or SVG.
    function _symbolOf(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            bytes memory b = bytes(s);
            if (b.length == 0 || b.length > 16) return "TOKEN";
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                bool ok = (c >= "0" && c <= "9") || (c >= "A" && c <= "Z") || (c >= "a" && c <= "z");
                if (!ok) return "TOKEN";
            }
            return s;
        } catch {
            return "TOKEN";
        }
    }

    /// @dev A missing or silly `decimals()` falls back to 18 rather than breaking tokenURI.
    function _decimalsOf(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d > 36 ? 18 : d;
        } catch {
            return 18;
        }
    }
}
