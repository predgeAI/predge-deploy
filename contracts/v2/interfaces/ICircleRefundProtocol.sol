// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Circle's Refund Protocol (github.com/circlefin/refund-protocol,
///         src/RefundProtocol.sol, read 01.11.2026) that Predge touches. Written by Predge from the
///         public function signatures; no Circle code is copied or imported. Only signatures are
///         declared, so this file carries no Circle implementation.
///
///         Facts about the real contract that shape the adapter (all from reading its source):
///         - `arbiter` is set once in the constructor; there is no setter. Every arbiter-only call
///           (`refundByArbiter`, `setLockupSeconds`, `earlyWithdrawByArbiter`, `depositArbiterFunds`,
///           `withdrawArbiterFunds`) checks `msg.sender == arbiter`.
///         - There is no `paymentInfo`; the public `payments(id)` getter returns the struct fields
///           `(to, amount, releaseTimestamp, refundTo, withdrawnAmount, refunded)`. The address that
///           called `pay` is NOT stored: the party a refund goes to is `refundTo`, which the current
///           `refundTo` may change at any time with `updateRefundTo`.
///         - `amount` is in the ERC-20's own units (USDC: 6 decimals).
///         - `refundByArbiter` does not check `releaseTimestamp`; it reverts `PaymentRefunded` if the
///           payment was already refunded, and `InsufficientFunds` if neither the recipient's balance
///           nor the arbiter's own deposited balance covers the amount.
///         - `setLockupSeconds` reverts above `MAX_LOCKUP_SECONDS` (180 days).
///         - Payment ids start at 0 (`nonce` starts at 0).
interface ICircleRefundProtocol {
    function arbiter() external view returns (address);
    function fiatToken() external view returns (address);
    function nonce() external view returns (uint256);
    function MAX_LOCKUP_SECONDS() external view returns (uint256);
    function lockupSeconds(address recipient) external view returns (uint256);
    function balances(address account) external view returns (uint256);
    function debts(address recipient) external view returns (uint256);

    function payments(uint256 paymentID)
        external
        view
        returns (
            address to,
            uint256 amount,
            uint256 releaseTimestamp,
            address refundTo,
            uint256 withdrawnAmount,
            bool refunded
        );

    function pay(address to, uint256 amount, address refundTo) external;
    function withdraw(uint256[] calldata paymentIDs) external;
    function refundByRecipient(uint256 paymentID) external;
    function updateRefundTo(uint256 paymentID, address newRefundTo) external;

    // arbiter-only
    function refundByArbiter(uint256 paymentID) external;
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external;
    function depositArbiterFunds(uint256 amount) external;
    function withdrawArbiterFunds(uint256 amount) external;
}
