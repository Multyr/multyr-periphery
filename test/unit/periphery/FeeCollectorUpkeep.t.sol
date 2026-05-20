// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    FeeCollectorUpkeep,
    IFeeCollectorForUpkeep
} from "../../../src/periphery/automation/FeeCollectorUpkeep.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ═════════════════════════════════════════════════════════════════════════════
// MOCKS
// ═════════════════════════════════════════════════════════════════════════════

contract MockERC20Minimal is IERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockFeeCollector {
    bool public shouldRevert;
    uint256 public distributeCallCount;
    address public lastDistributeToken;

    function distribute(address token) external {
        if (shouldRevert) revert("FeeCollector: paused");
        distributeCallCount++;
        lastDistributeToken = token;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// TESTS
// ═════════════════════════════════════════════════════════════════════════════

/// @title FeeCollectorUpkeepTest
/// @notice Unit tests for FeeCollectorUpkeep automation contract.
///
/// Coverage:
/// 1. Constructor validation (zero address, immutables, ownership transfer)
/// 2. Admin: addToken, removeToken, setInterval, getTokens
/// 3. checkUpkeep: no tokens, cooldown, balance checks, multi-token priority
/// 4. performUpkeep: execution, event emission, lastDistributeTs update
/// 5. CTO safe-idempotent: unknown token, cooldown, balance drained
/// 6. distribute revert → DistributionFailed (no upkeep revert)
/// 7. onlyOwner guards
contract FeeCollectorUpkeepTest is Test {
    FeeCollectorUpkeep public upkeep;
    MockFeeCollector public mockFC;
    MockERC20Minimal public shareToken;
    MockERC20Minimal public otherToken;

    address owner = address(0xBEEF);
    uint64 constant INTERVAL = 259_200; // 3 days
    uint256 constant SHARES = 1000e6;

    event IntervalUpdated(uint64 oldInterval, uint64 newInterval);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event DistributionTriggered(address indexed token, uint256 timestamp);
    event DistributionFailed(address indexed token, bytes reason);

    function setUp() public {
        mockFC = new MockFeeCollector();
        shareToken = new MockERC20Minimal();
        otherToken = new MockERC20Minimal();

        upkeep = new FeeCollectorUpkeep(address(mockFC), owner, INTERVAL);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public view {
        assertEq(address(upkeep.feeCollector()), address(mockFC));
        assertEq(upkeep.interval(), INTERVAL);
        assertEq(upkeep.owner(), owner);
    }

    function test_constructor_revertsZeroFeeCollector() public {
        vm.expectRevert("feeCollector=0");
        new FeeCollectorUpkeep(address(0), owner, INTERVAL);
    }

    function test_constructor_ownerStaysDeployerWhenInitialOwnerIsZero() public {
        FeeCollectorUpkeep u = new FeeCollectorUpkeep(address(mockFC), address(0), INTERVAL);
        assertEq(u.owner(), address(this));
    }

    function test_constructor_ownerStaysDeployerWhenInitialOwnerIsSelf() public {
        FeeCollectorUpkeep u = new FeeCollectorUpkeep(address(mockFC), address(this), INTERVAL);
        assertEq(u.owner(), address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: addToken
    // ═══════════════════════════════════════════════════════════════════════════

    function test_addToken_happyPath() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TokenAdded(address(shareToken));
        upkeep.addToken(address(shareToken));

        assertTrue(upkeep.isToken(address(shareToken)));
        address[] memory list = upkeep.getTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(shareToken));
    }

    function test_addToken_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("token=0");
        upkeep.addToken(address(0));
    }

    function test_addToken_revertsDuplicate() public {
        vm.startPrank(owner);
        upkeep.addToken(address(shareToken));
        vm.expectRevert("already added");
        upkeep.addToken(address(shareToken));
        vm.stopPrank();
    }

    function test_addToken_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("Ownable: caller is not the owner");
        upkeep.addToken(address(shareToken));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: removeToken
    // ═══════════════════════════════════════════════════════════════════════════

    function test_removeToken_happyPath() public {
        vm.startPrank(owner);
        upkeep.addToken(address(shareToken));
        upkeep.addToken(address(otherToken));

        vm.expectEmit(true, true, true, true);
        emit TokenRemoved(address(shareToken));
        upkeep.removeToken(address(shareToken));
        vm.stopPrank();

        assertFalse(upkeep.isToken(address(shareToken)));
        address[] memory list = upkeep.getTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(otherToken));
    }

    function test_removeToken_revertsNotFound() public {
        vm.prank(owner);
        vm.expectRevert("not found");
        upkeep.removeToken(address(shareToken));
    }

    function test_removeToken_onlyOwner() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));

        vm.prank(address(0xDEAD));
        vm.expectRevert("Ownable: caller is not the owner");
        upkeep.removeToken(address(shareToken));
    }

    function test_removeToken_lastElement() public {
        vm.startPrank(owner);
        upkeep.addToken(address(shareToken));
        upkeep.removeToken(address(shareToken));
        vm.stopPrank();

        address[] memory list = upkeep.getTokens();
        assertEq(list.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: setInterval
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setInterval_happyPath() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IntervalUpdated(INTERVAL, 86_400);
        upkeep.setInterval(86_400);

        assertEq(upkeep.interval(), 86_400);
    }

    function test_setInterval_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("Ownable: caller is not the owner");
        upkeep.setInterval(86_400);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // checkUpkeep
    // ═══════════════════════════════════════════════════════════════════════════

    function test_checkUpkeep_noTokens_returnsFalse() public view {
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_cooldownNotElapsed_returnsFalse() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        // First perform to set lastDistributeTs
        upkeep.performUpkeep(abi.encode(address(shareToken)));

        // Immediately check — cooldown not elapsed
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_zeroBalance_returnsFalse() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));

        // No balance at feeCollector
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_happyPath() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        address token = abi.decode(data, (address));
        assertEq(token, address(shareToken));
    }

    function test_checkUpkeep_afterCooldownElapsed() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        // Perform once
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        (bool needed1,) = upkeep.checkUpkeep("");
        assertFalse(needed1);

        // Warp past interval
        vm.warp(block.timestamp + INTERVAL);
        // Need new balance (distribute would have cleared it)
        shareToken.mint(address(mockFC), SHARES);

        (bool needed2, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed2);
        assertEq(abi.decode(data, (address)), address(shareToken));
    }

    function test_checkUpkeep_multipleTokens_firstEligibleWins() public {
        vm.startPrank(owner);
        upkeep.addToken(address(shareToken));
        upkeep.addToken(address(otherToken));
        vm.stopPrank();

        // Only otherToken has balance
        otherToken.mint(address(mockFC), SHARES);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        assertEq(abi.decode(data, (address)), address(otherToken));
    }

    function test_checkUpkeep_multipleTokens_bothEligible_firstInArrayWins() public {
        vm.startPrank(owner);
        upkeep.addToken(address(shareToken));
        upkeep.addToken(address(otherToken));
        vm.stopPrank();

        shareToken.mint(address(mockFC), SHARES);
        otherToken.mint(address(mockFC), SHARES);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        // shareToken was added first → index 0 → wins
        assertEq(abi.decode(data, (address)), address(shareToken));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // performUpkeep — EXECUTION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_performUpkeep_callsDistribute() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        vm.expectEmit(true, true, true, true);
        emit DistributionTriggered(address(shareToken), block.timestamp);

        upkeep.performUpkeep(abi.encode(address(shareToken)));

        assertEq(mockFC.distributeCallCount(), 1);
        assertEq(mockFC.lastDistributeToken(), address(shareToken));
    }

    function test_performUpkeep_updatesLastDistributeTs() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        uint256 ts = block.timestamp;
        upkeep.performUpkeep(abi.encode(address(shareToken)));

        assertEq(upkeep.lastDistributeTs(address(shareToken)), ts);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // performUpkeep — CTO SAFE-IDEMPOTENT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_performUpkeep_silentReturnWhenUnknownToken() public {
        // Token not registered — silent return, no revert
        shareToken.mint(address(mockFC), SHARES);
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        assertEq(mockFC.distributeCallCount(), 0);
    }

    function test_performUpkeep_silentReturnWhenCooldownNotElapsed() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        // First call
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        assertEq(mockFC.distributeCallCount(), 1);

        // Immediately again — cooldown guard fires
        shareToken.mint(address(mockFC), SHARES);
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        assertEq(mockFC.distributeCallCount(), 1); // still 1
    }

    function test_performUpkeep_silentReturnWhenBalanceDrained() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));

        // checkUpkeep would have returned true with balance
        // but by the time performUpkeep runs, balance is 0
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        assertEq(mockFC.distributeCallCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // performUpkeep — DISTRIBUTE REVERTS → DistributionFailed
    // ═══════════════════════════════════════════════════════════════════════════

    function test_performUpkeep_distributeReverts_emitsFailedAndDoesNotRevert() public {
        vm.prank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);
        mockFC.setShouldRevert(true);

        vm.expectEmit(true, false, false, false);
        emit DistributionFailed(address(shareToken), "");

        // Should NOT revert
        upkeep.performUpkeep(abi.encode(address(shareToken)));

        // distribute was not actually successful
        assertEq(mockFC.distributeCallCount(), 0);
        // But lastDistributeTs was still updated (prevents retry loops)
        assertEq(upkeep.lastDistributeTs(address(shareToken)), block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════

    function test_removeToken_thenCheckUpkeep_skipsRemoved() public {
        vm.startPrank(owner);
        upkeep.addToken(address(shareToken));
        shareToken.mint(address(mockFC), SHARES);

        // Token is eligible
        (bool needed1,) = upkeep.checkUpkeep("");
        assertTrue(needed1);

        // Remove it
        upkeep.removeToken(address(shareToken));
        vm.stopPrank();

        // No longer eligible
        (bool needed2,) = upkeep.checkUpkeep("");
        assertFalse(needed2);
    }

    function test_intervalZero_immediateDistribution() public {
        vm.startPrank(owner);
        upkeep.setInterval(0);
        upkeep.addToken(address(shareToken));
        vm.stopPrank();

        shareToken.mint(address(mockFC), SHARES);

        // Perform
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        assertEq(mockFC.distributeCallCount(), 1);

        // Immediately perform again (interval=0, but same block.timestamp)
        shareToken.mint(address(mockFC), SHARES);
        upkeep.performUpkeep(abi.encode(address(shareToken)));
        // block.timestamp >= lastDistributeTs + 0 is true
        assertEq(mockFC.distributeCallCount(), 2);
    }

    function test_getTokens_emptyByDefault() public view {
        address[] memory list = upkeep.getTokens();
        assertEq(list.length, 0);
    }
}
