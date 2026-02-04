// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TaskMarket.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000 * 10**6); // 1M USDC
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
    
    uint256 public constant STAKE = 100 * 10**6; // 100 USDC
    
    function setUp() public {
        usdc = new MockUSDC();
        market = new TaskMarket(address(usdc));
        
        // Fund test accounts
        usdc.mint(requester, 1000 * 10**6);
        usdc.mint(deliverer, 1000 * 10**6);
        
        // Approve market to spend
        vm.prank(requester);
        usdc.approve(address(market), type(uint256).max);
        
        vm.prank(deliverer);
        usdc.approve(address(market), type(uint256).max);
    }
    
    function testCreateMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket(
            "Deliver a coffee to 123 Main St",
            STAKE,
            block.timestamp + 1 hours
        );
        
        TaskMarket.Market memory m = market.getMarket(marketId);
        
        assertEq(m.requester, requester);
        assertEq(m.stake, STAKE);
        assertEq(uint(m.state), uint(TaskMarket.MarketState.Open));
    }
    
    function testTakeMarket() public {
        // Create market
        vm.prank(requester);
        uint256 marketId = market.createMarket(
            "Deliver a coffee",
            STAKE,
            block.timestamp + 1 hours
        );
        
        // Take market
        bytes32 commitment = keccak256(abi.encodePacked(bytes32("proof"), bytes32("salt")));
        
        vm.prank(deliverer);
        market.takeMarket(marketId, commitment);
        
        TaskMarket.Market memory m = market.getMarket(marketId);
        
        assertEq(m.deliverer, deliverer);
        assertEq(m.commitmentHash, commitment);
        assertEq(uint(m.state), uint(TaskMarket.MarketState.Locked));
    }
    
    function testFullFlow() public {
        // 1. Create market
        vm.prank(requester);
        uint256 marketId = market.createMarket(
            "Deliver a coffee",
            STAKE,
            block.timestamp + 1 hours
        );
        
        // 2. Take market with commitment
        bytes32 proof = bytes32("delivery_photo_hash_12345");
        bytes32 salt = bytes32("random_salt_67890");
        bytes32 commitment = keccak256(abi.encodePacked(proof, salt));
        
        vm.prank(deliverer);
        market.takeMarket(marketId, commitment);
        
        // 3. Reveal proof
        vm.prank(deliverer);
        market.revealDelivery(marketId, proof, salt);
        
        TaskMarket.Market memory m = market.getMarket(marketId);
        assertEq(uint(m.state), uint(TaskMarket.MarketState.Revealed));
        
        // 4. Wait for slashing period
        vm.warp(block.timestamp + 2 hours);
        
        // 5. Claim funds
        uint256 balanceBefore = usdc.balanceOf(deliverer);
        
        vm.prank(deliverer);
        market.claimFunds(marketId);
        
        uint256 balanceAfter = usdc.balanceOf(deliverer);
        
        // Deliverer should receive both stakes (200 USDC)
        assertEq(balanceAfter - balanceBefore, STAKE * 2);
        
        m = market.getMarket(marketId);
        assertEq(uint(m.state), uint(TaskMarket.MarketState.Completed));
    }
    
    function testCancelMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket(
            "Deliver a coffee",
            STAKE,
            block.timestamp + 1 hours
        );
        
        uint256 balanceBefore = usdc.balanceOf(requester);
        
        vm.prank(requester);
        market.cancelMarket(marketId);
        
        uint256 balanceAfter = usdc.balanceOf(requester);
        assertEq(balanceAfter - balanceBefore, STAKE);
    }
    
    function testExpiredMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket(
            "Deliver a coffee",
            STAKE,
            block.timestamp + 1 hours
        );
        
        // Take market
        vm.prank(deliverer);
        market.takeMarket(marketId, bytes32("commitment"));
        
        // Time passes, deliverer fails to deliver
        vm.warp(block.timestamp + 2 hours);
        
        uint256 balanceBefore = usdc.balanceOf(requester);
        
        // Requester claims (deliverer failed)
        market.claimExpired(marketId);
        
        uint256 balanceAfter = usdc.balanceOf(requester);
        
        // Requester gets both stakes
        assertEq(balanceAfter - balanceBefore, STAKE * 2);
    }
}
