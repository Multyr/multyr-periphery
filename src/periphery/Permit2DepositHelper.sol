// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IPermit2
 * @notice Minimal interface for Uniswap Permit2 - PermitTransferFrom functionality
 * @dev See: https://github.com/Uniswap/permit2
 */
interface IPermit2 {
    /// @notice Token and amount in a permit message
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    /// @notice Permit message for PermitTransferFrom
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Transfer details for permitTransferFrom
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Execute a transfer with a signed permit
    /// @param permit The permit data
    /// @param transferDetails The transfer details
    /// @param owner The owner of the tokens
    /// @param signature The EIP-712 signature
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

/**
 * @title Permit2DepositHelper
 * @notice Periphery contract enabling one-click deposits via Uniswap Permit2
 * @dev Immutable, no admin, no upgrades. Just a helper for UX.
 *
 * SECURITY MODEL:
 * - Fully immutable: PERMIT2, VAULT, ASSET are set at construction
 * - No owner, no admin functions, no upgrades
 * - Relies on Permit2 for signature verification and nonce management
 * - User signs Permit2 permit once (or per-use), helper handles approval and deposit
 *
 * FLOW:
 * 1. User approves Permit2 contract for ASSET (one-time, infinite approval)
 * 2. User signs a PermitTransferFrom message authorizing this helper to pull ASSET
 * 3. User calls depositWithPermit2() with the signature
 * 4. Helper pulls ASSET from user via Permit2, approves vault, calls deposit
 * 5. Shares are minted directly to receiver
 */
contract Permit2DepositHelper {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Uniswap Permit2 contract address
    IPermit2 public immutable PERMIT2;

    /// @notice CoreVault address
    IERC4626 public immutable VAULT;

    /// @notice Underlying asset (e.g., USDC)
    IERC20 public immutable ASSET;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted on successful deposit via Permit2
    /// @param user The user who signed the permit (token owner)
    /// @param receiver The address receiving vault shares
    /// @param assets The amount of assets deposited
    /// @param shares The amount of shares minted
    event DepositViaPermit2(
        address indexed user, address indexed receiver, uint256 assets, uint256 shares
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error TokenMismatch();
    error ZeroAmount();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the helper with immutable references
     * @param permit2_ The Uniswap Permit2 contract address
     * @param vault_ The CoreVault address
     * @param asset_ The underlying asset address (e.g., USDC)
     */
    constructor(address permit2_, address vault_, address asset_) {
        if (permit2_ == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();

        // Verify vault's asset matches
        if (IERC4626(vault_).asset() != asset_) revert TokenMismatch();

        PERMIT2 = IPermit2(permit2_);
        VAULT = IERC4626(vault_);
        ASSET = IERC20(asset_);

        // Pre-approve vault for max efficiency on subsequent deposits
        // Safe because vault is immutable and trusted
        IERC20(asset_).forceApprove(vault_, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN FUNCTION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit assets to vault using Permit2 signature
     * @dev User must have previously approved Permit2 for ASSET
     * @param amount Amount of assets to deposit
     * @param receiver Address to receive vault shares
     * @param nonce Permit2 nonce (user-selected, unique per permit)
     * @param deadline Permit expiration timestamp
     * @param signature EIP-712 signature for Permit2
     * @return shares Amount of vault shares minted
     */
    function depositWithPermit2(
        uint256 amount,
        address receiver,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Build permit data
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(ASSET), amount: amount }),
            nonce: nonce,
            deadline: deadline
        });

        // Transfer tokens from user to this contract via Permit2
        IPermit2.SignatureTransferDetails memory transferDetails =
            IPermit2.SignatureTransferDetails({ to: address(this), requestedAmount: amount });

        // Permit2 handles signature verification, nonce tracking, and transfer
        PERMIT2.permitTransferFrom(permit, transferDetails, msg.sender, signature);

        // Deposit to vault (approval already set in constructor)
        shares = VAULT.deposit(amount, receiver);

        emit DepositViaPermit2(msg.sender, receiver, amount, shares);
    }

    /**
     * @notice Preview shares for a given deposit amount
     * @param assets Amount of assets to deposit
     * @return shares Expected shares to receive
     */
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return VAULT.previewDeposit(assets);
    }
}
