// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IIncentivesEngine } from "@multyr-core/interfaces/IIncentivesEngine.sol";

/// @title RewardsPayoutManager — SOLE payout point for incentive rewards
/// @notice Converts IncentivesEngine reward units to actual assets and pays users.
///         Pull-based: user calls claimVestedReward when ready. No upkeep needed.
///
/// RULES:
///   - This is the ONLY contract that pays rewards
///   - NO payout in CoreVault, IncentivesEngine, or exit paths
///   - Vested rewards do NOT expire — claimable indefinitely
///   - Each vesting tranche preserves its RewardMode permanently
///
/// PAYOUT MODES:
///   VaultShares: mint shares via CoreVault.mintRewardShares (dedicated, minimal)
///   MultyrToken: transfer from rewardsTreasury (ratio fixed at vesting creation)
///   Usdc: transfer from rewardsTreasury
contract RewardsPayoutManager {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error NotGovernance();
    error UnsupportedMode();
    error InsufficientTreasuryBalance(IIncentivesEngine.RewardMode mode, uint256 needed, uint256 available);

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event RewardPaid(
        address indexed user,
        uint256 vestingIdx,
        uint256 amount,
        IIncentivesEngine.RewardMode mode
    );
    event RewardsTreasuryLow(
        IIncentivesEngine.RewardMode mode,
        uint256 balance,
        uint256 threshold
    );
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event TreasuryUpdated(address indexed newTreasury);
    event MultyrTokenUpdated(address indexed newToken);
    event SharesMintAuthorityUpdated(address indexed newAuthority);
    event LowBalanceThresholdUpdated(IIncentivesEngine.RewardMode mode, uint256 threshold);

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    IIncentivesEngine public immutable ENGINE;
    IERC20 public immutable USDC;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    address public governance;
    address public rewardsTreasury;
    address public sharesMintAuthority; // CoreVault address (for mintRewardShares)
    IERC20 public multyrToken;

    // Low balance alert thresholds
    mapping(IIncentivesEngine.RewardMode => uint256) public lowBalanceThreshold;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address engine_,
        address usdc_,
        address governance_,
        address rewardsTreasury_
    ) {
        if (engine_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0)) revert ZeroAddress();
        if (governance_ == address(0)) revert ZeroAddress();
        if (rewardsTreasury_ == address(0)) revert ZeroAddress();

        ENGINE = IIncentivesEngine(engine_);
        USDC = IERC20(usdc_);
        governance = governance_;
        rewardsTreasury = rewardsTreasury_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // USER ACTION: CLAIM VESTED REWARD (pull model)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim vested reward from a specific vesting tranche
    /// @param vestingIdx Index of the reward vesting tranche in IncentivesEngine
    /// @param amount Amount of reward units to claim (WAD)
    function claimVestedReward(uint256 vestingIdx, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // 1. Withdraw from engine (accounting update)
        (uint256 paid, IIncentivesEngine.RewardMode mode, uint128 conversionRatio) =
            ENGINE.withdrawVested(msg.sender, vestingIdx, amount);

        // 2. Convert and pay based on mode
        if (mode == IIncentivesEngine.RewardMode.VaultShares) {
            _payVaultShares(msg.sender, paid);
        } else if (mode == IIncentivesEngine.RewardMode.MultyrToken) {
            _payMultyrToken(msg.sender, paid, conversionRatio);
        } else if (mode == IIncentivesEngine.RewardMode.Usdc) {
            _payUsdc(msg.sender, paid);
        } else {
            revert UnsupportedMode();
        }

        emit RewardPaid(msg.sender, vestingIdx, paid, mode);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: PAYOUT LOGIC
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Pay in vault shares — mint via dedicated authority
    function _payVaultShares(address user, uint256 rewardUnitsWad) internal {
        // Convert WAD reward units to USDC (6 decimals)
        uint256 usdcAmount = rewardUnitsWad / 1e12;
        if (usdcAmount == 0) return;

        // Mint shares via CoreVault.mintRewardShares (dedicated, minimal function)
        // This is a tightly-scoped function — NOT processorMint
        IMintRewardShares(sharesMintAuthority).mintRewardShares(user, usdcAmount);
    }

    /// @dev Pay in MULTYR token — transfer from treasury at fixed ratio
    function _payMultyrToken(address user, uint256 rewardUnitsWad, uint128 conversionRatio) internal {
        // Conversion ratio fixed at vesting creation (WAD scale)
        // amount = rewardUnitsWad * conversionRatio / WAD
        uint256 tokenAmount = (rewardUnitsWad * conversionRatio) / 1e18;
        if (tokenAmount == 0) return;

        uint256 balance = multyrToken.balanceOf(rewardsTreasury);
        if (balance < tokenAmount) {
            revert InsufficientTreasuryBalance(
                IIncentivesEngine.RewardMode.MultyrToken, tokenAmount, balance
            );
        }

        // Check low balance alert
        uint256 threshold = lowBalanceThreshold[IIncentivesEngine.RewardMode.MultyrToken];
        if (threshold > 0 && balance - tokenAmount < threshold) {
            emit RewardsTreasuryLow(IIncentivesEngine.RewardMode.MultyrToken, balance - tokenAmount, threshold);
        }

        multyrToken.safeTransferFrom(rewardsTreasury, user, tokenAmount);
    }

    /// @dev Pay in USDC — transfer from treasury
    function _payUsdc(address user, uint256 rewardUnitsWad) internal {
        uint256 usdcAmount = rewardUnitsWad / 1e12; // WAD → 6 decimals
        if (usdcAmount == 0) return;

        uint256 balance = USDC.balanceOf(rewardsTreasury);
        if (balance < usdcAmount) {
            revert InsufficientTreasuryBalance(
                IIncentivesEngine.RewardMode.Usdc, usdcAmount, balance
            );
        }

        uint256 threshold = lowBalanceThreshold[IIncentivesEngine.RewardMode.Usdc];
        if (threshold > 0 && balance - usdcAmount < threshold) {
            emit RewardsTreasuryLow(IIncentivesEngine.RewardMode.Usdc, balance - usdcAmount, threshold);
        }

        USDC.safeTransferFrom(rewardsTreasury, user, usdcAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    function setRewardsTreasury(address treasury_) external onlyGovernance {
        if (treasury_ == address(0)) revert ZeroAddress();
        rewardsTreasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setMultyrToken(address token_) external onlyGovernance {
        multyrToken = IERC20(token_);
        emit MultyrTokenUpdated(token_);
    }

    function setSharesMintAuthority(address authority_) external onlyGovernance {
        sharesMintAuthority = authority_;
        emit SharesMintAuthorityUpdated(authority_);
    }

    function setLowBalanceThreshold(IIncentivesEngine.RewardMode mode, uint256 threshold)
        external
        onlyGovernance
    {
        lowBalanceThreshold[mode] = threshold;
        emit LowBalanceThresholdUpdated(mode, threshold);
    }

    function transferGovernance(address newGov) external onlyGovernance {
        if (newGov == address(0)) revert ZeroAddress();
        emit GovernanceTransferred(governance, newGov);
        governance = newGov;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MONITORING VIEWS (for off-chain monitoring / alerting)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Available USDC balance in treasury for reward payouts
    function availableUsdc() external view returns (uint256) {
        return USDC.balanceOf(rewardsTreasury);
    }

    /// @notice Available MULTYR balance in treasury for reward payouts
    function availableMultyr() external view returns (uint256) {
        if (address(multyrToken) == address(0)) return 0;
        return multyrToken.balanceOf(rewardsTreasury);
    }

    /// @notice Check if treasury has sufficient balance for a payout
    function canPay(IIncentivesEngine.RewardMode mode, uint256 rewardUnitsWad)
        external
        view
        returns (bool sufficient, uint256 available, uint256 needed)
    {
        if (mode == IIncentivesEngine.RewardMode.VaultShares) {
            return (true, type(uint256).max, 0); // mint is unlimited
        } else if (mode == IIncentivesEngine.RewardMode.MultyrToken) {
            needed = rewardUnitsWad; // 1:1 default (conversionRatio applied at claim)
            available = address(multyrToken) != address(0)
                ? multyrToken.balanceOf(rewardsTreasury) : 0;
            sufficient = available >= needed;
        } else if (mode == IIncentivesEngine.RewardMode.Usdc) {
            needed = rewardUnitsWad / 1e12; // WAD → 6 decimals
            available = USDC.balanceOf(rewardsTreasury);
            sufficient = available >= needed;
        }
    }
}

/// @dev Minimal interface for CoreVault reward share minting
/// @notice Tightly-scoped: ONLY callable by authorized RewardsPayoutManager
interface IMintRewardShares {
    function mintRewardShares(address user, uint256 usdcEquivalent) external;
}
