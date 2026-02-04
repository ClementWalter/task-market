// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TaskMarket.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6); // 1M USDC
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TaskMarketTest is Test {
    TaskMarket public market;
    MockUSDC public usdc;

    address public requester = address(0x1);
    address public deliverer = address(0x2);

    uint256 public constant STAKE = 100 * 10 ** 6; // 100 USDC

    function setUp() public {
        usdc = new MockUSDC();
        market = new TaskMarket(address(usdc));

        // Fund test accounts
        usdc.mint(requester, 1000 * 10 ** 6);
        usdc.mint(deliverer, 1000 * 10 ** 6);

        // Approve market to spend
        vm.prank(requester);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(deliverer);
        usdc.approve(address(market), type(uint256).max);
    }

    function testCreateMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee to 123 Main St", STAKE, block.timestamp + 1 hours);

        TaskMarket.Market memory m = market.getMarket(marketId);

        assertEq(m.requester, requester);
        assertEq(m.stake, STAKE);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Open));
    }

    function testTakeMarket() public {
        // Create market
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", STAKE, block.timestamp + 1 hours);

        // Take market (no commitment needed now)
        vm.prank(deliverer);
        market.takeMarket(marketId);

        TaskMarket.Market memory m = market.getMarket(marketId);

        assertEq(m.deliverer, deliverer);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Taken));
        // No commitment hash at take time
        assertEq(m.commitmentHash, bytes32(0));
    }

    function testFullFlow() public {
        // 1. Create market
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", STAKE, block.timestamp + 1 hours);

        // 2. Take market (just stake, no commitment)
        vm.prank(deliverer);
        market.takeMarket(marketId);

        TaskMarket.Market memory m = market.getMarket(marketId);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Taken));

        // 3. [Deliverer does the task IRL]

        // 4. Claim delivery with proof hash
        bytes32 proofHash = keccak256("delivery_photo_ipfs_hash_12345");
        vm.prank(deliverer);
        market.claimDelivery(marketId, proofHash);

        m = market.getMarket(marketId);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Claimed));
        assertEq(m.commitmentHash, proofHash);

        // 5. Wait for slashing period
        vm.warp(block.timestamp + 2 hours);

        // 6. Claim funds
        uint256 balanceBefore = usdc.balanceOf(deliverer);

        vm.prank(deliverer);
        market.claimFunds(marketId);

        uint256 balanceAfter = usdc.balanceOf(deliverer);

        // Deliverer should receive both stakes (200 USDC)
        assertEq(balanceAfter - balanceBefore, STAKE * 2);

        m = market.getMarket(marketId);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Completed));
    }

    function testCancelMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", STAKE, block.timestamp + 1 hours);

        uint256 balanceBefore = usdc.balanceOf(requester);

        vm.prank(requester);
        market.cancelMarket(marketId);

        uint256 balanceAfter = usdc.balanceOf(requester);
        assertEq(balanceAfter - balanceBefore, STAKE);
    }

    function testExpiredMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", STAKE, block.timestamp + 1 hours);

        // Take market
        vm.prank(deliverer);
        market.takeMarket(marketId);

        // Time passes, deliverer fails to claim delivery
        vm.warp(block.timestamp + 2 hours);

        uint256 balanceBefore = usdc.balanceOf(requester);

        // Requester claims (deliverer failed)
        market.claimExpired(marketId);

        uint256 balanceAfter = usdc.balanceOf(requester);

        // Requester gets both stakes
        assertEq(balanceAfter - balanceBefore, STAKE * 2);
    }

    function testCannotClaimBeforeSlashingPeriod() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", STAKE, block.timestamp + 1 hours);

        vm.prank(deliverer);
        market.takeMarket(marketId);

        vm.prank(deliverer);
        market.claimDelivery(marketId, keccak256("proof"));

        // Try to claim immediately (should fail)
        vm.expectRevert(TaskMarket.SlashingPeriodNotOver.selector);
        vm.prank(deliverer);
        market.claimFunds(marketId);
    }

    function testOnlyDelivererCanClaim() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", STAKE, block.timestamp + 1 hours);

        vm.prank(deliverer);
        market.takeMarket(marketId);

        // Someone else tries to claim delivery
        vm.expectRevert(TaskMarket.NotDeliverer.selector);
        vm.prank(requester);
        market.claimDelivery(marketId, keccak256("proof"));
    }
}
