// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { OpsCollectorV2 } from "../../../src/periphery/ops/OpsCollectorV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title MockVaultShares
/// @notice ERC20 with asset() getter and forceWithdrawAll() for testing OpsCollectorV2
contract MockVaultShares is ERC20 {
    address public immutable asset;
    uint256 public pricePerShare = 1e6; // 1 share = 1 USDC by default (6 decimals)

    constructor(string memory n, string memory s, address asset_) ERC20(n, s) {
        asset = asset_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setPricePerShare(uint256 pps) external {
        pricePerShare = pps;
    }

    /// @notice Simulates the vault's forceWithdrawAll: burns ALL shares of caller, pays USDC
    /// @dev For testing, applies no fee (tests use this to verify the OpsCollectorV2 flow).
    ///      Production vaults apply FORCE fee ~2%, but that's orthogonal to this test.
    function forceWithdrawAll(address receiver) external returns (uint256 assetsReceived) {
        uint256 shares = balanceOf(msg.sender);
        require(shares > 0, "zero shares");

        // Compute underlying assets
        assetsReceived = (shares * pricePerShare) / 1e6;

        // Burn shares from caller
        _burn(msg.sender, shares);

        // Transfer USDC to receiver (assumes this contract has USDC minted to it)
        IERC20(asset).transfer(receiver, assetsReceived);
    }
}

/// @title OpsCollectorV2Test
contract OpsCollectorV2Test is Test {
    OpsCollectorV2 public collector;
    MockUSDC public usdc;
    MockVaultShares public vaultA;
    MockVaultShares public vaultB;
    MockVaultShares public vaultC;

    address public opsWallet = address(0xAA01);
    address public feeDistributor = address(0xBB02);
    address public owner;

    uint16 public constant OPS_BPS = 7000; // 70% ops, 30% growth

    function setUp() public {
        owner = address(this);

        usdc = new MockUSDC();
        vaultA = new MockVaultShares("USDC Lending Vault", "mvUSDC-A", address(usdc));
        vaultB = new MockVaultShares("USDC Multiply Vault", "mvUSDC-B", address(usdc));
        vaultC = new MockVaultShares("USDC Delta Vault", "mvUSDC-C", address(usdc));

        collector = new OpsCollectorV2(address(usdc), opsWallet, feeDistributor, OPS_BPS);
        collector.addVault(address(vaultA));
        collector.addVault(address(vaultB));
        collector.addVault(address(vaultC));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. CONSTRUCTOR VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsStateCorrectly() public {
        assertEq(address(collector.UNDERLYING()), address(usdc));
        assertEq(collector.opsWallet(), opsWallet);
        assertEq(collector.feeDistributor(), feeDistributor);
        assertEq(collector.opsBps(), OPS_BPS);
        assertEq(collector.growthBps(), 10_000 - OPS_BPS);
        assertEq(collector.owner(), owner);
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(OpsCollectorV2.ZeroAddress.selector);
        new OpsCollectorV2(address(0), opsWallet, feeDistributor, OPS_BPS);
    }

    function test_constructor_revertsOnZeroOpsWallet() public {
        vm.expectRevert(OpsCollectorV2.ZeroAddress.selector);
        new OpsCollectorV2(address(usdc), address(0), feeDistributor, OPS_BPS);
    }

    function test_constructor_revertsOnZeroFeeDistributor() public {
        vm.expectRevert(OpsCollectorV2.ZeroAddress.selector);
        new OpsCollectorV2(address(usdc), opsWallet, address(0), OPS_BPS);
    }

    function test_constructor_revertsGrowthAboveCap() public {
        // growth = 10000 - opsBps; if opsBps too low, growth > 5000 cap
        vm.expectRevert();
        new OpsCollectorV2(address(usdc), opsWallet, feeDistributor, 4000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. VAULT REGISTRY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_addVault_registersCorrectly() public {
        address[] memory vaults = collector.getVaults();
        assertEq(vaults.length, 3);
        assertTrue(collector.isRegistered(address(vaultA)));
        assertTrue(collector.isRegistered(address(vaultB)));
        assertTrue(collector.isRegistered(address(vaultC)));
    }

    function test_addVault_revertsOnZero() public {
        vm.expectRevert(OpsCollectorV2.ZeroAddress.selector);
        collector.addVault(address(0));
    }

    function test_addVault_revertsOnDuplicate() public {
        vm.expectRevert(
            abi.encodeWithSelector(OpsCollectorV2.VaultAlreadyRegistered.selector, address(vaultA))
        );
        collector.addVault(address(vaultA));
    }

    function test_addVault_revertsOnAssetMismatch() public {
        MockUSDC otherAsset = new MockUSDC();
        MockVaultShares wrongVault =
            new MockVaultShares("Wrong", "W", address(otherAsset));
        vm.expectRevert(
            abi.encodeWithSelector(
                OpsCollectorV2.AssetMismatch.selector, address(usdc), address(otherAsset)
            )
        );
        collector.addVault(address(wrongVault));
    }

    function test_addVault_onlyOwner() public {
        MockVaultShares newVault =
            new MockVaultShares("New", "N", address(usdc));
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        collector.addVault(address(newVault));
    }

    function test_removeVault_works() public {
        collector.removeVault(address(vaultB));
        assertFalse(collector.isRegistered(address(vaultB)));
        address[] memory vaults = collector.getVaults();
        assertEq(vaults.length, 2);
    }

    function test_removeVault_revertsIfNotRegistered() public {
        address fake = address(0x1234);
        vm.expectRevert(
            abi.encodeWithSelector(OpsCollectorV2.VaultNotRegistered.selector, fake)
        );
        collector.removeVault(fake);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. SPLIT — SINGLE VAULT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_split_distributesCorrectly() public {
        uint256 total = 1000e6; // 1000 shares

        // Give OpsCollectorV2 some mvUSDC-A shares
        vaultA.mint(address(collector), total);
        // Fund the mock vault with USDC so forceWithdrawAll pays out
        usdc.mint(address(vaultA), total);

        uint256 expectedOps = (total * uint256(OPS_BPS)) / 10_000; // 700 shares
        uint256 expectedGrowth = total - expectedOps; // 300 shares → 300 USDC

        collector.split(address(vaultA));

        // Ops wallet received shares
        assertEq(vaultA.balanceOf(opsWallet), expectedOps, "ops shares");
        // FeeDistributor received USDC
        assertEq(usdc.balanceOf(feeDistributor), expectedGrowth, "USDC to feeDist");
        // Collector is clean
        assertEq(vaultA.balanceOf(address(collector)), 0, "collector shares");
        assertEq(usdc.balanceOf(address(collector)), 0, "collector usdc");
    }

    function test_split_zeroBalanceNoOp() public {
        collector.split(address(vaultA));
        // No revert, just nothing happens
        assertEq(vaultA.balanceOf(opsWallet), 0);
        assertEq(usdc.balanceOf(feeDistributor), 0);
    }

    function test_split_revertsOnUnregisteredVault() public {
        address fake = address(0x9999);
        vm.expectRevert(
            abi.encodeWithSelector(OpsCollectorV2.VaultNotRegistered.selector, fake)
        );
        collector.split(fake);
    }

    function test_split_revertsWhenPaused() public {
        collector.pause();
        vaultA.mint(address(collector), 100e6);
        vm.expectRevert();
        collector.split(address(vaultA));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. SPLIT_ALL — MULTI VAULT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_splitAll_distributesFromAllVaults() public {
        // Mint shares to collector from 3 different vaults
        vaultA.mint(address(collector), 1000e6);
        vaultB.mint(address(collector), 2000e6);
        vaultC.mint(address(collector), 500e6);

        // Fund each vault with USDC
        usdc.mint(address(vaultA), 1000e6);
        usdc.mint(address(vaultB), 2000e6);
        usdc.mint(address(vaultC), 500e6);

        collector.splitAll();

        // Each ops got its share
        uint256 ops = uint256(OPS_BPS);
        assertEq(vaultA.balanceOf(opsWallet), (1000e6 * ops) / 10_000);
        assertEq(vaultB.balanceOf(opsWallet), (2000e6 * ops) / 10_000);
        assertEq(vaultC.balanceOf(opsWallet), (500e6 * ops) / 10_000);

        // Growth shares redeemed: 30% of each = 300 + 600 + 150 = 1050 USDC
        uint256 expectedGrowth = ((1000e6 + 2000e6 + 500e6) * 3000) / 10_000;
        assertEq(usdc.balanceOf(feeDistributor), expectedGrowth);

        // Collector is clean
        assertEq(vaultA.balanceOf(address(collector)), 0);
        assertEq(vaultB.balanceOf(address(collector)), 0);
        assertEq(vaultC.balanceOf(address(collector)), 0);
        assertEq(usdc.balanceOf(address(collector)), 0);
    }

    function test_splitAll_skipsVaultsWithZeroBalance() public {
        // Only fund vaultA
        vaultA.mint(address(collector), 1000e6);
        usdc.mint(address(vaultA), 1000e6);

        collector.splitAll();

        // Only vaultA processed
        assertGt(vaultA.balanceOf(opsWallet), 0);
        assertEq(vaultB.balanceOf(opsWallet), 0);
        assertEq(vaultC.balanceOf(opsWallet), 0);
        // Growth from vaultA only (300 USDC)
        assertEq(usdc.balanceOf(feeDistributor), (1000e6 * 3000) / 10_000);
    }

    function test_splitAll_revertsWhenPaused() public {
        collector.pause();
        vaultA.mint(address(collector), 100e6);
        vm.expectRevert();
        collector.splitAll();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setSplitParams_updatesBps() public {
        collector.setSplitParams(8000);
        assertEq(collector.opsBps(), 8000);
        assertEq(collector.growthBps(), 2000);
    }

    function test_setSplitParams_revertsAboveCap() public {
        vm.expectRevert();
        collector.setSplitParams(4000); // growth = 6000 > 5000 cap
    }

    function test_setOpsWallet_updates() public {
        address newWallet = address(0xCCCC);
        collector.setOpsWallet(newWallet);
        assertEq(collector.opsWallet(), newWallet);
    }

    function test_setFeeDistributor_updates() public {
        address newDist = address(0xDDDD);
        collector.setFeeDistributor(newDist);
        assertEq(collector.feeDistributor(), newDist);
    }

    function test_sweep_requiresPauseForManagedTokens() public {
        vaultA.mint(address(collector), 100e6);
        // unpaused → revert on share token sweep
        vm.expectRevert();
        collector.sweep(address(vaultA), owner);

        // Pause → works
        collector.pause();
        collector.sweep(address(vaultA), owner);
        assertEq(vaultA.balanceOf(owner), 100e6);
    }

    function test_sweep_underlyingRequiresPause() public {
        usdc.mint(address(collector), 100e6);
        vm.expectRevert();
        collector.sweep(address(usdc), owner);

        collector.pause();
        collector.sweep(address(usdc), owner);
        assertEq(usdc.balanceOf(owner), 100e6);
    }

    function test_sweep_randomTokenWorksUnpaused() public {
        MockUSDC randomToken = new MockUSDC();
        randomToken.mint(address(collector), 500e6);
        // No pause needed for non-managed token
        collector.sweep(address(randomToken), owner);
        assertEq(randomToken.balanceOf(owner), 500e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. FUZZ
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_split_invariant(uint256 amount, uint16 opsBpsInput) public {
        amount = bound(amount, 1, 1_000_000_000e6);
        opsBpsInput = uint16(bound(opsBpsInput, 5000, 10000)); // growth <= 5000

        collector.setSplitParams(opsBpsInput);

        vaultA.mint(address(collector), amount);
        usdc.mint(address(vaultA), amount);

        uint256 expectedOps = (amount * uint256(opsBpsInput)) / 10_000;
        uint256 expectedGrowth = amount - expectedOps;

        collector.split(address(vaultA));

        assertEq(vaultA.balanceOf(opsWallet), expectedOps);
        assertEq(usdc.balanceOf(feeDistributor), expectedGrowth);
        // Invariant: ops + growth = total
        assertEq(vaultA.balanceOf(opsWallet) + usdc.balanceOf(feeDistributor), amount);
    }
}
