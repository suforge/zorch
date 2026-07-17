// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title FairLaunchToken
/// @notice A deliberately minimal, standard ERC-20 for fair-launch memecoins.
///
/// Fairness / no-rug properties, enforced structurally by *what this contract
/// does not have*:
///   - No owner / admin. Nothing is `onlyOwner`; there is nothing to renounce
///     because no privileged role is ever created.
///   - No mint, ever. Supply is minted once at construction to `recipient` (the
///     factory, which seeds it into a permanently-locked single-sided LP) and can
///     only ever DECREASE, via the permissionless `burn` (holders burning their
///     own). There is no path that increases supply. Nobody is pre-allocated
///     tokens; the only way to obtain them is to buy from the pool.
///   - No transfer hook, no transfer tax, no max-wallet, no blacklist, no pause.
///     Transfers are the plain ERC-20 semantics — so this token can never be a
///     honeypot and passes honeypot scanners cleanly. (Sniper protection is
///     intentionally omitted: Robinhood Chain's sequencer is FCFS with no public
///     mempool, so there is no priority-fee sniping meta to defend against, and
///     any transfer-path restriction would make this a non-standard token.)
///
/// This is a reference implementation. It is dependency-free so it can be
/// audited in isolation.
contract FairLaunchToken {
    // --- ERC-20 metadata ---
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    // --- Off-chain-display metadata (the Robinhood Chain launchpad convention,
    //     read by terminals like GMGN). These are plain view strings set once at
    //     deploy; they add no transfer logic, so the token stays a plain ERC-20.
    //     `logo` is an IPFS URI to the avatar image; `socials` is a single
    //     community URL (the Robinhood Chain convention — e.g. a Twitter/X link).
    string public logo;
    string public description;
    string public socials;

    // --- ERC-20 state ---
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- ERC-20 events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @param _name        token name
    /// @param _symbol      token symbol
    /// @param _supply      fixed total supply (18 decimals), minted once
    /// @param _recipient   receives the entire supply (the launch factory)
    /// @param _logo        IPFS URI of the avatar image (may be empty)
    /// @param _description short text description (may be empty)
    /// @param _socials     community links (may be empty)
    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _supply,
        address _recipient,
        string memory _logo,
        string memory _description,
        string memory _socials
    ) {
        require(_recipient != address(0), "recipient=0");
        require(_supply > 0, "supply=0");
        name = _name;
        symbol = _symbol;
        logo = _logo;
        description = _description;
        socials = _socials;
        totalSupply = _supply;
        balanceOf[_recipient] = _supply;
        emit Transfer(address(0), _recipient, _supply);
    }

    /// @notice Always the zero address: this token has no owner and no privileged
    ///         roles at all. Exposed so safety scanners / wallet UIs read it as
    ///         "ownership renounced" (a green check) rather than "unknown owner".
    function owner() external pure returns (address) {
        return address(0);
    }

    // --- ERC-20 logic (standard) ---

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "insufficient allowance");
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice Burn `value` tokens from the caller, permanently reducing
    ///         totalSupply. This is a REAL deflationary burn (supply drops), used
    ///         by the buyback engine to destroy repurchased $ZORCH — not a soft
    ///         "send to a dead address". Permissionless: you can only burn your own.
    function burn(uint256 value) external {
        uint256 bal = balanceOf[msg.sender];
        require(bal >= value, "insufficient balance");
        unchecked {
            balanceOf[msg.sender] = bal - value;
            totalSupply -= value;
        }
        emit Transfer(msg.sender, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "transfer to 0");
        uint256 bal = balanceOf[from];
        require(bal >= value, "insufficient balance");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
