// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice TEST / DEMO ONLY. Predge's own re-implementation of the behaviour of Circle's Refund
///         Protocol that the adapter depends on, written from the public interface and behaviour
///         described in `ICircleRefundProtocol`. It is NOT Circle's code and is not audited.
///         Same function names, argument order, getter layout and error names as Circle's contract,
///         so the adapter and tests exercise the real call shapes. Left out: EIP-712
///         `earlyWithdrawByArbiter` (not used by Predge) and recipient debt bookkeeping beyond the
///         arbiter-funds fallback.
interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockCircleRefundProtocol {
    struct Payment {
        address to;
        uint256 amount;
        uint256 releaseTimestamp;
        address refundTo;
        uint256 withdrawnAmount;
        bool refunded;
    }

    uint256 public constant MAX_LOCKUP_SECONDS = 180 days;

    address public immutable arbiter;
    address public immutable fiatToken;
    uint256 public nonce;

    mapping(address => uint256) public lockupSeconds;
    mapping(uint256 => Payment) public payments;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public debts;

    event PaymentCreated(uint256 indexed paymentID, address indexed to, uint256 amount, uint256 releaseTimestamp, address indexed refundTo);
    event Refund(uint256 indexed paymentID, address indexed refundTo, uint256 amount);
    event RefundToUpdated(uint256 indexed paymentID, address indexed oldRefundTo, address indexed newRefundTo);
    event Withdrawal(address indexed to, uint256 amount);

    error CallerNotAllowed();
    error PaymentIsStillLocked(uint256 paymentID);
    error RefundToIsZeroAddress();
    error InsufficientFunds();
    error PaymentRefunded(uint256 paymentID);
    error LockupSecondsExceedsMax();

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert CallerNotAllowed();
        _;
    }

    constructor(address arbiter_, address token_) {
        arbiter = arbiter_;
        fiatToken = token_;
    }

    function pay(address to, uint256 amount, address refundTo) external {
        if (refundTo == address(0)) revert RefundToIsZeroAddress();
        uint256 release = block.timestamp + lockupSeconds[to];
        require(IERC20Min(fiatToken).transferFrom(msg.sender, address(this), amount), "transferFrom");
        uint256 id = nonce++;
        payments[id] = Payment(to, amount, release, refundTo, 0, false);
        balances[to] += amount;
        emit PaymentCreated(id, to, amount, release, refundTo);
    }

    function refundByRecipient(uint256 paymentID) external {
        Payment storage p = payments[paymentID];
        if (msg.sender != p.to) revert CallerNotAllowed();
        if (balances[p.to] < p.amount) revert InsufficientFunds();
        balances[p.to] -= p.amount;
        _refund(paymentID, p);
    }

    /// @dev Like Circle's: no release-time check; paid from the recipient's balance, else from the
    ///      arbiter's deposited balance (which then becomes the recipient's debt).
    function refundByArbiter(uint256 paymentID) external onlyArbiter {
        Payment storage p = payments[paymentID];
        if (balances[p.to] >= p.amount) {
            balances[p.to] -= p.amount;
        } else {
            if (balances[arbiter] < p.amount) revert InsufficientFunds();
            balances[arbiter] -= p.amount;
            debts[p.to] += p.amount;
        }
        _refund(paymentID, p);
    }

    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external onlyArbiter {
        if (recipientLockupSeconds > MAX_LOCKUP_SECONDS) revert LockupSecondsExceedsMax();
        lockupSeconds[recipient] = recipientLockupSeconds;
    }

    function depositArbiterFunds(uint256 amount) external onlyArbiter {
        require(IERC20Min(fiatToken).transferFrom(msg.sender, address(this), amount), "transferFrom");
        balances[arbiter] += amount;
    }

    function withdrawArbiterFunds(uint256 amount) external onlyArbiter {
        if (balances[arbiter] < amount) revert InsufficientFunds();
        balances[arbiter] -= amount;
        require(IERC20Min(fiatToken).transfer(arbiter, amount), "transfer");
    }

    function withdraw(uint256[] calldata paymentIDs) external {
        uint256 total;
        for (uint256 i; i < paymentIDs.length; ++i) {
            Payment storage p = payments[paymentIDs[i]];
            if (p.to != msg.sender) revert CallerNotAllowed();
            if (block.timestamp < p.releaseTimestamp) revert PaymentIsStillLocked(paymentIDs[i]);
            if (p.refunded) revert PaymentRefunded(paymentIDs[i]);
            total += p.amount - p.withdrawnAmount;
            p.withdrawnAmount = p.amount;
        }
        if (balances[msg.sender] < total) revert InsufficientFunds();
        balances[msg.sender] -= total;
        require(IERC20Min(fiatToken).transfer(msg.sender, total), "transfer");
        emit Withdrawal(msg.sender, total);
    }

    function updateRefundTo(uint256 paymentID, address newRefundTo) external {
        if (newRefundTo == address(0)) revert RefundToIsZeroAddress();
        Payment storage p = payments[paymentID];
        if (msg.sender != p.refundTo) revert CallerNotAllowed();
        emit RefundToUpdated(paymentID, p.refundTo, newRefundTo);
        p.refundTo = newRefundTo;
    }

    function _refund(uint256 paymentID, Payment storage p) private {
        if (p.refunded) revert PaymentRefunded(paymentID);
        p.refunded = true;
        require(IERC20Min(fiatToken).transfer(p.refundTo, p.amount), "transfer");
        emit Refund(paymentID, p.refundTo, p.amount);
    }
}
