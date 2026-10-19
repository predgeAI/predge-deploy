// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal standard ERC20 (returns bool).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external virtual returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external virtual returns (bool) {
        _spend(from, amt);
        _move(from, to, amt);
        return true;
    }

    function _spend(address from, uint256 amt) internal {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
    }

    function _move(address from, address to, uint256 amt) internal virtual {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
    }
}

/// @notice Fee-on-transfer token: burns `feeBps` of every transfer.
contract FeeOnTransferToken is MockERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) MockERC20("Fee", "FEE", 18) {
        feeBps = feeBps_;
    }

    function _move(address from, address to, uint256 amt) internal override {
        uint256 fee = (amt * feeBps) / 10_000;
        balanceOf[from] -= amt;
        balanceOf[to] += amt - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amt - fee);
    }
}

/// @notice USDT-style token whose transfer/transferFrom return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }
}

/// @notice USDC-like token: 6 decimals, admin blacklist on sender and recipient.
contract BlacklistUSDC is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor() MockERC20("USD Coin", "USDC", 6) {}

    function blacklist(address a, bool b) external {
        blacklisted[a] = b;
    }

    function _move(address from, address to, uint256 amt) internal override {
        require(!blacklisted[from] && !blacklisted[to], "Blacklistable: account is blacklisted");
        super._move(from, to, amt);
    }
}
