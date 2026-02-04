// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TaskMarket.sol";
import "../src/MockCTF.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
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
    MockConditionalTokens public ctf;
    MockUSDC public usdc;

    address public requester = address(0x1);
    address public deliverer = address(0x2);
    address public trader = address(0x3);

    uint256 public constant LIQUIDITY = 100 * 10 ** 6; // 100 USDC

    function setUp() public {
        usdc = new MockUSDC();
        ctf = new MockConditionalTokens();
        market = new TaskMarket(address(usdc), address(ctf));

        // Fund test accounts
        usdc.mint(requester, 1000 * 10 ** 6);
        usdc.mint(deliverer, 1000 * 10 ** 6);
        usdc.mint(trader, 1000 * 10 ** 6);

        // Approve market to spend
        vm.prank(requester);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(deliverer);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(trader);
        usdc.approve(address(market), type(uint256).max);

        // Approve CTF for market
        vm.prank(requester);
        ctf.setApprovalForAll(address(market), true);

        vm.prank(trader);
        ctf.setApprovalForAll(address(market), true);
    }

    function testCreateMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee to 123 Main St", LIQUIDITY, block.timestamp + 1 hours);

        TaskMarket.Market memory m = market.getMarket(marketId);

        assertEq(m.requester, requester);
        assertEq(m.totalCollateral, LIQUIDITY);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Open));

        // Requester should have NO tokens
        assertEq(ctf.balanceOf(requester, m.noTokenId), LIQUIDITY);

        // Contract should have YES tokens (for sale)
        assertEq(ctf.balanceOf(address(market), m.yesTokenId), LIQUIDITY);
    }

    function testBuyYesTokens() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", LIQUIDITY, block.timestamp + 1 hours);

        TaskMarket.Market memory m = market.getMarket(marketId);

        // Trader buys YES tokens
        uint256 buyAmount = 50 * 10 ** 6;
        vm.prank(trader);
        market.buyYes(marketId, buyAmount);

        // Trader should have YES tokens
        assertEq(ctf.balanceOf(trader, m.yesTokenId), buyAmount);

        // Contract should have less YES tokens
        assertEq(ctf.balanceOf(address(market), m.yesTokenId), LIQUIDITY - buyAmount);
    }

    function testFullFlowWithTrading() public {
        // 1. Create market
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", LIQUIDITY, block.timestamp + 1 hours);

        TaskMarket.Market memory m = market.getMarket(marketId);

        // 2. Trader buys YES tokens (betting task will be done)
        uint256 buyAmount = 50 * 10 ** 6;
        vm.prank(trader);
        market.buyYes(marketId, buyAmount);

        // 3. Deliverer takes the market
        vm.prank(deliverer);
        market.takeMarket(marketId);

        // 4. Deliverer completes task and claims
        vm.prank(deliverer);
        market.claimDelivery(marketId, keccak256("proof_hash"));

        // 5. Wait slashing period
        vm.warp(block.timestamp + 2 hours);

        // 6. Resolve as YES
        market.resolveYes(marketId);

        m = market.getMarket(marketId);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.ResolvedYes));

        // 7. Trader redeems YES tokens directly through CTF
        uint256 traderBalanceBefore = usdc.balanceOf(trader);

        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1; // YES
        indexSets[1] = 2; // NO

        vm.prank(trader);
        ctf.redeemPositions(usdc, bytes32(0), m.conditionId, indexSets);

        uint256 traderBalanceAfter = usdc.balanceOf(trader);

        // Trader should get their YES token value back (50 USDC)
        assertEq(traderBalanceAfter - traderBalanceBefore, buyAmount);
    }

    function testResolveNo() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", LIQUIDITY, block.timestamp + 1 hours);

        // Deliverer takes but doesn't complete
        vm.prank(deliverer);
        market.takeMarket(marketId);

        // Deadline passes
        vm.warp(block.timestamp + 2 hours);

        // Resolve as NO
        market.resolveNo(marketId);

        TaskMarket.Market memory m = market.getMarket(marketId);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.ResolvedNo));
    }

    function testTakeMarket() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", LIQUIDITY, block.timestamp + 1 hours);

        vm.prank(deliverer);
        market.takeMarket(marketId);

        TaskMarket.Market memory m = market.getMarket(marketId);
        assertEq(m.deliverer, deliverer);
        assertEq(uint256(m.state), uint256(TaskMarket.MarketState.Taken));
    }

    function testCannotResolveYesBeforeSlashingPeriod() public {
        vm.prank(requester);
        uint256 marketId = market.createMarket("Deliver a coffee", LIQUIDITY, block.timestamp + 1 hours);

        vm.prank(deliverer);
        market.takeMarket(marketId);

        vm.prank(deliverer);
        market.claimDelivery(marketId, keccak256("proof"));

        // Try to resolve immediately
        vm.expectRevert(TaskMarket.SlashingPeriodNotOver.selector);
        market.resolveYes(marketId);
    }
}
