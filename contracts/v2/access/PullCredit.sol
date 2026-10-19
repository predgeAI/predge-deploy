// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  PullCredit
/// @notice Pull-payment ledger shared by the Predge v2 contracts. Whoever is owed value is
///         credited here and withdraws it themselves, so a recipient that reverts or is
///         blocklisted can never force an outcome or lock anybody else's funds.
/// @dev    `totalCredit` is the sum of all outstanding credits; the inheriting contract's native
///         balance is always at least `totalCredit` plus whatever it still escrows or bonds.
///         Checks-effects-interactions: the credit is zeroed and the event emitted before the call.
abstract contract PullCredit {
    /// @notice Withdrawable balance per account.
    mapping(address => uint256) public credit;
    /// @notice Sum of all credits not yet withdrawn.
    uint256 public totalCredit;

    event Withdrawn(address indexed account, address indexed to, uint256 amount);

    error NothingToWithdraw();
    error TransferFailed();
    error ZeroRecipient();

    /// @notice Withdraw the caller's whole credit to the caller.
    function withdraw() external {
        _withdraw(payable(msg.sender));
    }

    /// @notice Withdraw the caller's whole credit to `to`, e.g. when the caller's own address
    ///         cannot receive value (blocklisted or a contract without a receive function).
    function withdrawTo(address payable to) external {
        if (to == address(0)) revert ZeroRecipient();
        _withdraw(to);
    }

    function _addCredit(address to, uint256 amount) internal {
        credit[to] += amount;
        totalCredit += amount;
    }

    function _withdraw(address payable to) private {
        uint256 amt = credit[msg.sender];
        if (amt == 0) revert NothingToWithdraw();
        credit[msg.sender] = 0;
        totalCredit -= amt;
        emit Withdrawn(msg.sender, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }
}
