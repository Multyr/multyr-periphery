// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PartnerRegistry
/// @notice Governance-managed registry of partner terms for reward attribution
/// @dev Off-chain epoch script reads partner terms to compute reward allocations.
///      partnerList is append-only (never pruned). Expected count: <100.
contract PartnerRegistry is Ownable2Step {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct PartnerTerms {
        bool enabled;
        uint16 bps; // reward bps (e.g. 500 = 5%)
        uint256 capPerEpoch; // max USDC per epoch (6 decimals)
        uint64 expiry; // unix timestamp, 0 = never expires
        address recipient; // receives partner rewards
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error BpsTooHigh(uint16 bps);

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event PartnerRegistered(address indexed partner, PartnerTerms terms);
    event PartnerUpdated(address indexed partner, PartnerTerms terms);
    event PartnerDisabled(address indexed partner);

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(address => PartnerTerms) public partners;
    address[] public partnerList;
    mapping(address => bool) private _isInList;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() Ownable() { }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Register or update a partner's terms
    function setPartner(address partner, PartnerTerms calldata terms) external onlyOwner {
        if (partner == address(0)) revert ZeroAddress();
        if (terms.recipient == address(0)) revert ZeroAddress();
        if (terms.bps > 10_000) revert BpsTooHigh(terms.bps);

        bool isNew = !_isInList[partner];
        partners[partner] = terms;

        if (isNew) {
            partnerList.push(partner);
            _isInList[partner] = true;
            emit PartnerRegistered(partner, terms);
        } else {
            emit PartnerUpdated(partner, terms);
        }
    }

    /// @notice Disable a partner (does not remove from partnerList)
    function disablePartner(address partner) external onlyOwner {
        partners[partner].enabled = false;
        emit PartnerDisabled(partner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Check if a partner is currently active
    function isActivePartner(address partner) external view returns (bool) {
        PartnerTerms storage t = partners[partner];
        return t.enabled && (t.expiry == 0 || block.timestamp < t.expiry);
    }

    /// @notice Get full partner terms
    function getPartner(address partner) external view returns (PartnerTerms memory) {
        return partners[partner];
    }

    /// @notice Get total number of partners ever registered
    function getPartnerCount() external view returns (uint256) {
        return partnerList.length;
    }
}
