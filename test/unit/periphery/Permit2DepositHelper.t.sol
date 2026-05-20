// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { Permit2DepositHelper, IPermit2 } from "../../../src/periphery/Permit2DepositHelper.sol";
import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { ERC4626Module } from "@multyr-core/core/modules/ERC4626Module.sol";
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";
import { MockUSDCPermit } from "../../helpers/MockUSDCPermit.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBufferManager } from "@multyr-core/interfaces/IBufferManager.sol";

/// @notice Minimal mock BufferManager that returns fresh/valid warmNavState
contract StubBufferManager is IBufferManager {
    function refreshWarmNav() external {}
    function warmNavState() external view returns (uint256, uint40, bool) {
        return (0, uint40(block.timestamp), true);
    }
    function prepareDeploy() external pure returns (uint256) { return 0; }
    function executeDeploy(uint256) external {}
    function refill(uint256) external {}
    function rebalance() external {}
    function updateConfig(BufferConfig calldata) external {}
    function setWarmAdapters(address[] calldata) external {}
    function setPaused(bool) external {}
    function getConfig() external view returns (BufferConfig memory c) { return c; }
    function hotBalance() external pure returns (uint256) { return 0; }
    function warmBalance() external pure returns (uint256) { return 0; }
    function totalBuffer() external pure returns (uint256) { return 0; }
    function plan() external pure returns (uint256, uint256) { return (0, 0); }
    function canRebalance() external pure returns (bool) { return false; }
    function getWarmAdapters() external pure returns (address[] memory) { return new address[](0); }
    function addWarmAdapter(address) external {}
    function removeWarmAdapter(uint256) external {}
    function forceRefill(uint256) external returns (bool, uint256) { return (false, 0); }
    function realizeForReserveAndOps(uint256) external returns (uint256) { return 0; }
}

/**
 * @title MockPermit2
 * @notice Minimal mock of Uniswap Permit2 for testing
 */
contract MockPermit2 {
    // Track nonces to prevent replay
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    error InvalidSignature();
    error ExpiredDeadline();
    error NonceAlreadyUsed();

    /// @notice Mock permitTransferFrom - just validates basic params and transfers
    function permitTransferFrom(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external {
        // Check deadline
        if (block.timestamp > permit.deadline) revert ExpiredDeadline();

        // Check nonce not used (replay protection)
        if (usedNonces[owner][permit.nonce]) revert NonceAlreadyUsed();
        usedNonces[owner][permit.nonce] = true;

        // Validate signature (mock: just check it's not empty)
        if (signature.length == 0) revert InvalidSignature();

        // Transfer tokens from owner to recipient
        IERC20(permit.permitted.token)
            .transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}

/**
 * @title Permit2DepositHelper Tests
 * @notice Unit tests for the Permit2DepositHelper periphery contract
 */
contract Permit2DepositHelperTest is Test {
    Permit2DepositHelper public helper;
    MockPermit2 public permit2;
    CoreVault public vault;
    MockUSDCPermit public usdc;
    MockParamsProvider public paramsProvider;

    address public owner = address(0xA11CE);
    address public feeCollector = address(0xFEE);
    address public user = address(0x1234);
    address public receiver = address(0x5678);

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC

    event DepositViaPermit2(
        address indexed user, address indexed receiver, uint256 assets, uint256 shares
    );

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDCPermit();

        // Deploy mock Permit2
        permit2 = new MockPermit2();

        // Deploy params provider
        paramsProvider = new MockParamsProvider();

        // Deploy CoreVault (without ERC20Permit now)
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "VaultUSDC",
            "vUSDC",
            owner,
            feeCollector,
            address(paramsProvider)
        );

        // Wire ERC4626Module selectors so deposit/mint route correctly
        {
            ERC4626Module erc4626Module = new ERC4626Module();
            bytes4[] memory erc4626Sels = SelectorLib.getERC4626ModuleSelectors();
            vm.startPrank(owner);
            for (uint256 i; i < erc4626Sels.length; i++) {
                vault.setModule(erc4626Sels[i], address(erc4626Module), SelectorLib.ROLE_PUBLIC);
            }
            vault.authorizeModule(address(erc4626Module), true);
            vm.stopPrank();
        }

        // Wire a mock BufferManager so deposit() doesn't revert NavInvalid
        {
            StubBufferManager bm = new StubBufferManager();
            bytes32 CORE_SLOT = 0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00;
            bytes32 bufferSlot = bytes32(uint256(CORE_SLOT) + 1);
            vm.store(address(vault), bufferSlot, bytes32(uint256(uint160(address(bm)))));
        }

        // Unpause vault (v8+: starts paused)
        vm.prank(owner);
        vault.unpauseAll();

        // Deploy Permit2DepositHelper
        helper = new Permit2DepositHelper(address(permit2), address(vault), address(usdc));

        // Setup user: mint USDC and approve Permit2
        usdc.mint(user, INITIAL_BALANCE);
        vm.prank(user);
        usdc.approve(address(permit2), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_sets_immutables() public view {
        assertEq(address(helper.PERMIT2()), address(permit2));
        assertEq(address(helper.VAULT()), address(vault));
        assertEq(address(helper.ASSET()), address(usdc));
    }

    function test_constructor_reverts_zero_permit2() public {
        vm.expectRevert(Permit2DepositHelper.ZeroAddress.selector);
        new Permit2DepositHelper(address(0), address(vault), address(usdc));
    }

    function test_constructor_reverts_zero_vault() public {
        vm.expectRevert(Permit2DepositHelper.ZeroAddress.selector);
        new Permit2DepositHelper(address(permit2), address(0), address(usdc));
    }

    function test_constructor_reverts_zero_asset() public {
        vm.expectRevert(Permit2DepositHelper.ZeroAddress.selector);
        new Permit2DepositHelper(address(permit2), address(vault), address(0));
    }

    function test_constructor_reverts_token_mismatch() public {
        MockUSDCPermit wrongToken = new MockUSDCPermit();
        vm.expectRevert(Permit2DepositHelper.TokenMismatch.selector);
        new Permit2DepositHelper(address(permit2), address(vault), address(wrongToken));
    }

    function test_constructor_approves_vault() public view {
        uint256 allowance = usdc.allowance(address(helper), address(vault));
        assertEq(allowance, type(uint256).max, "Helper should have max approval to vault");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HAPPY PATH TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositWithPermit2_happy_path() public {
        uint256 amount = 1_000e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = hex"deadbeef"; // Mock sig

        uint256 userBalBefore = usdc.balanceOf(user);
        uint256 receiverSharesBefore = vault.balanceOf(receiver);

        vm.prank(user);
        uint256 shares = helper.depositWithPermit2(amount, receiver, nonce, deadline, signature);

        // Verify USDC transferred from user
        assertEq(usdc.balanceOf(user), userBalBefore - amount, "User USDC should decrease");

        // Verify shares minted to receiver (accounting for deposit fee)
        assertGt(shares, 0, "Should mint shares");
        assertEq(
            vault.balanceOf(receiver), receiverSharesBefore + shares, "Receiver should have shares"
        );
    }

    function test_depositWithPermit2_emits_event() public {
        uint256 amount = 500e6;
        uint256 nonce = 42;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = hex"cafebabe";

        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit DepositViaPermit2(user, receiver, amount, 0); // shares checked separately

        helper.depositWithPermit2(amount, receiver, nonce, deadline, signature);
    }

    function test_depositWithPermit2_receiver_different_from_signer() public {
        uint256 amount = 100e6;
        address differentReceiver = address(0x9999);

        vm.prank(user);
        uint256 shares = helper.depositWithPermit2(
            amount, differentReceiver, 1, block.timestamp + 1 hours, hex"1234"
        );

        assertGt(shares, 0);
        assertEq(
            vault.balanceOf(differentReceiver), shares, "Different receiver should have shares"
        );
        assertEq(vault.balanceOf(user), 0, "Signer should have no shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REVERT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositWithPermit2_reverts_zero_amount() public {
        vm.prank(user);
        vm.expectRevert(Permit2DepositHelper.ZeroAmount.selector);
        helper.depositWithPermit2(0, receiver, 1, block.timestamp + 1 hours, hex"1234");
    }

    function test_depositWithPermit2_reverts_zero_receiver() public {
        vm.prank(user);
        vm.expectRevert(Permit2DepositHelper.ZeroAddress.selector);
        helper.depositWithPermit2(100e6, address(0), 1, block.timestamp + 1 hours, hex"1234");
    }

    function test_depositWithPermit2_reverts_expired_deadline() public {
        uint256 deadline = block.timestamp - 1; // Already expired

        vm.prank(user);
        vm.expectRevert(MockPermit2.ExpiredDeadline.selector);
        helper.depositWithPermit2(100e6, receiver, 1, deadline, hex"1234");
    }

    function test_depositWithPermit2_reverts_nonce_replay() public {
        uint256 amount = 100e6;
        uint256 nonce = 123;
        bytes memory signature = hex"abcd";

        // First deposit succeeds
        vm.prank(user);
        helper.depositWithPermit2(amount, receiver, nonce, block.timestamp + 1 hours, signature);

        // Second deposit with same nonce fails
        vm.prank(user);
        vm.expectRevert(MockPermit2.NonceAlreadyUsed.selector);
        helper.depositWithPermit2(amount, receiver, nonce, block.timestamp + 1 hours, signature);
    }

    function test_depositWithPermit2_reverts_empty_signature() public {
        vm.prank(user);
        vm.expectRevert(MockPermit2.InvalidSignature.selector);
        helper.depositWithPermit2(100e6, receiver, 1, block.timestamp + 1 hours, hex"");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PREVIEW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_previewDeposit_matches_vault() public view {
        uint256 amount = 1_000e6;
        uint256 helperPreview = helper.previewDeposit(amount);
        uint256 vaultPreview = vault.previewDeposit(amount);
        assertEq(helperPreview, vaultPreview, "Preview should match vault");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_depositWithPermit2(uint256 amount, uint256 nonce) public {
        // Bound amount to reasonable range
        amount = bound(amount, 1e6, INITIAL_BALANCE / 2);
        nonce = bound(nonce, 1, type(uint128).max);

        vm.prank(user);
        uint256 shares = helper.depositWithPermit2(
            amount, receiver, nonce, block.timestamp + 1 hours, hex"f0f0f0f0"
        );

        assertGt(shares, 0, "Should mint non-zero shares");
        assertEq(vault.balanceOf(receiver), shares, "Receiver should have shares");
    }
}
