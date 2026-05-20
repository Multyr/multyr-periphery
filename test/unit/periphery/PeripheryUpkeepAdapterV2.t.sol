// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    PeripheryUpkeepAdapterV2,
    PeripheryOp,
    UnknownOp
} from "../../../src/periphery/automation/PeripheryUpkeepAdapterV2.sol";
import { OpsCollectorV2 } from "../../../src/periphery/ops/OpsCollectorV2.sol";
import { FeeDistributorV2 } from "../../../src/periphery/rewards/FeeDistributorV2.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockVaultShares is ERC20 {
    address public immutable asset;
    uint256 public pricePerShare = 1e6;

    constructor(string memory n, string memory s, address a) ERC20(n, s) {
        asset = a;
    }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }

    function forceWithdrawAll(address receiver) external returns (uint256) {
        uint256 shares = balanceOf(msg.sender);
        _burn(msg.sender, shares);
        uint256 assets = (shares * pricePerShare) / 1e6;
        IERC20(asset).transfer(receiver, assets);
        return assets;
    }
}

contract PeripheryUpkeepAdapterV2Test is Test {
    PeripheryUpkeepAdapterV2 public adapter;
    OpsCollectorV2 public collector;
    FeeDistributorV2 public feeDist;
    MockUSDC public usdc;
    MockVaultShares public vaultA;
    MockVaultShares public vaultB;

    address public opsWallet = address(0xAA01);
    address public epochPayout = address(0xEEEE);

    function setUp() public {
        usdc = new MockUSDC();
        vaultA = new MockVaultShares("Vault A", "vA", address(usdc));
        vaultB = new MockVaultShares("Vault B", "vB", address(usdc));

        feeDist = new FeeDistributorV2(address(usdc), epochPayout, 100_000e6, 1 hours, 1);

        collector = new OpsCollectorV2(address(usdc), opsWallet, address(feeDist), 7000);
        collector.addVault(address(vaultA));
        collector.addVault(address(vaultB));

        adapter = new PeripheryUpkeepAdapterV2(address(collector), address(feeDist));

        // Warp past initial delay so fundEpochPayout can execute
        vm.warp(1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsState() public {
        assertEq(address(adapter.opsCollector()), address(collector));
        assertEq(address(adapter.feeDistributor()), address(feeDist));
        assertEq(address(adapter.asset()), address(usdc));
    }

    function test_constructor_revertsOnZero() public {
        vm.expectRevert();
        new PeripheryUpkeepAdapterV2(address(0), address(feeDist));
        vm.expectRevert();
        new PeripheryUpkeepAdapterV2(address(collector), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHECKUPKEEP
    // ═══════════════════════════════════════════════════════════════════════════

    function test_checkUpkeep_idle() public {
        (bool needed, bytes memory data) = adapter.checkUpkeep("");
        assertFalse(needed);
        assertEq(data.length, 0);
    }

    function test_checkUpkeep_splitPriority() public {
        // OpsCollectorV2 has shares → SPLIT needed
        vaultA.mint(address(collector), 1000e6);
        usdc.mint(address(vaultA), 1000e6);

        (bool needed, bytes memory data) = adapter.checkUpkeep("");
        assertTrue(needed);
        PeripheryOp op = abi.decode(data, (PeripheryOp));
        assertEq(uint256(op), uint256(PeripheryOp.SPLIT));
    }

    function test_checkUpkeep_fundPriority() public {
        // FeeDistributor has USDC → FUND (but not SPLIT since no shares in collector)
        usdc.mint(address(feeDist), 1000e6);

        (bool needed, bytes memory data) = adapter.checkUpkeep("");
        assertTrue(needed);
        PeripheryOp op = abi.decode(data, (PeripheryOp));
        assertEq(uint256(op), uint256(PeripheryOp.FUND));
    }

    function test_checkUpkeep_splitBeforeFund() public {
        // Both conditions → SPLIT wins
        vaultA.mint(address(collector), 1000e6);
        usdc.mint(address(vaultA), 1000e6);
        usdc.mint(address(feeDist), 1000e6);

        (bool needed, bytes memory data) = adapter.checkUpkeep("");
        assertTrue(needed);
        PeripheryOp op = abi.decode(data, (PeripheryOp));
        assertEq(uint256(op), uint256(PeripheryOp.SPLIT));
    }

    function test_checkUpkeep_opsCollectorPausedSkipsSplit() public {
        vaultA.mint(address(collector), 1000e6);
        collector.pause();

        (bool needed, bytes memory data) = adapter.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_fundRespectsDelay() public {
        // Fund once, then check — delay not met
        usdc.mint(address(feeDist), 1000e6);
        feeDist.fundEpochPayout(1, 500e6);

        // No more than fund cap and within delay
        usdc.mint(address(feeDist), 500e6);
        (bool needed,) = adapter.checkUpkeep("");
        assertFalse(needed, "delay should block");

        // After delay
        vm.warp(block.timestamp + 1 hours + 1);
        (needed,) = adapter.checkUpkeep("");
        assertTrue(needed);
    }

    function test_checkUpkeep_fundRespectsCap() public {
        // Fund up to cap
        usdc.mint(address(feeDist), 100_000e6);
        feeDist.fundEpochPayout(1, 100_000e6);

        // Cap reached → no more funding even with balance
        usdc.mint(address(feeDist), 1000e6);
        vm.warp(block.timestamp + 1 hours + 1);
        (bool needed,) = adapter.checkUpkeep("");
        assertFalse(needed, "cap reached");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PERFORMUPKEEP — SPLIT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_performUpkeep_split() public {
        vaultA.mint(address(collector), 1000e6);
        vaultB.mint(address(collector), 2000e6);
        usdc.mint(address(vaultA), 1000e6);
        usdc.mint(address(vaultB), 2000e6);

        bytes memory data = abi.encode(PeripheryOp.SPLIT);
        adapter.performUpkeep(data);

        // All shares distributed
        assertEq(vaultA.balanceOf(address(collector)), 0);
        assertEq(vaultB.balanceOf(address(collector)), 0);
        // Growth USDC arrived at FeeDistributor
        uint256 expectedGrowth = ((1000e6 + 2000e6) * 3000) / 10_000;
        assertEq(usdc.balanceOf(address(feeDist)), expectedGrowth);
    }

    function test_performUpkeep_split_stalePerformDataSilentReturn() public {
        // Stale performData: say SPLIT but no shares
        bytes memory data = abi.encode(PeripheryOp.SPLIT);
        // Should not revert, just silent return
        adapter.performUpkeep(data);
        assertEq(vaultA.balanceOf(address(collector)), 0);
    }

    function test_performUpkeep_split_skipsWhenPaused() public {
        vaultA.mint(address(collector), 1000e6);
        collector.pause();
        bytes memory data = abi.encode(PeripheryOp.SPLIT);
        adapter.performUpkeep(data); // no revert, silent
        assertEq(vaultA.balanceOf(address(collector)), 1000e6, "shares untouched");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PERFORMUPKEEP — FUND
    // ═══════════════════════════════════════════════════════════════════════════

    function test_performUpkeep_fund() public {
        usdc.mint(address(feeDist), 5000e6);
        bytes memory data = abi.encode(PeripheryOp.FUND);
        adapter.performUpkeep(data);

        assertEq(usdc.balanceOf(epochPayout), 5000e6);
    }

    function test_performUpkeep_fund_noBalanceSilent() public {
        bytes memory data = abi.encode(PeripheryOp.FUND);
        adapter.performUpkeep(data); // silent
        assertEq(usdc.balanceOf(epochPayout), 0);
    }

    function test_performUpkeep_unknownOpReverts() public {
        bytes memory data = abi.encode(PeripheryOp.NONE);
        vm.expectRevert(UnknownOp.selector);
        adapter.performUpkeep(data);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // END-TO-END PIPELINE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_fullPipelineFlow() public {
        // Simulate: FeeCollector mints shares to OpsCollector (as 28% ops slice)
        vaultA.mint(address(collector), 1000e6);
        vaultB.mint(address(collector), 500e6);
        usdc.mint(address(vaultA), 1000e6);
        usdc.mint(address(vaultB), 500e6);

        // 1. Keeper runs checkUpkeep → gets SPLIT
        (bool needed1, bytes memory data1) = adapter.checkUpkeep("");
        assertTrue(needed1);
        adapter.performUpkeep(data1);

        // Ops received shares
        assertEq(vaultA.balanceOf(opsWallet), 700e6);
        assertEq(vaultB.balanceOf(opsWallet), 350e6);
        // FeeDistributor received USDC
        assertEq(usdc.balanceOf(address(feeDist)), 450e6);

        // 2. Advance time past delay
        vm.warp(block.timestamp + 1 hours + 1);

        // 3. Keeper runs again → gets FUND
        (bool needed2, bytes memory data2) = adapter.checkUpkeep("");
        assertTrue(needed2);
        PeripheryOp op = abi.decode(data2, (PeripheryOp));
        assertEq(uint256(op), uint256(PeripheryOp.FUND));
        adapter.performUpkeep(data2);

        // EpochPayout received USDC
        assertEq(usdc.balanceOf(epochPayout), 450e6);

        // 4. Idle
        (bool needed3,) = adapter.checkUpkeep("");
        assertFalse(needed3);
    }
}
