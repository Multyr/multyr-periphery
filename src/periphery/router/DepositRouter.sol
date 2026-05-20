// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ReferralBinding } from "../referral/ReferralBinding.sol";

/// @title IPermit2Extended
/// @notice Permit2 interface covering both SignatureTransfer and AllowanceTransfer modes
/// @dev Matches Uniswap Permit2 deployed at 0x000000000022D473030F116dDEE9F6B43aC78BA3
interface IPermit2Extended {
    // ── SignatureTransfer (Mode A: per-deposit signature) ──

    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    // ── AllowanceTransfer (Mode B: Euler-style long-lived allowance) ──

    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature)
        external;

    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @title ICoreVaultDeposit
/// @notice Minimal interface for CoreVault.depositFor
interface ICoreVaultDeposit {
    function depositFor(uint256 assets, address receiver, address payer)
        external
        returns (uint256 shares);
}

/// @title DepositRouter
/// @notice Permit2-only deposit router with referral binding
/// @dev Immutable, no admin, no sweep, no callbacks. Fully minimal surface.
///
///      Two Permit2 modes:
///      (A) depositWithPermit2Transfer — per-deposit signature (PermitTransferFrom)
///      (B) depositWithPermit2Allowance — one-time allowance + deposit (Euler-style)
///
///      receiver = msg.sender always (prevents lock-grief).
///      Referral binding is safety-scoped: only catches expected errors.
contract DepositRouter {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error ZeroAddress();
    error TokenMismatch();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event DepositWithReferral(
        address indexed user, address indexed referrer, uint256 assets, uint256 shares
    );

    event ReferralBindingSkipped(address indexed user, address indexed referrer, bytes reason);

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    ICoreVaultDeposit public immutable VAULT;
    IERC20 public immutable ASSET;
    IPermit2Extended public immutable PERMIT2;
    ReferralBinding public immutable REFERRAL_BINDING;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address vault_, address asset_, address permit2_, address referralBinding_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (permit2_ == address(0)) revert ZeroAddress();
        if (referralBinding_ == address(0)) revert ZeroAddress();

        if (IERC4626(vault_).asset() != asset_) revert TokenMismatch();

        VAULT = ICoreVaultDeposit(vault_);
        ASSET = IERC20(asset_);
        PERMIT2 = IPermit2Extended(permit2_);
        REFERRAL_BINDING = ReferralBinding(referralBinding_);

        // Pre-approve vault so depositFor(amount, receiver, address(this)) works
        IERC20(asset_).forceApprove(vault_, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODE A: Per-deposit signature (PermitTransferFrom)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit with a per-deposit Permit2 signature
    /// @param amount Amount of ASSET to deposit
    /// @param referrer Referrer address (address(0) to skip binding)
    /// @param nonce Permit2 nonce
    /// @param deadline Permit2 deadline
    /// @param signature EIP-712 signature for PermitTransferFrom
    /// @return shares Amount of vault shares minted to msg.sender
    function depositWithPermit2Transfer(
        uint256 amount,
        address referrer,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        // Pull USDC from user to router via Permit2 SignatureTransfer
        IPermit2Extended.PermitTransferFrom memory permit = IPermit2Extended.PermitTransferFrom({
            permitted: IPermit2Extended.TokenPermissions({ token: address(ASSET), amount: amount }),
            nonce: nonce,
            deadline: deadline
        });

        IPermit2Extended.SignatureTransferDetails memory transferDetails =
            IPermit2Extended.SignatureTransferDetails({
                to: address(this), requestedAmount: amount
            });

        PERMIT2.permitTransferFrom(permit, transferDetails, msg.sender, signature);

        // Bind referral + deposit
        shares = _bindAndDeposit(amount, referrer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODE B: One-time allowance + deposit (Euler-style)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit using Permit2 allowance mode
    /// @dev First call: provide permitSignature to set Permit2 allowance (high cap, long expiry)
    ///      Subsequent calls: pass permitSignature = "" to use existing allowance
    /// @param amount Amount of ASSET to deposit
    /// @param referrer Referrer address (address(0) to skip binding)
    /// @param permitAmount Permit2 allowance amount (e.g. type(uint160).max)
    /// @param permitExpiration Permit2 allowance expiration timestamp
    /// @param permitNonce Permit2 allowance nonce
    /// @param permitDeadline Signature deadline
    /// @param permitSignature EIP-712 signature (empty = skip permit, use existing allowance)
    /// @return shares Amount of vault shares minted to msg.sender
    function depositWithPermit2Allowance(
        uint256 amount,
        address referrer,
        uint160 permitAmount,
        uint48 permitExpiration,
        uint48 permitNonce,
        uint256 permitDeadline,
        bytes calldata permitSignature
    ) external returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        // Set allowance on Permit2 if signature provided
        if (permitSignature.length > 0) {
            IPermit2Extended.PermitSingle memory permitSingle = IPermit2Extended.PermitSingle({
                details: IPermit2Extended.PermitDetails({
                    token: address(ASSET),
                    amount: permitAmount,
                    expiration: permitExpiration,
                    nonce: permitNonce
                }),
                spender: address(this),
                sigDeadline: permitDeadline
            });

            PERMIT2.permit(msg.sender, permitSingle, permitSignature);
        }

        // Transfer USDC from user to router via Permit2 allowance
        PERMIT2.transferFrom(msg.sender, address(this), uint160(amount), address(ASSET));

        // Bind referral + deposit
        shares = _bindAndDeposit(amount, referrer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Bind referral (safety-scoped) then deposit. receiver = msg.sender always.
    function _bindAndDeposit(uint256 amount, address referrer) internal returns (uint256 shares) {
        // Safety-scoped referral binding
        if (referrer != address(0)) {
            try REFERRAL_BINDING.bindFor(msg.sender, referrer) {
            // bound successfully
            }
            catch (bytes memory reason) {
                bytes4 sel = _revertSelector(reason);
                if (
                    sel == ReferralBinding.AlreadyBound.selector
                        || sel == ReferralBinding.SelfReferral.selector
                        || sel == ReferralBinding.ZeroAddress.selector
                ) {
                    // Expected errors — don't block deposit
                    emit ReferralBindingSkipped(msg.sender, referrer, reason);
                } else {
                    // Unknown error — bubble up
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
            }
        }

        // Deposit: vault pulls USDC from router (payer = address(this))
        // Shares minted to msg.sender (receiver = msg.sender, prevents lock-grief)
        shares = VAULT.depositFor(amount, msg.sender, address(this));

        emit DepositWithReferral(msg.sender, referrer, amount, shares);
    }

    /// @dev Extract selector from revert reason bytes (reliable via assembly)
    function _revertSelector(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(reason, 0x20))
        }
    }
}
