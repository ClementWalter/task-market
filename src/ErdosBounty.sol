// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ErdosBounty
 * @notice Collaborative bounty system for solving ONE mathematical problem together
 * @dev Proof of Effective Collaboration — agents contribute, verify, and share rewards
 *
 * Example: "Verify Collatz conjecture for n = 1 to 10^12"
 * - Problem split into ranges
 * - Agents claim ranges, compute, submit proofs
 * - Other agents verify (spot-check)
 * - When 100% complete, rewards distributed by contribution
 */
contract ErdosBounty is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Structs ============
    struct Bounty {
        address sponsor;
        string problemStatement;
        uint256 totalRanges; // Total work units
        uint256 rangeSize; // Size of each range (e.g., 1 million numbers)
        uint256 bountyPool; // Total USDC reward
        uint256 stakePerRange; // Required stake to claim a range
        uint256 deadline;
        uint256 createdAt;
        uint256 completedRanges;
        bool solved;
        bool cancelled;
    }

    struct RangeWork {
        address worker;
        bytes32 proofHash; // Merkle root of results
        uint256 claimedAt;
        uint256 submittedAt;
        uint256 verificationCount;
        bool verified; // Meets verification threshold
        bool slashed;
    }

    struct Contribution {
        uint256 rangesCompleted;
        uint256 verificationsPerformed;
        uint256 firstContributionTime;
        uint256 stakedAmount;
        bool claimed;
    }

    // ============ Constants ============
    uint256 public constant CLAIM_TIMEOUT = 2 hours;
    uint256 public constant VERIFICATION_THRESHOLD = 2;
    uint256 public constant EARLY_BONUS_PERCENT = 10; // First 10% of work
    uint256 public constant EARLY_MULTIPLIER = 200; // 2x for early work
    uint256 public constant VERIFIER_REWARD_BPS = 500; // 5% of range reward to verifiers

    // ============ State ============
    IERC20 public immutable usdc;
    uint256 public bountyCount;

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(uint256 => RangeWork)) public rangeWork; // bountyId => rangeId => work
    mapping(uint256 => mapping(address => Contribution)) public contributions; // bountyId => agent => contribution
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasVerified; // bountyId => rangeId => verifier => verified

    // ============ Events ============
    event BountyCreated(
        uint256 indexed bountyId,
        address indexed sponsor,
        string problemStatement,
        uint256 totalRanges,
        uint256 bountyPool,
        uint256 deadline
    );
    event RangeClaimed(uint256 indexed bountyId, uint256 indexed rangeId, address indexed worker);
    event WorkSubmitted(uint256 indexed bountyId, uint256 indexed rangeId, address indexed worker, bytes32 proofHash);
    event RangeVerified(uint256 indexed bountyId, uint256 indexed rangeId, address indexed verifier);
    event FraudReported(uint256 indexed bountyId, uint256 indexed rangeId, address indexed reporter);
    event BountySolved(uint256 indexed bountyId, uint256 totalContributors);
    event RewardsClaimed(uint256 indexed bountyId, address indexed agent, uint256 amount);

    // ============ Errors ============
    error BountyNotActive();
    error RangeAlreadyClaimed();
    error RangeNotClaimed();
    error NotRangeWorker();
    error ClaimTimeout();
    error AlreadyVerified();
    error CannotVerifyOwnWork();
    error InsufficientStake();
    error BountyNotSolved();
    error AlreadyClaimed();
    error InvalidRange();
    error DeadlinePassed();

    // ============ Constructor ============
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    // ============ Bounty Creation ============

    /**
     * @notice Create a new collaborative bounty
     * @param problemStatement Description of the problem to solve
     * @param totalRanges Number of work units to split into
     * @param rangeSize Size of each range (for documentation)
     * @param bountyPool Total USDC reward
     * @param stakePerRange USDC stake required to claim each range
     * @param durationSeconds Time until deadline
     */
    function createBounty(
        string calldata problemStatement,
        uint256 totalRanges,
        uint256 rangeSize,
        uint256 bountyPool,
        uint256 stakePerRange,
        uint256 durationSeconds
    ) external nonReentrant returns (uint256 bountyId) {
        require(totalRanges > 0, "No ranges");
        require(bountyPool > 0, "No bounty");

        bountyId = bountyCount++;

        bounties[bountyId] = Bounty({
            sponsor: msg.sender,
            problemStatement: problemStatement,
            totalRanges: totalRanges,
            rangeSize: rangeSize,
            bountyPool: bountyPool,
            stakePerRange: stakePerRange,
            deadline: block.timestamp + durationSeconds,
            createdAt: block.timestamp,
            completedRanges: 0,
            solved: false,
            cancelled: false
        });

        usdc.safeTransferFrom(msg.sender, address(this), bountyPool);

        emit BountyCreated(
            bountyId, msg.sender, problemStatement, totalRanges, bountyPool, block.timestamp + durationSeconds
        );
    }

    // ============ Work Flow ============

    /**
     * @notice Claim a range to work on
     * @param bountyId The bounty
     * @param rangeId The range to claim (0 to totalRanges-1)
     */
    function claimRange(uint256 bountyId, uint256 rangeId) external nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        RangeWork storage work = rangeWork[bountyId][rangeId];

        if (bounty.solved || bounty.cancelled) revert BountyNotActive();
        if (block.timestamp > bounty.deadline) revert DeadlinePassed();
        if (rangeId >= bounty.totalRanges) revert InvalidRange();

        // Check if range is available (not claimed, or claim timed out)
        if (work.worker != address(0)) {
            if (work.submittedAt > 0) revert RangeAlreadyClaimed(); // Already submitted
            if (block.timestamp < work.claimedAt + CLAIM_TIMEOUT) revert RangeAlreadyClaimed(); // Still in timeout
            // Else: previous claim timed out, slash their stake
            _slashWorker(bountyId, rangeId);
        }

        // Stake required
        if (bounty.stakePerRange > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), bounty.stakePerRange);
            contributions[bountyId][msg.sender].stakedAmount += bounty.stakePerRange;
        }

        work.worker = msg.sender;
        work.claimedAt = block.timestamp;
        work.submittedAt = 0;
        work.proofHash = bytes32(0);
        work.verificationCount = 0;
        work.verified = false;
        work.slashed = false;

        // Track first contribution time for early bonus
        if (contributions[bountyId][msg.sender].firstContributionTime == 0) {
            contributions[bountyId][msg.sender].firstContributionTime = block.timestamp;
        }

        emit RangeClaimed(bountyId, rangeId, msg.sender);
    }

    /**
     * @notice Submit work for a claimed range
     * @param bountyId The bounty
     * @param rangeId The range
     * @param proofHash Merkle root or hash of the computation results
     */
    function submitWork(uint256 bountyId, uint256 rangeId, bytes32 proofHash) external nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        RangeWork storage work = rangeWork[bountyId][rangeId];

        if (bounty.solved || bounty.cancelled) revert BountyNotActive();
        if (work.worker != msg.sender) revert NotRangeWorker();
        if (work.submittedAt > 0) revert RangeAlreadyClaimed(); // Already submitted
        if (block.timestamp > work.claimedAt + CLAIM_TIMEOUT) revert ClaimTimeout();

        work.proofHash = proofHash;
        work.submittedAt = block.timestamp;

        emit WorkSubmitted(bountyId, rangeId, msg.sender, proofHash);
    }

    /**
     * @notice Verify another agent's work
     * @param bountyId The bounty
     * @param rangeId The range to verify
     * @param isValid Whether the work is valid
     */
    function verifyWork(uint256 bountyId, uint256 rangeId, bool isValid) external nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        RangeWork storage work = rangeWork[bountyId][rangeId];

        if (bounty.solved) revert BountyNotActive();
        if (work.submittedAt == 0) revert RangeNotClaimed();
        if (work.worker == msg.sender) revert CannotVerifyOwnWork();
        if (hasVerified[bountyId][rangeId][msg.sender]) revert AlreadyVerified();
        if (work.slashed) revert BountyNotActive();

        hasVerified[bountyId][rangeId][msg.sender] = true;

        if (isValid) {
            work.verificationCount++;
            contributions[bountyId][msg.sender].verificationsPerformed++;

            // Check if verification threshold met
            if (!work.verified && work.verificationCount >= VERIFICATION_THRESHOLD) {
                work.verified = true;
                bounty.completedRanges++;
                contributions[bountyId][work.worker].rangesCompleted++;

                // Check if bounty is solved
                if (bounty.completedRanges >= bounty.totalRanges) {
                    bounty.solved = true;
                    emit BountySolved(bountyId, _countContributors(bountyId));
                }
            }

            emit RangeVerified(bountyId, rangeId, msg.sender);
        } else {
            // Fraud reported - for POC, just emit event
            // In production: require fraud proof, slash if confirmed
            emit FraudReported(bountyId, rangeId, msg.sender);
        }
    }

    // ============ Rewards ============

    /**
     * @notice Claim rewards after bounty is solved
     * @param bountyId The bounty
     */
    function claimRewards(uint256 bountyId) external nonReentrant {
        Bounty storage bounty = bounties[bountyId];
        Contribution storage contrib = contributions[bountyId][msg.sender];

        if (!bounty.solved) revert BountyNotSolved();
        if (contrib.claimed) revert AlreadyClaimed();
        if (contrib.rangesCompleted == 0 && contrib.verificationsPerformed == 0) revert AlreadyClaimed();

        contrib.claimed = true;

        uint256 reward = calculateReward(bountyId, msg.sender);

        // Return stake
        uint256 totalPayout = reward + contrib.stakedAmount;

        if (totalPayout > 0) {
            usdc.safeTransfer(msg.sender, totalPayout);
        }

        emit RewardsClaimed(bountyId, msg.sender, reward);
    }

    /**
     * @notice Calculate reward for an agent
     */
    function calculateReward(uint256 bountyId, address agent) public view returns (uint256) {
        Bounty storage bounty = bounties[bountyId];
        Contribution storage contrib = contributions[bountyId][agent];

        if (!bounty.solved || contrib.rangesCompleted == 0) {
            // Verifier-only reward
            if (contrib.verificationsPerformed > 0) {
                uint256 verifierPool = (bounty.bountyPool * VERIFIER_REWARD_BPS) / 10000;
                // Simple: proportional to verifications
                // In production: weight by total verifications
                return verifierPool / bounty.totalRanges * contrib.verificationsPerformed / VERIFICATION_THRESHOLD;
            }
            return 0;
        }

        // Worker reward
        uint256 workerPool = (bounty.bountyPool * (10000 - VERIFIER_REWARD_BPS)) / 10000;

        // Base share
        uint256 baseShare = (workerPool * contrib.rangesCompleted) / bounty.totalRanges;

        // Early bonus: first 10% of work gets 2x multiplier
        uint256 earlyThreshold = (bounty.totalRanges * EARLY_BONUS_PERCENT) / 100;
        if (contrib.rangesCompleted <= earlyThreshold) {
            // Check if they were in the early period
            uint256 earlyDeadline =
                bounty.createdAt + ((bounty.deadline - bounty.createdAt) * EARLY_BONUS_PERCENT) / 100;
            if (contrib.firstContributionTime <= earlyDeadline) {
                baseShare = (baseShare * EARLY_MULTIPLIER) / 100;
            }
        }

        // Verification bonus: +10% per verification performed
        uint256 verificationBonus = (baseShare * contrib.verificationsPerformed * 10) / 100;

        return baseShare + verificationBonus;
    }

    // ============ Internal ============

    function _slashWorker(uint256 bountyId, uint256 rangeId) internal {
        RangeWork storage work = rangeWork[bountyId][rangeId];
        Bounty storage bounty = bounties[bountyId];

        if (work.worker != address(0) && !work.slashed) {
            work.slashed = true;
            // Stake goes to bounty pool (benefits other contributors)
            bounty.bountyPool += contributions[bountyId][work.worker].stakedAmount;
            contributions[bountyId][work.worker].stakedAmount = 0;
        }
    }

    function _countContributors(uint256 bountyId) internal view returns (uint256) {
        // Simplified: return completed ranges as proxy
        return bounties[bountyId].completedRanges;
    }

    // ============ View Functions ============

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return bounties[bountyId];
    }

    function getRangeWork(uint256 bountyId, uint256 rangeId) external view returns (RangeWork memory) {
        return rangeWork[bountyId][rangeId];
    }

    function getContribution(uint256 bountyId, address agent) external view returns (Contribution memory) {
        return contributions[bountyId][agent];
    }

    function getProgress(uint256 bountyId)
        external
        view
        returns (uint256 completed, uint256 total, uint256 percentComplete)
    {
        Bounty storage bounty = bounties[bountyId];
        completed = bounty.completedRanges;
        total = bounty.totalRanges;
        percentComplete = (completed * 100) / total;
    }
}
