// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title EpochPayout
/// @notice Merkle-based distributor for epoch rewards (USDC only)
/// @dev Holds a single USDC pool (funding is fungible, not segregated per epoch).
///      Off-chain accounting ensures sum(claimable) <= pool balance.
///
///      Leaf encoding (256 bytes = 8×32, immune to second-preimage):
///        keccak256(abi.encode(chainid, address(this), epochId, category, beneficiary, token, amount, metadataHash))
///
///      Anti-replay: claimedLeaf[leafHash] = true
///      Anti-cross-chain: chainid in leaf
///      Anti-cross-contract: address(this) in leaf
///
///      Third-party claiming: anyone can submit a valid proof for any beneficiary.
///      Funds always go to the beneficiary in the leaf, never to msg.sender.
contract EpochPayout is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroRoot();
    error ZeroMetadataHash();
    error EpochAlreadyPublished(uint32 epochId);
    error EpochNotMonotonic(uint32 epochId, uint32 latestEpochId);
    error EpochNotPublished(uint32 epochId);
    error MetadataHashMismatch();
    error AlreadyClaimed();
    error InvalidProof();
    error ZeroAmount();
    error InsufficientFunds(uint256 required, uint256 available);

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event RootPublished(uint32 indexed epochId, bytes32 root, bytes32 metadataHash);
    event Claimed(
        uint32 indexed epochId,
        bytes32 indexed category,
        address indexed beneficiary,
        uint256 amount,
        bytes32 metadataHash
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant CAT_REFERRAL = keccak256("REFERRAL");
    bytes32 public constant CAT_PARTNER = keccak256("PARTNER");

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    IERC20 public immutable PAYOUT_TOKEN;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(bytes32 => bool) public claimedLeaf;
    mapping(uint32 => bytes32) public rootOfEpoch;
    mapping(uint32 => bytes32) public metadataHashOfEpoch;
    uint32 public latestEpochId;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address payoutToken_) Ownable() {
        PAYOUT_TOKEN = IERC20(payoutToken_);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Publish a Merkle root for an epoch
    /// @param epochId Must be strictly greater than latestEpochId (monotonic)
    /// @param root Merkle root (non-zero)
    /// @param metadataHash Hash binding this root to a specific off-chain report
    function publishRoot(uint32 epochId, bytes32 root, bytes32 metadataHash) external onlyOwner {
        if (root == bytes32(0)) revert ZeroRoot();
        if (metadataHash == bytes32(0)) revert ZeroMetadataHash();
        if (rootOfEpoch[epochId] != bytes32(0)) revert EpochAlreadyPublished(epochId);
        if (epochId <= latestEpochId) revert EpochNotMonotonic(epochId, latestEpochId);

        rootOfEpoch[epochId] = root;
        metadataHashOfEpoch[epochId] = metadataHash;
        latestEpochId = epochId;

        emit RootPublished(epochId, root, metadataHash);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CLAIM
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim rewards for a beneficiary using a Merkle proof
    /// @param epochId The epoch this claim belongs to
    /// @param category CAT_REFERRAL or CAT_PARTNER
    /// @param beneficiary Address receiving the payout (not necessarily msg.sender)
    /// @param amount Amount of PAYOUT_TOKEN to claim
    /// @param proof Merkle proof
    /// @param metadataHash Must match the epoch's metadataHash
    function claim(
        uint32 epochId,
        bytes32 category,
        address beneficiary,
        uint256 amount,
        bytes32[] calldata proof,
        bytes32 metadataHash
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        bytes32 root = rootOfEpoch[epochId];
        if (root == bytes32(0)) revert EpochNotPublished(epochId);
        if (metadataHash != metadataHashOfEpoch[epochId]) revert MetadataHashMismatch();

        // Solvency guard
        uint256 available = PAYOUT_TOKEN.balanceOf(address(this));
        if (available < amount) revert InsufficientFunds(amount, available);

        bytes32 leaf = computeLeaf(epochId, category, beneficiary, amount, metadataHash);
        if (claimedLeaf[leaf]) revert AlreadyClaimed();
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();

        claimedLeaf[leaf] = true;
        PAYOUT_TOKEN.safeTransfer(beneficiary, amount);

        emit Claimed(epochId, category, beneficiary, amount, metadataHash);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Compute a leaf hash for verification or off-chain use.
    /// @dev Double-hashed to match @openzeppelin/merkle-tree StandardMerkleTree:
    ///      leaf = keccak256(bytes.concat(keccak256(abi.encode(values))))
    ///      This is the industry standard for Merkle tree preimage resistance.
    function computeLeaf(
        uint32 epochId,
        bytes32 category,
        address beneficiary,
        uint256 amount,
        bytes32 metadataHash
    ) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(this),
                        epochId,
                        category,
                        beneficiary,
                        address(PAYOUT_TOKEN),
                        amount,
                        metadataHash
                    )
                )
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EMERGENCY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emergency sweep tokens (only when paused)
    function emergencySweep(address token, address to, uint256 amount) external onlyOwner {
        require(paused(), "EpochPayout: must be paused");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Transfer unallocated funds to ops wallet (governance-only, no pause required)
    /// @dev Used to recover funds not allocated to partner/referral claims.
    ///      Only the payout token can be swept this way (not arbitrary tokens).
    function sweepUnallocated(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "EpochPayout: zero address");
        PAYOUT_TOKEN.safeTransfer(to, amount);
        emit UnallocatedSwept(to, amount);
    }

    event UnallocatedSwept(address indexed to, uint256 amount);

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
