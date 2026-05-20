// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { ReferralBinding } from "../../../src/periphery/referral/ReferralBinding.sol";

/// @title ReferralBindingTest
/// @notice Unit tests for the ReferralBinding periphery contract
///
/// Tests cover:
/// 1. bind() happy path, self-referral revert, zero revert, already bound revert
/// 2. bindFor() authorized router, unauthorized revert
/// 3. setRouter() governance access, not-governance revert
/// 4. isBound() view correctness
contract ReferralBindingTest is Test {
    ReferralBinding public binding;

    address public governance = address(0xAAA1);
    address public router = address(0xBBB2);
    address public user = address(0xCCC3);
    address public referrer = address(0xDDD4);

    function setUp() public {
        binding = new ReferralBinding(governance);

        // Authorize the router for bindFor tests
        vm.prank(governance);
        binding.setRouter(router, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsGovernance() public {
        assertEq(binding.governance(), governance);
    }

    function test_constructor_revertsOnZeroGovernance() public {
        vm.expectRevert(ReferralBinding.ZeroAddress.selector);
        new ReferralBinding(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. bind()
    // ═══════════════════════════════════════════════════════════════════════════

    function test_bind_happyPath() public {
        vm.prank(user);
        binding.bind(referrer);

        assertEq(binding.referrerOf(user), referrer);
        assertTrue(binding.isBound(user));
    }

    function test_bind_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ReferralBinding.ReferralBound(user, referrer);

        vm.prank(user);
        binding.bind(referrer);
    }

    function test_bind_revertsOnSelfReferral() public {
        vm.prank(user);
        vm.expectRevert(ReferralBinding.SelfReferral.selector);
        binding.bind(user);
    }

    function test_bind_revertsOnZeroReferrer() public {
        vm.prank(user);
        vm.expectRevert(ReferralBinding.ZeroAddress.selector);
        binding.bind(address(0));
    }

    function test_bind_revertsWhenAlreadyBound() public {
        vm.prank(user);
        binding.bind(referrer);

        // Second bind should revert
        vm.prank(user);
        vm.expectRevert(ReferralBinding.AlreadyBound.selector);
        binding.bind(address(0x9999));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. bindFor()
    // ═══════════════════════════════════════════════════════════════════════════

    function test_bindFor_authorizedRouter() public {
        vm.prank(router);
        binding.bindFor(user, referrer);

        assertEq(binding.referrerOf(user), referrer);
        assertTrue(binding.isBound(user));
    }

    function test_bindFor_revertsUnauthorizedRouter() public {
        address unauthorized = address(0xBAD);

        vm.prank(unauthorized);
        vm.expectRevert(ReferralBinding.NotAuthorizedRouter.selector);
        binding.bindFor(user, referrer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. setRouter()
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setRouter_onlyGovernance() public {
        address newRouter = address(0xEEE5);

        vm.prank(governance);
        binding.setRouter(newRouter, true);

        assertTrue(binding.authorizedRouter(newRouter));
    }

    function test_setRouter_canDeauthorize() public {
        assertTrue(binding.authorizedRouter(router));

        vm.prank(governance);
        binding.setRouter(router, false);

        assertFalse(binding.authorizedRouter(router));
    }

    function test_setRouter_revertsNotGovernance() public {
        address random = address(0xDEAD);

        vm.prank(random);
        vm.expectRevert(ReferralBinding.NotGovernance.selector);
        binding.setRouter(address(0xEEE5), true);
    }

    function test_setRouter_revertsOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(ReferralBinding.ZeroAddress.selector);
        binding.setRouter(address(0), true);
    }

    function test_setRouter_emitsEvent() public {
        address newRouter = address(0xEEE5);

        vm.expectEmit(true, false, false, true);
        emit ReferralBinding.RouterAuthorizationUpdated(newRouter, true);

        vm.prank(governance);
        binding.setRouter(newRouter, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. isBound()
    // ═══════════════════════════════════════════════════════════════════════════

    function test_isBound_falseForUnbound() public {
        assertFalse(binding.isBound(user));
    }

    function test_isBound_trueAfterBind() public {
        vm.prank(user);
        binding.bind(referrer);

        assertTrue(binding.isBound(user));
    }
}
