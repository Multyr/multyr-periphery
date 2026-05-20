// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PartnerRegistry } from "../partner/PartnerRegistry.sol";
import { ReferralBinding } from "../referral/ReferralBinding.sol";

/// @title AttributionResolver — View-only on-chain attribution
/// @notice Resolves WHO gets attributed for a depositor's activity.
///         Does NOT resolve HOW MUCH — amount computation stays off-chain (build_epoch.ts).
/// @dev    Priority: PARTNER > REFERRAL > NONE
///         Matches scripts/epoch/lib/attribution.ts logic exactly.
contract AttributionResolver {

    enum Category { NONE, PARTNER, REFERRAL }

    PartnerRegistry public immutable partnerRegistry;
    ReferralBinding public immutable referralBinding;

    constructor(address partnerRegistry_, address referralBinding_) {
        require(partnerRegistry_ != address(0), "partnerRegistry=0");
        require(referralBinding_ != address(0), "referralBinding=0");
        partnerRegistry = PartnerRegistry(partnerRegistry_);
        referralBinding = ReferralBinding(referralBinding_);
    }

    /// @notice Resolve attribution for a depositor
    /// @param depositor The address to resolve
    /// @return category PARTNER, REFERRAL, or NONE
    /// @return beneficiary Who receives rewards (partner.recipient or referrer)
    function resolve(address depositor) external view returns (
        Category category,
        address beneficiary
    ) {
        // Priority 1: Partner — active depositor is a partner
        if (partnerRegistry.isActivePartner(depositor)) {
            (,,,,address recipient) = partnerRegistry.partners(depositor);
            return (Category.PARTNER, recipient);
        }

        // Priority 2: Referral — depositor has a bound referrer
        address referrer = referralBinding.referrerOf(depositor);
        if (referrer != address(0)) {
            return (Category.REFERRAL, referrer);
        }

        // Priority 3: None — organic, no attribution
        return (Category.NONE, address(0));
    }

    /// @notice Batch resolve for multiple depositors
    /// @param depositors Array of addresses to resolve
    /// @return categories Array of categories
    /// @return beneficiaries Array of beneficiary addresses
    function resolveBatch(address[] calldata depositors) external view returns (
        Category[] memory categories,
        address[] memory beneficiaries
    ) {
        uint256 len = depositors.length;
        categories = new Category[](len);
        beneficiaries = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            (categories[i], beneficiaries[i]) = this.resolve(depositors[i]);
        }
    }
}
