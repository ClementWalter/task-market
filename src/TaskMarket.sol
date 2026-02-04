// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TaskMarket
 * @notice Prediction market-based task coordination for AI agents
 * @dev Every task is a prediction market: "This task will be completed by deadline"
 * 
 * Flow:
 * 1. Requester creates market: "I want X done" + stakes USDC on NO
 * 2. Deliverer takes market: commits hash + stakes USDC on YES → market LOCKED
 * 3. Deliverer reveals preimage (proof of delivery)
 * 4. Slashing period: anyone can challenge invalid proofs
 * 5. After timeout: funds released to winner
 */
contract TaskMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Enums ============
    enum MarketState {
        Open,           // Waiting for deliverer
        Locked,         // Deliverer committed, task in progress
        Revealed,       // Proof revealed, in slashing period
        Completed,      // Funds claimed by deliverer
        Cancelled,      // Requester cancelled (before lock)
        Expired,        // Deadline passed, no delivery
        Slashed         // Deliverer slashed (future: dispute resolution)
    }

    // ============ Structs ============
    struct Market {
        // Parties
        address requester;
        address deliverer;
        
        // Task details
        string taskDescription;
        uint256 stake;              // USDC amount staked by each side
        
        // Timing
        uint256 createdAt;
        uint256 taskDeadline;       // Deliverer must reveal by this time
        uint256 slashDeadline;      // Challenge period ends here
        
        // Commitment scheme
        bytes32 commitmentHash;     // H(proof + salt) - submitted at take
        bytes32 revealedProof;      // The actual proof, revealed later
        
        // State
        MarketState state;
    }

    // ============ State ============
    IERC20 public immutable usdc;
    uint256 public marketCount;
    uint256 public slashingPeriod = 1 hours; // Configurable challenge window
    
    mapping(uint256 => Market) public markets;

    // ============ Events ============
    event MarketCreated(
        uint256 indexed marketId,
        address indexed requester,
        string taskDescription,
        uint256 stake,
        uint256 taskDeadline
    );
    
    event MarketTaken(
        uint256 indexed marketId,
        address indexed deliverer,
        bytes32 commitmentHash
    );
    
    event DeliveryRevealed(
        uint256 indexed marketId,
        bytes32 proof,
        uint256 slashDeadline
    );
    
    event MarketCompleted(
        uint256 indexed marketId,
        address indexed winner,
        uint256 payout
    );
    
    event MarketCancelled(uint256 indexed marketId);
    event MarketExpired(uint256 indexed marketId);
    event MarketSlashed(uint256 indexed marketId, address indexed challenger);

    // ============ Errors ============
    error InvalidState();
    error NotRequester();
    error NotDeliverer();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error SlashingPeriodNotOver();
    error InvalidCommitment();
    error ZeroStake();
    error ZeroDeadline();

    // ============ Constructor ============
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    // ============ Core Functions ============

    /**
     * @notice Create a new task market
     * @param taskDescription What needs to be done
     * @param stake USDC amount to stake (same for both sides)
     * @param taskDeadline Unix timestamp by which task must be completed
     */
    function createMarket(
        string calldata taskDescription,
        uint256 stake,
        uint256 taskDeadline
    ) external nonReentrant returns (uint256 marketId) {
        if (stake == 0) revert ZeroStake();
        if (taskDeadline <= block.timestamp) revert ZeroDeadline();

        marketId = marketCount++;
        
        markets[marketId] = Market({
            requester: msg.sender,
            deliverer: address(0),
            taskDescription: taskDescription,
            stake: stake,
            createdAt: block.timestamp,
            taskDeadline: taskDeadline,
            slashDeadline: 0,
            commitmentHash: bytes32(0),
            revealedProof: bytes32(0),
            state: MarketState.Open
        });

        // Transfer stake from requester
        usdc.safeTransferFrom(msg.sender, address(this), stake);

        emit MarketCreated(marketId, msg.sender, taskDescription, stake, taskDeadline);
    }

    /**
     * @notice Take a market and commit to delivering
     * @param marketId The market to take
     * @param commitmentHash Hash of (proof + salt) - proves you know the proof before delivering
     */
    function takeMarket(
        uint256 marketId,
        bytes32 commitmentHash
    ) external nonReentrant {
        Market storage market = markets[marketId];
        
        if (market.state != MarketState.Open) revert InvalidState();
        if (block.timestamp >= market.taskDeadline) revert DeadlinePassed();

        market.deliverer = msg.sender;
        market.commitmentHash = commitmentHash;
        market.state = MarketState.Locked;

        // Transfer stake from deliverer
        usdc.safeTransferFrom(msg.sender, address(this), market.stake);

        emit MarketTaken(marketId, msg.sender, commitmentHash);
    }

    /**
     * @notice Reveal the proof of delivery
     * @param marketId The market
     * @param proof The actual proof (preimage)
     * @param salt Random salt used in commitment
     */
    function revealDelivery(
        uint256 marketId,
        bytes32 proof,
        bytes32 salt
    ) external nonReentrant {
        Market storage market = markets[marketId];
        
        if (market.state != MarketState.Locked) revert InvalidState();
        if (msg.sender != market.deliverer) revert NotDeliverer();
        if (block.timestamp > market.taskDeadline) revert DeadlinePassed();
        
        // Verify commitment
        bytes32 expectedHash = keccak256(abi.encodePacked(proof, salt));
        if (expectedHash != market.commitmentHash) revert InvalidCommitment();

        market.revealedProof = proof;
        market.slashDeadline = block.timestamp + slashingPeriod;
        market.state = MarketState.Revealed;

        emit DeliveryRevealed(marketId, proof, market.slashDeadline);
    }

    /**
     * @notice Claim funds after successful delivery (slashing period over)
     * @param marketId The market
     */
    function claimFunds(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        
        if (market.state != MarketState.Revealed) revert InvalidState();
        if (block.timestamp < market.slashDeadline) revert SlashingPeriodNotOver();

        market.state = MarketState.Completed;
        
        // Deliverer wins both stakes
        uint256 payout = market.stake * 2;
        usdc.safeTransfer(market.deliverer, payout);

        emit MarketCompleted(marketId, market.deliverer, payout);
    }

    /**
     * @notice Cancel an open market (only requester, only if not taken)
     * @param marketId The market
     */
    function cancelMarket(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        
        if (market.state != MarketState.Open) revert InvalidState();
        if (msg.sender != market.requester) revert NotRequester();

        market.state = MarketState.Cancelled;
        
        // Return stake to requester
        usdc.safeTransfer(market.requester, market.stake);

        emit MarketCancelled(marketId);
    }

    /**
     * @notice Claim funds when deliverer failed (deadline passed without reveal)
     * @param marketId The market
     */
    function claimExpired(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        
        // Can claim if: Locked and deadline passed, OR Open and deadline passed
        bool isLockedExpired = market.state == MarketState.Locked && 
                               block.timestamp > market.taskDeadline;
        bool isOpenExpired = market.state == MarketState.Open && 
                             block.timestamp > market.taskDeadline;
        
        if (!isLockedExpired && !isOpenExpired) revert InvalidState();

        market.state = MarketState.Expired;
        
        if (isLockedExpired) {
            // Requester wins both stakes (deliverer failed)
            usdc.safeTransfer(market.requester, market.stake * 2);
            emit MarketCompleted(marketId, market.requester, market.stake * 2);
        } else {
            // Just return requester's stake (no taker)
            usdc.safeTransfer(market.requester, market.stake);
            emit MarketCancelled(marketId);
        }
    }

    /**
     * @notice Slash a fraudulent delivery (stub for v1 - always reverts)
     * @dev In v2: implement dispute resolution with multi-agent oracle
     */
    function slash(uint256 marketId, bytes calldata /* evidence */) external pure {
        // Stub: slashing mechanism designed but not implemented in POC
        // In production: multi-agent oracle votes on validity
        revert("Slashing not implemented in POC");
    }

    // ============ View Functions ============

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function getOpenMarkets(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](limit);
        uint256 count = 0;
        
        for (uint256 i = offset; i < marketCount && count < limit; i++) {
            if (markets[i].state == MarketState.Open) {
                result[count++] = i;
            }
        }
        
        // Resize array
        assembly {
            mstore(result, count)
        }
        return result;
    }

    function setSlashingPeriod(uint256 _period) external {
        // In production: add access control
        slashingPeriod = _period;
    }
}
