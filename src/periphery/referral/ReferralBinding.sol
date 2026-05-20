// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ReferralBinding
/// @notice Set-once mapping of user → referrer, used for reward attribution
/// @dev No admin for bind() — users can self-bind.
///      bindFor() is restricted to authorized routers (e.g., DepositRouter).
///      governance (immutable) = timelock, manages router authorization.
contract ReferralBinding {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error AlreadyBound();
    error SelfReferral();
    error ZeroAddress();
    error NotAuthorizedRouter();
    error NotGovernance();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event ReferralBound(address indexed user, address indexed referrer);
    event RouterAuthorizationUpdated(address indexed router, bool authorized);

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(address => address) public referrerOf;
    mapping(address => bool) public authorizedRouter;
    address public immutable governance;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address governance_) {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bind msg.sender to a referrer (set-once, irreversible)
    function bind(address referrer) external {
        _bind(msg.sender, referrer);
    }

    /// @notice Bind a user to a referrer (called by authorized routers)
    function bindFor(address user, address referrer) external {
        if (!authorizedRouter[msg.sender]) revert NotAuthorizedRouter();
        _bind(user, referrer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Authorize or deauthorize a router for bindFor()
    function setRouter(address router, bool authorized) external {
        if (msg.sender != governance) revert NotGovernance();
        if (router == address(0)) revert ZeroAddress();
        authorizedRouter[router] = authorized;
        emit RouterAuthorizationUpdated(router, authorized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Check if a user has a referrer bound
    function isBound(address user) external view returns (bool) {
        return referrerOf[user] != address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _bind(address user, address referrer) internal {
        if (referrer == address(0)) revert ZeroAddress();
        if (user == referrer) revert SelfReferral();
        if (referrerOf[user] != address(0)) revert AlreadyBound();

        referrerOf[user] = referrer;
        emit ReferralBound(user, referrer);
    }
}
