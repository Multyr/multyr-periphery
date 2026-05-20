// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { PartnerRegistry } from "../../../src/periphery/partner/PartnerRegistry.sol";

contract PartnerRegistryTest is Test {
    PartnerRegistry public registry;

    address public owner;
    address public nonOwner;
    address public partnerAddr;
    address public recipient;

    event PartnerRegistered(address indexed partner, PartnerRegistry.PartnerTerms terms);
    event PartnerUpdated(address indexed partner, PartnerRegistry.PartnerTerms terms);
    event PartnerDisabled(address indexed partner);

    function setUp() public {
        owner = address(this);
        nonOwner = makeAddr("nonOwner");
        partnerAddr = makeAddr("partner");
        recipient = makeAddr("recipient");

        registry = new PartnerRegistry();
    }

    // ─── helpers ─────────────────────────────────────────────────────────────────

    function _defaultTerms() internal view returns (PartnerRegistry.PartnerTerms memory) {
        return PartnerRegistry.PartnerTerms({
            enabled: true,
            bps: 500, // 5 %
            capPerEpoch: 1_000e6,
            expiry: 0, // never expires
            recipient: recipient
        });
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // setPartner
    // ═════════════════════════════════════════════════════════════════════════════

    function test_setPartner_createsNew() public {
        PartnerRegistry.PartnerTerms memory terms = _defaultTerms();

        vm.expectEmit(true, false, false, true);
        emit PartnerRegistered(partnerAddr, terms);

        registry.setPartner(partnerAddr, terms);

        PartnerRegistry.PartnerTerms memory stored = registry.getPartner(partnerAddr);
        assertEq(stored.enabled, true);
        assertEq(stored.bps, 500);
        assertEq(stored.capPerEpoch, 1_000e6);
        assertEq(stored.expiry, 0);
        assertEq(stored.recipient, recipient);
        assertEq(registry.getPartnerCount(), 1);
    }

    function test_setPartner_updatesExisting() public {
        PartnerRegistry.PartnerTerms memory terms = _defaultTerms();
        registry.setPartner(partnerAddr, terms);

        // Update bps and cap
        PartnerRegistry.PartnerTerms memory updated = PartnerRegistry.PartnerTerms({
            enabled: true,
            bps: 1_000, // 10 %
            capPerEpoch: 5_000e6,
            expiry: 0,
            recipient: recipient
        });

        vm.expectEmit(true, false, false, true);
        emit PartnerUpdated(partnerAddr, updated);

        registry.setPartner(partnerAddr, updated);

        PartnerRegistry.PartnerTerms memory stored = registry.getPartner(partnerAddr);
        assertEq(stored.bps, 1_000);
        assertEq(stored.capPerEpoch, 5_000e6);
        // Count should not increase on update
        assertEq(registry.getPartnerCount(), 1);
    }

    function test_setPartner_revertsForNonOwner() public {
        PartnerRegistry.PartnerTerms memory terms = _defaultTerms();

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setPartner(partnerAddr, terms);
    }

    function test_setPartner_revertsOnZeroPartnerAddress() public {
        PartnerRegistry.PartnerTerms memory terms = _defaultTerms();

        vm.expectRevert(PartnerRegistry.ZeroAddress.selector);
        registry.setPartner(address(0), terms);
    }

    function test_setPartner_revertsOnZeroRecipient() public {
        PartnerRegistry.PartnerTerms memory terms = PartnerRegistry.PartnerTerms({
            enabled: true, bps: 500, capPerEpoch: 1_000e6, expiry: 0, recipient: address(0)
        });

        vm.expectRevert(PartnerRegistry.ZeroAddress.selector);
        registry.setPartner(partnerAddr, terms);
    }

    function test_setPartner_revertsOnBpsTooHigh() public {
        PartnerRegistry.PartnerTerms memory terms = PartnerRegistry.PartnerTerms({
            enabled: true, bps: 10_001, capPerEpoch: 1_000e6, expiry: 0, recipient: recipient
        });

        vm.expectRevert(abi.encodeWithSelector(PartnerRegistry.BpsTooHigh.selector, uint16(10_001)));
        registry.setPartner(partnerAddr, terms);
    }

    function test_setPartner_bpsAtBoundary() public {
        // 10_000 bps (100 %) should succeed
        PartnerRegistry.PartnerTerms memory terms = PartnerRegistry.PartnerTerms({
            enabled: true, bps: 10_000, capPerEpoch: 1_000e6, expiry: 0, recipient: recipient
        });

        registry.setPartner(partnerAddr, terms);
        assertEq(registry.getPartner(partnerAddr).bps, 10_000);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // disablePartner
    // ═════════════════════════════════════════════════════════════════════════════

    function test_disablePartner_setsEnabledToFalse() public {
        registry.setPartner(partnerAddr, _defaultTerms());
        assertTrue(registry.isActivePartner(partnerAddr));

        vm.expectEmit(true, false, false, false);
        emit PartnerDisabled(partnerAddr);

        registry.disablePartner(partnerAddr);
        assertFalse(registry.isActivePartner(partnerAddr));
    }

    function test_disablePartner_revertsForNonOwner() public {
        registry.setPartner(partnerAddr, _defaultTerms());

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.disablePartner(partnerAddr);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // isActivePartner
    // ═════════════════════════════════════════════════════════════════════════════

    function test_isActivePartner_enabledNoExpiry() public {
        registry.setPartner(partnerAddr, _defaultTerms());
        assertTrue(registry.isActivePartner(partnerAddr));
    }

    function test_isActivePartner_disabledReturnsFalse() public {
        registry.setPartner(partnerAddr, _defaultTerms());
        registry.disablePartner(partnerAddr);
        assertFalse(registry.isActivePartner(partnerAddr));
    }

    function test_isActivePartner_expiredReturnsFalse() public {
        PartnerRegistry.PartnerTerms memory terms = PartnerRegistry.PartnerTerms({
            enabled: true,
            bps: 500,
            capPerEpoch: 1_000e6,
            expiry: uint64(block.timestamp + 100),
            recipient: recipient
        });
        registry.setPartner(partnerAddr, terms);

        // Still active before expiry
        assertTrue(registry.isActivePartner(partnerAddr));

        // Warp past expiry
        vm.warp(block.timestamp + 101);
        assertFalse(registry.isActivePartner(partnerAddr));
    }

    function test_isActivePartner_unknownAddressReturnsFalse() public view {
        assertFalse(registry.isActivePartner(address(0xdead)));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // getPartnerCount
    // ═════════════════════════════════════════════════════════════════════════════

    function test_getPartnerCount_incrementsOnNewPartners() public {
        assertEq(registry.getPartnerCount(), 0);

        registry.setPartner(partnerAddr, _defaultTerms());
        assertEq(registry.getPartnerCount(), 1);

        address partner2 = makeAddr("partner2");
        PartnerRegistry.PartnerTerms memory terms2 = _defaultTerms();
        terms2.recipient = makeAddr("recipient2");
        registry.setPartner(partner2, terms2);
        assertEq(registry.getPartnerCount(), 2);

        // Re-setting existing partner does not increment count
        registry.setPartner(partnerAddr, _defaultTerms());
        assertEq(registry.getPartnerCount(), 2);
    }
}
