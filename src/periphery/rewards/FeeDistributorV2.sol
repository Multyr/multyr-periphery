// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title FeeDistributorV2
/// @notice Receives USDC from OpsCollectorV2 and funds EpochPayout for referral/partner claims.
/// @dev Simplified vs V1: no share redemption logic. OpsCollectorV2 handles the
///      share → USDC conversion. This contract is a thin funding gate:
///
///      OpsCollectorV2 → USDC → FeeDistributorV2 → fundEpochPayout() → EpochPayout
///
///      Vault-agnostic: single instance serves all vaults (receives USDC from any source).
///
///      Guardrails:
///      - Per-epoch funding cap (maxFundPerEpoch)
///      - Minimum delay between fund calls
///      - Granular pause (funding / global)
///
///      Residual USDC (not allocated to referral/partner) can be swept by owner.
contract FeeDistributorV2 is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error FundingPaused();
    error FundDelayNotMet(uint256 earliest, uint256 current);
    error EpochNotMonotonic(uint32 newEpochId, uint32 currentEpochId);
    error ExceedsEpochCap(uint256 requested, uint256 remaining);

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event EpochFunded(uint32 indexed epochId, uint256 assets);
    event EpochAdvanced(uint32 indexed newEpochId);
    event GuardrailsUpdated(uint256 maxFundPerEpoch, uint256 minDelayBetweenFunds);
    event EpochPayoutUpdated(address indexed oldPayout, address indexed newPayout);
    event FundingPauseUpdated(bool paused);

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    IERC20 public immutable ASSET; // USDC

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    address public epochPayout;
    uint256 public maxFundPerEpoch;
    uint256 public minDelayBetweenFunds;
    uint256 public lastFundTimestamp;
    mapping(uint32 => uint256) public fundedInEpoch;
    uint32 public currentEpochId;
    bool public fundingPaused;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address asset_,
        address epochPayout_,
        uint256 maxFundPerEpoch_,
        uint256 minDelayBetweenFunds_,
        uint32 initialEpochId_
    ) Ownable() {
        if (asset_ == address(0)) revert ZeroAddress();
        if (epochPayout_ == address(0)) revert ZeroAddress();

        ASSET = IERC20(asset_);
        epochPayout = epochPayout_;
        maxFundPerEpoch = maxFundPerEpoch_;
        minDelayBetweenFunds = minDelayBetweenFunds_;
        currentEpochId = initialEpochId_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fund EpochPayout with a specific USDC amount (budget for referral/partner claims).
    /// @param epochId Epoch identifier (telemetry only — funding is fungible in EpochPayout).
    /// @param amount USDC amount to transfer. If 0, transfers full balance.
    /// @dev Only the off-chain-calculated payout budget should be funded.
    ///      Excess USDC stays here for governance to sweep.
    ///      Permissionless — anyone can call if guards pass.
    function fundEpochPayout(uint32 epochId, uint256 amount) external nonReentrant whenNotPaused {
        if (fundingPaused) revert FundingPaused();
        if (block.timestamp < lastFundTimestamp + minDelayBetweenFunds) {
            revert FundDelayNotMet(lastFundTimestamp + minDelayBetweenFunds, block.timestamp);
        }

        uint256 bal = ASSET.balanceOf(address(this));
        if (bal == 0) return;

        uint256 toFund = amount == 0 ? bal : (amount > bal ? bal : amount);

        // Enforce per-epoch cap
        if (maxFundPerEpoch > 0) {
            uint256 remaining = maxFundPerEpoch - fundedInEpoch[epochId];
            if (toFund > remaining) revert ExceedsEpochCap(toFund, remaining);
        }

        fundedInEpoch[epochId] += toFund;
        lastFundTimestamp = block.timestamp;

        ASSET.safeTransfer(epochPayout, toFund);
        emit EpochFunded(epochId, toFund);
    }

    /// @notice Convenience: fund full balance (no amount param).
    function fundEpochPayout(uint32 epochId) external nonReentrant whenNotPaused {
        if (fundingPaused) revert FundingPaused();
        if (block.timestamp < lastFundTimestamp + minDelayBetweenFunds) {
            revert FundDelayNotMet(lastFundTimestamp + minDelayBetweenFunds, block.timestamp);
        }

        uint256 bal = ASSET.balanceOf(address(this));
        if (bal == 0) return;

        if (maxFundPerEpoch > 0) {
            uint256 remaining = maxFundPerEpoch - fundedInEpoch[epochId];
            if (bal > remaining) revert ExceedsEpochCap(bal, remaining);
        }

        fundedInEpoch[epochId] += bal;
        lastFundTimestamp = block.timestamp;

        ASSET.safeTransfer(epochPayout, bal);
        emit EpochFunded(epochId, bal);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Advance to a new epoch (resets per-epoch cap implicitly via mapping).
    function advanceEpoch(uint32 newEpochId) external onlyOwner {
        if (newEpochId <= currentEpochId) revert EpochNotMonotonic(newEpochId, currentEpochId);
        currentEpochId = newEpochId;
        emit EpochAdvanced(newEpochId);
    }

    function setGuardrails(uint256 maxFund, uint256 minDelay) external onlyOwner {
        maxFundPerEpoch = maxFund;
        minDelayBetweenFunds = minDelay;
        emit GuardrailsUpdated(maxFund, minDelay);
    }

    function setEpochPayout(address newEpochPayout) external onlyOwner {
        if (newEpochPayout == address(0)) revert ZeroAddress();
        address old = epochPayout;
        epochPayout = newEpochPayout;
        emit EpochPayoutUpdated(old, newEpochPayout);
    }

    function pauseFunding(bool paused_) external onlyOwner {
        fundingPaused = paused_;
        emit FundingPauseUpdated(paused_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sweep residual USDC (or stuck tokens) to a destination.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
        }
    }
}
