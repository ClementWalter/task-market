// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IConditionalTokens
 * @notice Interface for Gnosis Conditional Tokens Framework
 */
interface IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;
    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) external pure returns (uint256);
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

/**
 * @title TaskMarket
 * @notice Prediction market-based task coordination with tradeable positions
 * @dev Integrates with Gnosis CTF for YES/NO outcome tokens
 *
 * Flow:
 * 1. Requester creates market with USDC → mints YES + NO tokens
 * 2. Anyone can buy/sell YES/NO tokens (bet on outcome)
 * 3. Deliverer completes task, claims delivery with proof
 * 4. After slashing period, oracle resolves market
 * 5. Winners redeem tokens for USDC
 */
contract TaskMarket is ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    bytes32 public constant PARENT_COLLECTION_ID = bytes32(0);
    uint256 public constant YES_INDEX = 1; // 0b01
    uint256 public constant NO_INDEX = 2; // 0b10

    // ============ Immutables ============
    IERC20 public immutable collateral;
    IConditionalTokens public immutable ctf;

    // ============ State ============
    uint256 public marketCount;
    uint256 public slashingPeriod = 1 hours;

    struct Market {
        address requester;
        address deliverer;
        string taskDescription;
        bytes32 questionId;
        bytes32 conditionId;
        uint256 yesTokenId;
        uint256 noTokenId;
        uint256 totalCollateral;
        uint256 deadline;
        uint256 claimTime;
        bytes32 proofHash;
        MarketState state;
    }

    enum MarketState {
        Open, // Waiting for deliverer
        Taken, // Someone committed to deliver
        Claimed, // Delivery claimed, in slashing period
        ResolvedYes, // Task completed (YES wins)
        ResolvedNo, // Task failed (NO wins)
        Cancelled
    }

    mapping(uint256 => Market) public markets;

    // ============ Events ============
    event MarketCreated(
        uint256 indexed marketId,
        address indexed requester,
        bytes32 conditionId,
        uint256 yesTokenId,
        uint256 noTokenId,
        uint256 collateralAmount,
        uint256 deadline
    );
    event MarketTaken(uint256 indexed marketId, address indexed deliverer);
    event DeliveryClaimed(uint256 indexed marketId, bytes32 proofHash);
    event MarketResolved(uint256 indexed marketId, bool yesWins);
    event TokensPurchased(uint256 indexed marketId, address indexed buyer, bool isYes, uint256 amount);

    // ============ Errors ============
    error InvalidState();
    error NotRequester();
    error NotDeliverer();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error SlashingPeriodNotOver();
    error ZeroAmount();
    error MarketNotResolved();

    // ============ Constructor ============
    constructor(address _collateral, address _ctf) {
        collateral = IERC20(_collateral);
        ctf = IConditionalTokens(_ctf);
    }

    // ============ Market Creation ============

    /**
     * @notice Create a new task market with tradeable YES/NO tokens
     * @param taskDescription What needs to be done
     * @param initialLiquidity USDC to seed the market (creates YES + NO tokens)
     * @param deadline Unix timestamp for task completion
     */
    function createMarket(string calldata taskDescription, uint256 initialLiquidity, uint256 deadline)
        external
        nonReentrant
        returns (uint256 marketId)
    {
        if (initialLiquidity == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlinePassed();

        marketId = marketCount++;

        // Generate unique question ID
        bytes32 questionId = keccak256(abi.encodePacked(marketId, msg.sender, block.timestamp, taskDescription));

        // Prepare condition in CTF (this contract is the oracle)
        ctf.prepareCondition(address(this), questionId, 2);

        // Get condition and token IDs
        bytes32 conditionId = ctf.getConditionId(address(this), questionId, 2);
        bytes32 yesCollectionId = ctf.getCollectionId(PARENT_COLLECTION_ID, conditionId, YES_INDEX);
        bytes32 noCollectionId = ctf.getCollectionId(PARENT_COLLECTION_ID, conditionId, NO_INDEX);
        uint256 yesTokenId = ctf.getPositionId(collateral, yesCollectionId);
        uint256 noTokenId = ctf.getPositionId(collateral, noCollectionId);

        markets[marketId] = Market({
            requester: msg.sender,
            deliverer: address(0),
            taskDescription: taskDescription,
            questionId: questionId,
            conditionId: conditionId,
            yesTokenId: yesTokenId,
            noTokenId: noTokenId,
            totalCollateral: initialLiquidity,
            deadline: deadline,
            claimTime: 0,
            proofHash: bytes32(0),
            state: MarketState.Open
        });

        // Transfer collateral and split into YES + NO tokens
        collateral.safeTransferFrom(msg.sender, address(this), initialLiquidity);
        collateral.approve(address(ctf), initialLiquidity);

        uint256[] memory partition = new uint256[](2);
        partition[0] = YES_INDEX;
        partition[1] = NO_INDEX;
        ctf.splitPosition(collateral, PARENT_COLLECTION_ID, conditionId, partition, initialLiquidity);

        // Give requester the NO tokens (they bet task won't be done)
        ctf.safeTransferFrom(address(this), msg.sender, noTokenId, initialLiquidity, "");

        // Keep YES tokens in contract for deliverer to claim

        emit MarketCreated(marketId, msg.sender, conditionId, yesTokenId, noTokenId, initialLiquidity, deadline);
    }

    // ============ Trading ============

    /**
     * @notice Buy YES tokens (bet task will be completed)
     * @dev Sends USDC, receives YES tokens from contract reserves
     */
    function buyYes(uint256 marketId, uint256 amount) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.state != MarketState.Open && market.state != MarketState.Taken) revert InvalidState();
        if (amount == 0) revert ZeroAmount();

        // Simple 1:1 exchange - more sophisticated AMM could be added
        uint256 available = ctf.balanceOf(address(this), market.yesTokenId);
        require(amount <= available, "Insufficient YES tokens");

        collateral.safeTransferFrom(msg.sender, address(this), amount);
        market.totalCollateral += amount;

        ctf.safeTransferFrom(address(this), msg.sender, market.yesTokenId, amount, "");

        emit TokensPurchased(marketId, msg.sender, true, amount);
    }

    /**
     * @notice Sell YES tokens back to the contract
     */
    function sellYes(uint256 marketId, uint256 amount) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.state != MarketState.Open && market.state != MarketState.Taken) revert InvalidState();
        if (amount == 0) revert ZeroAmount();

        // Transfer YES tokens to contract
        ctf.safeTransferFrom(msg.sender, address(this), market.yesTokenId, amount, "");

        // Return collateral
        collateral.safeTransfer(msg.sender, amount);
        market.totalCollateral -= amount;
    }

    // ============ Task Flow ============

    /**
     * @notice Take the market - commit to delivering the task
     * @dev Deliverer can later claim YES tokens upon completion
     */
    function takeMarket(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.state != MarketState.Open) revert InvalidState();
        if (block.timestamp >= market.deadline) revert DeadlinePassed();

        market.deliverer = msg.sender;
        market.state = MarketState.Taken;

        emit MarketTaken(marketId, msg.sender);
    }

    /**
     * @notice Claim delivery with proof hash
     */
    function claimDelivery(uint256 marketId, bytes32 proofHash) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.state != MarketState.Taken) revert InvalidState();
        if (msg.sender != market.deliverer) revert NotDeliverer();
        if (block.timestamp > market.deadline) revert DeadlinePassed();

        market.proofHash = proofHash;
        market.claimTime = block.timestamp;
        market.state = MarketState.Claimed;

        emit DeliveryClaimed(marketId, proofHash);
    }

    // ============ Resolution ============

    /**
     * @notice Resolve market as YES (task completed)
     * @dev Only after slashing period
     */
    function resolveYes(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.state != MarketState.Claimed) revert InvalidState();
        if (block.timestamp < market.claimTime + slashingPeriod) revert SlashingPeriodNotOver();

        market.state = MarketState.ResolvedYes;

        // Report to CTF: YES wins
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES
        payouts[1] = 0; // NO
        ctf.reportPayouts(market.questionId, payouts);

        emit MarketResolved(marketId, true);
    }

    /**
     * @notice Resolve market as NO (task failed)
     * @dev Deadline passed without valid claim
     */
    function resolveNo(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];

        bool canResolveNo = (market.state == MarketState.Open || market.state == MarketState.Taken)
            && block.timestamp > market.deadline;

        if (!canResolveNo) revert InvalidState();

        market.state = MarketState.ResolvedNo;

        // Report to CTF: NO wins
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0; // YES
        payouts[1] = 1; // NO
        ctf.reportPayouts(market.questionId, payouts);

        emit MarketResolved(marketId, false);
    }

    // ============ Redemption ============

    /**
     * @notice Redeem winning tokens for collateral
     * @dev Call CTF directly to redeem, this is a helper
     */
    function redeem(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        if (market.state != MarketState.ResolvedYes && market.state != MarketState.ResolvedNo) {
            revert MarketNotResolved();
        }

        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = YES_INDEX;
        indexSets[1] = NO_INDEX;

        // Redeem on behalf of caller (they need to have the winning tokens)
        ctf.redeemPositions(collateral, PARENT_COLLECTION_ID, market.conditionId, indexSets);
    }

    // ============ View Functions ============

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function getTokenIds(uint256 marketId) external view returns (uint256 yesTokenId, uint256 noTokenId) {
        Market storage market = markets[marketId];
        return (market.yesTokenId, market.noTokenId);
    }

    function setSlashingPeriod(uint256 _period) external {
        // TODO: Add access control
        slashingPeriod = _period;
    }
}
