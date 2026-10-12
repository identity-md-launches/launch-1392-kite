// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Kite (KITE)
/// @notice A fixed-supply ERC-20 token. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`). There is no owner, no minter, no pause, no blocklist, no fee and no burn:
/// after construction the contract has no privileged functions at all, and the supply can never grow.
/// @dev Self-contained ERC-20 (EIP-20) with no external dependencies, so the launch deploys exactly
/// these bytes with no library linking. Transfers are plain balance moves: every flow delivers exactly
/// the amount requested, which the launch (factory -> distributor -> claimants, factory -> pool,
/// trader <-> pool) relies on.
contract KiteToken {
    /// @notice Emitted on every transfer, including the single mint in the constructor (`from` is zero).
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted when `owner` sets `spender`'s allowance to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice `account` (`msg.sender` for transfer/approve, `from` for transferFrom) is the zero address.
    error InvalidSender(address account);
    /// @notice The recipient of a transfer is the zero address.
    error InvalidReceiver(address receiver);
    /// @notice The spender being approved is the zero address.
    error InvalidSpender(address spender);
    /// @notice `sender` holds `balance` but `needed` was requested.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @notice `spender` is allowed `allowance` by the owner but `needed` was requested.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    string public constant name = "Kite";
    string public constant symbol = "KITE";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 KITE in minor units (18 decimals). Fixed forever.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    /// @notice Mints the entire supply to the deployer. Takes no arguments and calls no other contract.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Total number of tokens in existence. Constant: nothing can mint or burn.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Remaining number of tokens `spender` may move on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Moves `amount` from the caller to `to`. Reverts rather than returning false on failure.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `amount` (overwrites, does not add).
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance. An allowance of
    /// `type(uint256).max` is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert InvalidSender(address(0));
        if (to == address(0)) revert InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount was just checked; the sum of all balances is TOTAL_SUPPLY < 2**256.
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0)) revert InvalidSender(address(0));
        if (spender == address(0)) revert InvalidSpender(address(0));
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
