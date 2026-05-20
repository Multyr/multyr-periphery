// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EpochPayout } from "../../../src/periphery/rewards/EpochPayout.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MerkleTreeHelper } from "../../helpers/MerkleTreeHelper.sol";

// ---------------------------------------------------------------------------
// Mock ERC20 with mint (minimal)
// ---------------------------------------------------------------------------
contract MockERC20 is IERC20 {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

    // ---------------------------------------------------------------------------
    // Test contract
    // ---------------------------------------------------------------------------
    contract EpochPayoutTest is Test {
        using MerkleTreeHelper for bytes32;

        EpochPayout public payout;
        MockERC20 public token;

        address public owner;
        address public alice = address(0xA11CE);
        address public bob = address(0xB0B);
        address public stranger = address(0x5747);

        bytes32 constant META = keccak256("epoch-1-meta");
        bytes32 constant META2 = keccak256("epoch-2-meta");

        uint256 constant POOL = 100_000e6;

        // Cache category constants to avoid external calls after vm.expectRevert
        bytes32 internal CAT_REFERRAL;
        bytes32 internal CAT_PARTNER;

        function setUp() public {
            owner = address(this);
            token = new MockERC20();
            payout = new EpochPayout(address(token));

            // Cache constants
            CAT_REFERRAL = payout.CAT_REFERRAL();
            CAT_PARTNER = payout.CAT_PARTNER();

            // Fund the payout pool
            token.mint(address(payout), POOL);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // HELPERS
        // ═══════════════════════════════════════════════════════════════════════

        /// @dev Publish epoch 1 with a 2-leaf tree and return (root, leafA, leafB)
        function _publishEpoch1() internal returns (bytes32 root, bytes32 leafA, bytes32 leafB) {
            leafA = payout.computeLeaf(1, CAT_REFERRAL, alice, 500e6, META);
            leafB = payout.computeLeaf(1, CAT_PARTNER, bob, 300e6, META);
            root = MerkleTreeHelper.buildRoot(leafA, leafB);
            payout.publishRoot(1, root, META);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // publishRoot
        // ═══════════════════════════════════════════════════════════════════════

        function test_publishRoot_onlyOwner_revert() public {
            vm.prank(stranger);
            vm.expectRevert("Ownable: caller is not the owner");
            payout.publishRoot(1, keccak256("root"), META);
        }

        function test_publishRoot_zeroRoot_revert() public {
            vm.expectRevert(EpochPayout.ZeroRoot.selector);
            payout.publishRoot(1, bytes32(0), META);
        }

        function test_publishRoot_zeroMetadataHash_revert() public {
            vm.expectRevert(EpochPayout.ZeroMetadataHash.selector);
            payout.publishRoot(1, keccak256("root"), bytes32(0));
        }

        function test_publishRoot_noOverwrite_revert() public {
            payout.publishRoot(1, keccak256("root"), META);

            vm.expectRevert(
                abi.encodeWithSelector(EpochPayout.EpochAlreadyPublished.selector, uint32(1))
            );
            payout.publishRoot(1, keccak256("root2"), META);
        }

        function test_publishRoot_strictMonotonic_revert() public {
            payout.publishRoot(5, keccak256("root"), META);

            // Lower epoch (3 < latestEpochId=5) — triggers EpochNotMonotonic
            vm.expectRevert(
                abi.encodeWithSelector(EpochPayout.EpochNotMonotonic.selector, uint32(3), uint32(5))
            );
            payout.publishRoot(3, keccak256("root3"), META2);
        }

        function test_publishRoot_happyPath() public {
            bytes32 root = keccak256("root");

            vm.expectEmit(true, false, false, true);
            emit EpochPayout.RootPublished(1, root, META);

            payout.publishRoot(1, root, META);

            assertEq(payout.rootOfEpoch(1), root);
            assertEq(payout.metadataHashOfEpoch(1), META);
            assertEq(payout.latestEpochId(), 1);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // claim
        // ═══════════════════════════════════════════════════════════════════════

        function test_claim_happyPath_referral() public {
            (, bytes32 leafA, bytes32 leafB) = _publishEpoch1();

            bytes32[] memory proof = MerkleTreeHelper.proofForFirst(leafB);
            uint256 balBefore = token.balanceOf(alice);

            vm.prank(alice);
            payout.claim(1, CAT_REFERRAL, alice, 500e6, proof, META);

            assertEq(token.balanceOf(alice), balBefore + 500e6);
            assertTrue(payout.claimedLeaf(leafA));
        }

        function test_claim_happyPath_partner() public {
            (, bytes32 leafA, bytes32 leafB) = _publishEpoch1();

            bytes32[] memory proof = MerkleTreeHelper.proofForSecond(leafA);
            uint256 balBefore = token.balanceOf(bob);

            vm.prank(bob);
            payout.claim(1, CAT_PARTNER, bob, 300e6, proof, META);

            assertEq(token.balanceOf(bob), balBefore + 300e6);
            assertTrue(payout.claimedLeaf(leafB));
        }

        function test_claim_thirdPartyCaller_fundsGoBeneficiary() public {
            (, bytes32 leafA,) = _publishEpoch1();

            bytes32[] memory proof = MerkleTreeHelper.proofForSecond(leafA);
            uint256 bobBefore = token.balanceOf(bob);
            uint256 strangerBefore = token.balanceOf(stranger);

            // stranger submits proof for bob
            vm.prank(stranger);
            payout.claim(1, CAT_PARTNER, bob, 300e6, proof, META);

            assertEq(token.balanceOf(bob), bobBefore + 300e6, "Funds should go to beneficiary");
            assertEq(token.balanceOf(stranger), strangerBefore, "Caller balance unchanged");
        }

        function test_claim_replay_revert() public {
            (, bytes32 leafA,) = _publishEpoch1();

            bytes32[] memory proof = MerkleTreeHelper.proofForSecond(leafA);
            payout.claim(1, CAT_PARTNER, bob, 300e6, proof, META);

            vm.expectRevert(EpochPayout.AlreadyClaimed.selector);
            payout.claim(1, CAT_PARTNER, bob, 300e6, proof, META);
        }

        function test_claim_wrongMetadataHash_revert() public {
            _publishEpoch1();

            bytes32[] memory proof = new bytes32[](0);
            bytes32 wrongMeta = keccak256("wrong");

            vm.expectRevert(EpochPayout.MetadataHashMismatch.selector);
            payout.claim(1, CAT_REFERRAL, alice, 500e6, proof, wrongMeta);
        }

        function test_claim_invalidProof_revert() public {
            _publishEpoch1();

            bytes32[] memory badProof = new bytes32[](1);
            badProof[0] = keccak256("garbage");

            vm.expectRevert(EpochPayout.InvalidProof.selector);
            payout.claim(1, CAT_REFERRAL, alice, 500e6, badProof, META);
        }

        function test_claim_whenPaused_revert() public {
            _publishEpoch1();
            payout.pause();

            bytes32[] memory proof = new bytes32[](0);

            vm.expectRevert("Pausable: paused");
            payout.claim(1, CAT_REFERRAL, alice, 500e6, proof, META);
        }

        function test_claim_zeroAmount_revert() public {
            _publishEpoch1();

            bytes32[] memory proof = new bytes32[](0);

            vm.expectRevert(EpochPayout.ZeroAmount.selector);
            payout.claim(1, CAT_REFERRAL, alice, 0, proof, META);
        }

        function test_claim_epochNotPublished_revert() public {
            bytes32[] memory proof = new bytes32[](0);

            vm.expectRevert(
                abi.encodeWithSelector(EpochPayout.EpochNotPublished.selector, uint32(99))
            );
            payout.claim(99, CAT_REFERRAL, alice, 100e6, proof, META);
        }

        function test_claim_insufficientFunds_revert() public {
            // Deploy a fresh payout with zero balance
            EpochPayout emptyPayout = new EpochPayout(address(token));

            bytes32 catRef = emptyPayout.CAT_REFERRAL();
            bytes32 catPart = emptyPayout.CAT_PARTNER();

            bytes32 leafA = emptyPayout.computeLeaf(1, catRef, alice, 500e6, META);
            bytes32 leafB = emptyPayout.computeLeaf(1, catPart, bob, 300e6, META);
            bytes32 root = MerkleTreeHelper.buildRoot(leafA, leafB);
            emptyPayout.publishRoot(1, root, META);

            bytes32[] memory proof = MerkleTreeHelper.proofForFirst(leafB);

            vm.expectRevert(
                abi.encodeWithSelector(EpochPayout.InsufficientFunds.selector, 500e6, 0)
            );
            emptyPayout.claim(1, catRef, alice, 500e6, proof, META);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // computeLeaf
        // ═══════════════════════════════════════════════════════════════════════

        function test_computeLeaf_matchesExpected() public view {
            // Double-hash to match OpenZeppelin StandardMerkleTree format:
            // leaf = keccak256(bytes.concat(keccak256(abi.encode(values))))
            bytes32 expected = keccak256(
                bytes.concat(
                    keccak256(
                        abi.encode(
                            block.chainid,
                            address(payout),
                            uint32(1),
                            CAT_REFERRAL,
                            alice,
                            address(token),
                            uint256(500e6),
                            META
                        )
                    )
                )
            );

            bytes32 actual = payout.computeLeaf(1, CAT_REFERRAL, alice, 500e6, META);
            assertEq(actual, expected);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // emergencySweep
        // ═══════════════════════════════════════════════════════════════════════

        function test_emergencySweep_requiresPaused() public {
            vm.expectRevert("EpochPayout: must be paused");
            payout.emergencySweep(address(token), owner, 1e6);
        }

        function test_emergencySweep_happyPath() public {
            payout.pause();
            uint256 ownerBefore = token.balanceOf(owner);
            payout.emergencySweep(address(token), owner, 1000e6);
            assertEq(token.balanceOf(owner), ownerBefore + 1000e6);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // FUZZ
        // ═══════════════════════════════════════════════════════════════════════

        function testFuzz_claim_variousAmounts(uint256 amount) public {
            amount = bound(amount, 1, POOL);

            // Build tree with one real leaf and one filler
            bytes32 leafA = payout.computeLeaf(1, CAT_REFERRAL, alice, amount, META);
            bytes32 leafB = keccak256(abi.encode("filler-leaf"));
            bytes32 root = MerkleTreeHelper.buildRoot(leafA, leafB);

            payout.publishRoot(1, root, META);

            bytes32[] memory proof = MerkleTreeHelper.proofForFirst(leafB);
            uint256 balBefore = token.balanceOf(alice);

            payout.claim(1, CAT_REFERRAL, alice, amount, proof, META);

            assertEq(token.balanceOf(alice), balBefore + amount);
            assertTrue(payout.claimedLeaf(leafA));
        }
    }
