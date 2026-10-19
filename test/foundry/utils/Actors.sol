// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A recipient whose native-value receive can be switched off, modelling a
///         blacklisted / non-payable counterparty (the native analogue of a USDC blacklist).
contract ToggleReceiver {
    bool public accept = true;
    uint256 public received;

    function setAccept(bool a) external {
        accept = a;
    }

    /// @notice Forward an arbitrary call (lets this contract act as client/provider/operator/validator).
    function exec(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {
        require(accept, "blacklisted");
        received += msg.value;
    }
}

/// @notice A recipient that tries to re-enter `target` with `data` when it receives value.
///         Records whether the re-entrant call succeeded; never reverts itself.
contract Reenterer {
    address public target;
    bytes public data;
    bool public reentered;
    bool public reentrySucceeded;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function exec(address t, uint256 value, bytes calldata d) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = t.call{value: value}(d);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {
        if (target != address(0) && !reentered) {
            reentered = true;
            (bool ok, ) = target.call(data);
            reentrySucceeded = ok;
        }
    }
}

/// @notice Force-sends native value via SELFDESTRUCT (still transfers balance under Cancun / EIP-6780).
contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}
