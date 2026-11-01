// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Owned2Step
/// @notice Minimal two-step ownership, the same hand-over model as OpenZeppelin v5 `Ownable2Step`.
///         The owner is passed to the constructor (the intended owner is a Safe multisig), so the
///         deployer key never holds a role. There is deliberately NO `renounceOwnership`: a
///         renounced owner could never rotate a compromised operator or resolve a dispute.
/// @dev    Two steps: `transferOwnership(next)` nominates, `acceptOwnership()` (called by `next`)
///         completes. Nominating `address(0)` cancels a pending nomination. A wrong address can
///         therefore never take ownership, because it has to prove it can sign.
abstract contract Owned2Step {
    /// @notice Current owner. Config and dispute resolution only; never moves user funds.
    address public owner;
    /// @notice Nominated owner, or zero.
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param owner_ initial owner; must not be zero.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Nominate `newOwner`. Passing `address(0)` cancels a pending nomination.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete the hand-over. Only the nominated address can call this.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}

/// @title  Operated
/// @notice Adds the hot "operator" role (the day-to-day validator / arbiter key) under an
///         `Owned2Step` owner. The owner can rotate the operator; the operator can never touch
///         ownership or configuration.
/// @dev    Rotation is not retroactive by design: the contracts that pay out snapshot the staker
///         address on each stake or ruling, so rotating this key never lets a new key take an old
///         key's bond, and never strands the bond either. It can strand an in-flight VERDICT
///         (Olympix 5.3.8): a Committed stake in `PredgeValidatorBondV2` can only be scored by the new
///         key if it is given the old commitment's `(expected, salt)`. If it is not, the job times out,
///         the client is refunded and the bond is forfeited to the provider. Rotate with no stake in
///         flight, or hand the preimages over, unless the old key is compromised.
abstract contract Operated is Owned2Step {
    /// @notice The hot operations key. Rotatable by the owner.
    address public operator;

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    error NotOperator();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @param owner_    initial owner (Safe); must not be zero.
    /// @param operator_ initial operator; must not be zero.
    constructor(address owner_, address operator_) Owned2Step(owner_) {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorUpdated(address(0), operator_);
    }

    /// @notice Rotate the operator key. Owner only; the new key must be non-zero.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }
}
