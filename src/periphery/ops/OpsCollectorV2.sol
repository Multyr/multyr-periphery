// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Percentage } from "@multyr-core/libs/Percentage.sol";

interface IForceWithdrawable {
    function forceWithdrawAll(address receiver) external returns (uint256 assetsReceived);
}

interface IERC4626Asset {
    function asset() external view returns (address);
}

/// @title OpsCollectorV2
/// @notice Multi-vault ops/growth splitter for the fee pipeline.
/// @dev Replaces FeeCollector.foundationOpsSafe. Receives vault shares from
///      FeeCollector.distribute(), then for each registered vault share token:
///        1. Transfers opsBps% of shares to opsWallet (untouched)
///        2. Redeems growthBps% of shares via forceWithdrawAll → USDC
///        3. Forwards USDC to feeDistributor (for referral/partner payouts)
///
///      Supports N vault share tokens (all must be USDC-underlying vaults).
///      Zero parking needed: ops shares transferred BEFORE forceWithdrawAll,
///      so the contract holds exactly the growth shares at redeem time.
contract OpsCollectorV2 is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error VaultNotRegistered(address shareToken);
    error VaultAlreadyRegistered(address shareToken);
    error AssetMismatch(address expected, address actual);
    error GrowthBpsExceedsCap(uint16 growthBps, uint16 maxGrowthBps);
    error MaxVaultsReached();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event Split(
        address indexed shareToken,
        uint256 totalShares,
        uint256 opsShares,
        uint256 growthShares,
        uint256 usdcRedeemed
    );
    event VaultAdded(address indexed shareToken);
    event VaultRemoved(address indexed shareToken);
    event SplitParamsUpdated(uint16 opsBps, uint16 growthBps);
    event OpsWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event FeeDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint16 public constant MAX_GROWTH_BPS = 5000; // 50% hard cap
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant MAX_VAULTS = 20;

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The common underlying asset for all registered vaults (e.g. USDC)
    IERC20 public immutable UNDERLYING;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    uint16 public opsBps;
    uint16 public growthBps;
    address public opsWallet;
    address public feeDistributor;

    /// @notice Registered vault share tokens
    address[] public vaults;
    mapping(address => bool) public isRegistered;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address underlying_,
        address opsWallet_,
        address feeDistributor_,
        uint16 opsBps_
    ) Ownable() {
        if (underlying_ == address(0)) revert ZeroAddress();
        if (opsWallet_ == address(0)) revert ZeroAddress();
        if (feeDistributor_ == address(0)) revert ZeroAddress();

        uint16 growth = BPS_DENOMINATOR - opsBps_;
        if (growth > MAX_GROWTH_BPS) revert GrowthBpsExceedsCap(growth, MAX_GROWTH_BPS);

        UNDERLYING = IERC20(underlying_);
        opsWallet = opsWallet_;
        feeDistributor = feeDistributor_;
        opsBps = opsBps_;
        growthBps = growth;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT REGISTRY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Register a vault share token. Must be an ERC4626 with UNDERLYING as asset.
    function addVault(address shareToken) external onlyOwner {
        if (shareToken == address(0)) revert ZeroAddress();
        if (isRegistered[shareToken]) revert VaultAlreadyRegistered(shareToken);
        if (vaults.length >= MAX_VAULTS) revert MaxVaultsReached();

        // Verify the vault's underlying asset matches
        address vaultAsset = IERC4626Asset(shareToken).asset();
        if (vaultAsset != address(UNDERLYING)) revert AssetMismatch(address(UNDERLYING), vaultAsset);

        vaults.push(shareToken);
        isRegistered[shareToken] = true;
        emit VaultAdded(shareToken);
    }

    /// @notice Unregister a vault share token.
    function removeVault(address shareToken) external onlyOwner {
        if (!isRegistered[shareToken]) revert VaultNotRegistered(shareToken);
        isRegistered[shareToken] = false;
        uint256 len = vaults.length;
        for (uint256 i = 0; i < len; i++) {
            if (vaults[i] == shareToken) {
                vaults[i] = vaults[len - 1];
                vaults.pop();
                break;
            }
        }
        emit VaultRemoved(shareToken);
    }

    /// @notice Get all registered vault share tokens.
    function getVaults() external view returns (address[] memory) {
        return vaults;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Split shares of a specific vault: ops% as shares, growth% redeemed to USDC.
    /// @param shareToken The vault share token to split.
    /// @dev Permissionless. No-op if balance is zero.
    ///      Flow:
    ///        1. Transfer opsBps% shares → opsWallet (shares, untouched)
    ///        2. forceWithdrawAll() on remaining → USDC arrives here
    ///        3. Transfer all USDC → feeDistributor
    function split(address shareToken) external nonReentrant whenNotPaused {
        if (!isRegistered[shareToken]) revert VaultNotRegistered(shareToken);

        uint256 total = IERC20(shareToken).balanceOf(address(this));
        if (total == 0) return;

        // Step 1: ops shares → opsWallet (untouched, as shares)
        uint256 opsAmount = Percentage.mulBpsDown(total, opsBps);
        if (opsAmount > 0) {
            IERC20(shareToken).safeTransfer(opsWallet, opsAmount);
        }

        // Step 2: remaining shares → forceWithdrawAll → USDC to this contract
        uint256 growthShares = IERC20(shareToken).balanceOf(address(this));
        uint256 usdcRedeemed = 0;
        if (growthShares > 0) {
            usdcRedeemed = IForceWithdrawable(shareToken).forceWithdrawAll(address(this));
        }

        // Step 3: all USDC → feeDistributor
        uint256 usdcBalance = UNDERLYING.balanceOf(address(this));
        if (usdcBalance > 0) {
            UNDERLYING.safeTransfer(feeDistributor, usdcBalance);
        }

        emit Split(shareToken, total, opsAmount, growthShares, usdcRedeemed);
    }

    /// @notice Split all registered vaults in one call.
    /// @dev Convenience function for keeper. Skips vaults with zero balance.
    function splitAll() external nonReentrant whenNotPaused {
        uint256 len = vaults.length;
        for (uint256 i = 0; i < len; i++) {
            address shareToken = vaults[i];
            uint256 bal = IERC20(shareToken).balanceOf(address(this));
            if (bal == 0) continue;

            // ops shares → opsWallet
            uint256 opsAmount = Percentage.mulBpsDown(bal, opsBps);
            if (opsAmount > 0) {
                IERC20(shareToken).safeTransfer(opsWallet, opsAmount);
            }

            // growth shares → redeem → USDC
            uint256 growthShares = IERC20(shareToken).balanceOf(address(this));
            uint256 usdcRedeemed = 0;
            if (growthShares > 0) {
                usdcRedeemed = IForceWithdrawable(shareToken).forceWithdrawAll(address(this));
            }

            emit Split(shareToken, bal, opsAmount, growthShares, usdcRedeemed);
        }

        // batch transfer all USDC → feeDistributor
        uint256 usdcBalance = UNDERLYING.balanceOf(address(this));
        if (usdcBalance > 0) {
            UNDERLYING.safeTransfer(feeDistributor, usdcBalance);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setSplitParams(uint16 newOpsBps) external onlyOwner {
        uint16 growth = BPS_DENOMINATOR - newOpsBps;
        if (growth > MAX_GROWTH_BPS) revert GrowthBpsExceedsCap(growth, MAX_GROWTH_BPS);
        opsBps = newOpsBps;
        growthBps = growth;
        emit SplitParamsUpdated(newOpsBps, growth);
    }

    function setOpsWallet(address newOpsWallet) external onlyOwner {
        if (newOpsWallet == address(0)) revert ZeroAddress();
        address old = opsWallet;
        opsWallet = newOpsWallet;
        emit OpsWalletUpdated(old, newOpsWallet);
    }

    function setFeeDistributor(address newFeeDistributor) external onlyOwner {
        if (newFeeDistributor == address(0)) revert ZeroAddress();
        address old = feeDistributor;
        feeDistributor = newFeeDistributor;
        emit FeeDistributorUpdated(old, newFeeDistributor);
    }

    /// @notice Sweep stuck tokens. UNDERLYING and registered share tokens require pause.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(UNDERLYING) || isRegistered[token]) {
            require(paused(), "OpsCollectorV2: must be paused to sweep managed tokens");
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
