// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ErdosBounty.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract ErdosBountyTest is Test {
    ErdosBounty public bounty;
    MockUSDC public usdc;

    address public sponsor = address(0x1);
    address public worker1 = address(0x2);
    address public worker2 = address(0x3);
    address public verifier1 = address(0x4);
    address public verifier2 = address(0x5);

    uint256 public constant BOUNTY_POOL = 1000 * 10 ** 6; // 1000 USDC
    uint256 public constant STAKE_PER_RANGE = 10 * 10 ** 6; // 10 USDC
    uint256 public constant TOTAL_RANGES = 10;

    function setUp() public {
        usdc = new MockUSDC();
        bounty = new ErdosBounty(address(usdc));

        // Fund accounts
        usdc.mint(sponsor, 10000 * 10 ** 6);
        usdc.mint(worker1, 1000 * 10 ** 6);
        usdc.mint(worker2, 1000 * 10 ** 6);
        usdc.mint(verifier1, 1000 * 10 ** 6);
        usdc.mint(verifier2, 1000 * 10 ** 6);

        // Approve
        vm.prank(sponsor);
        usdc.approve(address(bounty), type(uint256).max);
        vm.prank(worker1);
        usdc.approve(address(bounty), type(uint256).max);
        vm.prank(worker2);
        usdc.approve(address(bounty), type(uint256).max);
    }

    function testCreateBounty() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty(
            "Verify Collatz for n = 1 to 10 million",
            TOTAL_RANGES,
            1_000_000, // 1M numbers per range
            BOUNTY_POOL,
            STAKE_PER_RANGE,
            7 days
        );

        ErdosBounty.Bounty memory b = bounty.getBounty(bountyId);

        assertEq(b.sponsor, sponsor);
        assertEq(b.totalRanges, TOTAL_RANGES);
        assertEq(b.bountyPool, BOUNTY_POOL);
        assertEq(b.completedRanges, 0);
        assertFalse(b.solved);
    }

    function testClaimAndSubmitWork() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", TOTAL_RANGES, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        // Worker claims range 0
        vm.prank(worker1);
        bounty.claimRange(bountyId, 0);

        ErdosBounty.RangeWork memory work = bounty.getRangeWork(bountyId, 0);
        assertEq(work.worker, worker1);

        // Submit work
        bytes32 proofHash = keccak256("merkle_root_of_results");
        vm.prank(worker1);
        bounty.submitWork(bountyId, 0, proofHash);

        work = bounty.getRangeWork(bountyId, 0);
        assertEq(work.proofHash, proofHash);
        assertGt(work.submittedAt, 0);
    }

    function testVerificationFlow() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", TOTAL_RANGES, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        // Worker claims and submits
        vm.prank(worker1);
        bounty.claimRange(bountyId, 0);

        vm.prank(worker1);
        bounty.submitWork(bountyId, 0, keccak256("proof"));

        // Verifier 1 verifies
        vm.prank(verifier1);
        bounty.verifyWork(bountyId, 0, true);

        ErdosBounty.RangeWork memory work = bounty.getRangeWork(bountyId, 0);
        assertEq(work.verificationCount, 1);
        assertFalse(work.verified); // Need 2 verifications

        // Verifier 2 verifies
        vm.prank(verifier2);
        bounty.verifyWork(bountyId, 0, true);

        work = bounty.getRangeWork(bountyId, 0);
        assertEq(work.verificationCount, 2);
        assertTrue(work.verified);

        // Check contribution updated
        ErdosBounty.Contribution memory contrib = bounty.getContribution(bountyId, worker1);
        assertEq(contrib.rangesCompleted, 1);
    }

    function testFullBountySolved() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", 3, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        // Complete all 3 ranges
        for (uint256 i = 0; i < 3; i++) {
            address worker = i % 2 == 0 ? worker1 : worker2;

            vm.prank(worker);
            bounty.claimRange(bountyId, i);

            vm.prank(worker);
            bounty.submitWork(bountyId, i, keccak256(abi.encodePacked("proof", i)));

            // Two verifications
            vm.prank(verifier1);
            bounty.verifyWork(bountyId, i, true);

            vm.prank(verifier2);
            bounty.verifyWork(bountyId, i, true);
        }

        ErdosBounty.Bounty memory b = bounty.getBounty(bountyId);
        assertTrue(b.solved);
        assertEq(b.completedRanges, 3);
    }

    function testClaimRewards() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", 2, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        // Worker1 does range 0
        vm.prank(worker1);
        bounty.claimRange(bountyId, 0);
        vm.prank(worker1);
        bounty.submitWork(bountyId, 0, keccak256("proof0"));

        // Worker2 does range 1
        vm.prank(worker2);
        bounty.claimRange(bountyId, 1);
        vm.prank(worker2);
        bounty.submitWork(bountyId, 1, keccak256("proof1"));

        // Verify both
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(verifier1);
            bounty.verifyWork(bountyId, i, true);
            vm.prank(verifier2);
            bounty.verifyWork(bountyId, i, true);
        }

        assertTrue(bounty.getBounty(bountyId).solved);

        // Claim rewards
        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        vm.prank(worker1);
        bounty.claimRewards(bountyId);
        uint256 worker1BalanceAfter = usdc.balanceOf(worker1);

        // Should get reward + stake back
        assertGt(worker1BalanceAfter, worker1BalanceBefore);
    }

    function testCannotVerifyOwnWork() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", 2, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        vm.prank(worker1);
        bounty.claimRange(bountyId, 0);
        vm.prank(worker1);
        bounty.submitWork(bountyId, 0, keccak256("proof"));

        // Worker cannot verify own work
        vm.expectRevert(ErdosBounty.CannotVerifyOwnWork.selector);
        vm.prank(worker1);
        bounty.verifyWork(bountyId, 0, true);
    }

    function testClaimTimeout() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", 2, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        vm.prank(worker1);
        bounty.claimRange(bountyId, 0);

        // Time passes without submission
        vm.warp(block.timestamp + 3 hours);

        // Another worker can claim the timed-out range
        vm.prank(worker2);
        bounty.claimRange(bountyId, 0);

        ErdosBounty.RangeWork memory work = bounty.getRangeWork(bountyId, 0);
        assertEq(work.worker, worker2);
    }

    function testProgress() public {
        vm.prank(sponsor);
        uint256 bountyId = bounty.createBounty("Test", 10, 1000, BOUNTY_POOL, STAKE_PER_RANGE, 7 days);

        // Complete 3 ranges
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(worker1);
            bounty.claimRange(bountyId, i);
            vm.prank(worker1);
            bounty.submitWork(bountyId, i, keccak256(abi.encodePacked(i)));
            vm.prank(verifier1);
            bounty.verifyWork(bountyId, i, true);
            vm.prank(verifier2);
            bounty.verifyWork(bountyId, i, true);
        }

        (uint256 completed, uint256 total, uint256 percent) = bounty.getProgress(bountyId);
        assertEq(completed, 3);
        assertEq(total, 10);
        assertEq(percent, 30);
    }
}
