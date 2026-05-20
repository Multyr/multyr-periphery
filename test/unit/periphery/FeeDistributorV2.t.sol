// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { FeeDistributorV2 } from "../../../src/periphery/rewards/FeeDistributorV2.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract FeeDistributorV2Test is Test {
    FeeDistributorV2 public dist;
    MockUSDC public usdc;
    address public epochPayout = address(0xEEEE);
    address public owner;

    uint32 public constant INITIAL_EPOCH = 1;
    uint256 public constant MAX_FUND = 100_000e6; // 100k USDC per epoch
    uint256 public constant MIN_DELAY = 1 hours;

    function setUp() public {
        owner = address(this);
        usdc = new MockUSDC();
        dist = new FeeDistributorV2(
            address(usdc), epochPayout, MAX_FUND, MIN_DELAY, INITIAL_EPOCH
        );
        // Warp past initial delay window so first fundEpochPayout() can execute
        // (lastFundTimestamp starts at 0; need block.timestamp >= minDelay)
        vm.warp(1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsState() public {
        assertEq(address(dist.ASSET()), address(usdc));
        assertEq(dist.epochPayout(), epochPayout);
        assertEq(dist.maxFundPerEpoch(), MAX_FUND);
        assertEq(dist.minDelayBetweenFunds(), MIN_DELAY);
        assertEq(dist.currentEpochId(), INITIAL_EPOCH);
    }

    function test_constructor_revertsOnZeroAsset() public {
        vm.expectRevert(FeeDistributorV2.ZeroAddress.selector);
        new FeeDistributorV2(address(0), epochPayout, MAX_FUND, MIN_DELAY, INITIAL_EPOCH);
    }

    function test_constructor_revertsOnZeroEpochPayout() public {
        vm.expectRevert(FeeDistributorV2.ZeroAddress.selector);
        new FeeDistributorV2(address(usdc), address(0), MAX_FUND, MIN_DELAY, INITIAL_EPOCH);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUND — amount specified
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fundEpochPayout_transfersAmount() public {
        usdc.mint(address(dist), 1000e6);
        dist.fundEpochPayout(INITIAL_EPOCH, 500e6);

        assertEq(usdc.balanceOf(epochPayout), 500e6);
        assertEq(usdc.balanceOf(address(dist)), 500e6); // residual stays
        assertEq(dist.fundedInEpoch(INITIAL_EPOCH), 500e6);
    }

    function test_fundEpochPayout_amountZeroSendsFullBalance() public {
        usdc.mint(address(dist), 1000e6);
        dist.fundEpochPayout(INITIAL_EPOCH, 0);

        assertEq(usdc.balanceOf(epochPayout), 1000e6);
        assertEq(usdc.balanceOf(address(dist)), 0);
    }

    function test_fundEpochPayout_amountExceedsBalanceClamped() public {
        usdc.mint(address(dist), 500e6);
        dist.fundEpochPayout(INITIAL_EPOCH, 1000e6); // requested > balance

        // Clamp to balance (not exceed cap since 500 < 100k)
        assertEq(usdc.balanceOf(epochPayout), 500e6);
    }

    function test_fundEpochPayout_revertsExceedsCap() public {
        usdc.mint(address(dist), 200_000e6);
        vm.expectRevert();
        dist.fundEpochPayout(INITIAL_EPOCH, 150_000e6); // > 100k cap
    }

    function test_fundEpochPayout_revertsOnDelayNotMet() public {
        usdc.mint(address(dist), 10_000e6);
        dist.fundEpochPayout(INITIAL_EPOCH, 1000e6);

        // Second call immediately should fail (no time warp)
        usdc.mint(address(dist), 1000e6);
        vm.expectRevert();
        dist.fundEpochPayout(INITIAL_EPOCH, 500e6);
    }

    function test_fundEpochPayout_worksAfterDelay() public {
        usdc.mint(address(dist), 10_000e6);
        dist.fundEpochPayout(INITIAL_EPOCH, 1000e6);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        dist.fundEpochPayout(INITIAL_EPOCH, 500e6);

        assertEq(usdc.balanceOf(epochPayout), 1500e6);
        assertEq(dist.fundedInEpoch(INITIAL_EPOCH), 1500e6);
    }

    function test_fundEpochPayout_revertsWhenFundingPaused() public {
        dist.pauseFunding(true);
        usdc.mint(address(dist), 1000e6);
        vm.expectRevert(FeeDistributorV2.FundingPaused.selector);
        dist.fundEpochPayout(INITIAL_EPOCH, 500e6);
    }

    function test_fundEpochPayout_zeroBalanceNoOp() public {
        dist.fundEpochPayout(INITIAL_EPOCH, 500e6);
        // No revert, nothing transferred
        assertEq(usdc.balanceOf(epochPayout), 0);
    }

    function test_fundEpochPayout_noAmount_sameCap() public {
        // no-amount variant: also respects the cap
        usdc.mint(address(dist), 200_000e6);
        vm.expectRevert();
        dist.fundEpochPayout(INITIAL_EPOCH);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EPOCH ADVANCE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_advanceEpoch_resetsCapImplicitly() public {
        usdc.mint(address(dist), 100_000e6);
        dist.fundEpochPayout(INITIAL_EPOCH, 100_000e6); // hit cap

        // New epoch resets fundedInEpoch[epoch] → cap available again
        dist.advanceEpoch(INITIAL_EPOCH + 1);
        assertEq(dist.currentEpochId(), INITIAL_EPOCH + 1);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        usdc.mint(address(dist), 50_000e6);
        dist.fundEpochPayout(INITIAL_EPOCH + 1, 50_000e6);
        assertEq(dist.fundedInEpoch(INITIAL_EPOCH + 1), 50_000e6);
    }

    function test_advanceEpoch_revertsNonMonotonic() public {
        vm.expectRevert();
        dist.advanceEpoch(INITIAL_EPOCH); // same
        vm.expectRevert();
        dist.advanceEpoch(INITIAL_EPOCH - 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWEEP
    // ═══════════════════════════════════════════════════════════════════════════

    function test_sweep_recoversUsdc() public {
        usdc.mint(address(dist), 1000e6);
        dist.sweep(address(usdc), owner);
        assertEq(usdc.balanceOf(owner), 1000e6);
    }

    function test_sweep_revertsOnZeroTo() public {
        usdc.mint(address(dist), 1000e6);
        vm.expectRevert(FeeDistributorV2.ZeroAddress.selector);
        dist.sweep(address(usdc), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setGuardrails_updates() public {
        dist.setGuardrails(50_000e6, 30 minutes);
        assertEq(dist.maxFundPerEpoch(), 50_000e6);
        assertEq(dist.minDelayBetweenFunds(), 30 minutes);
    }

    function test_setEpochPayout_updates() public {
        address newPayout = address(0xFACE);
        dist.setEpochPayout(newPayout);
        assertEq(dist.epochPayout(), newPayout);
    }

    function test_setEpochPayout_revertsZero() public {
        vm.expectRevert(FeeDistributorV2.ZeroAddress.selector);
        dist.setEpochPayout(address(0));
    }

    function test_setGuardrails_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        dist.setGuardrails(1, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_fundEpochPayout_respectsBalance(uint256 mintAmount, uint256 fundAmount) public {
        mintAmount = bound(mintAmount, 1, MAX_FUND);
        fundAmount = bound(fundAmount, 0, MAX_FUND);

        usdc.mint(address(dist), mintAmount);
        dist.fundEpochPayout(INITIAL_EPOCH, fundAmount);

        uint256 expected = fundAmount == 0 ? mintAmount : (fundAmount > mintAmount ? mintAmount : fundAmount);
        assertEq(usdc.balanceOf(epochPayout), expected);
        assertEq(usdc.balanceOf(address(dist)), mintAmount - expected);
    }
}
