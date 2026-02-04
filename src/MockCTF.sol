// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @title MockConditionalTokens
 * @notice Simplified CTF for testing TaskMarket
 * @dev In production, use Gnosis CTF at 0x...
 */
contract MockConditionalTokens is ERC1155 {
    using SafeERC20 for IERC20;

    bytes32 public constant PARENT_COLLECTION_ID = bytes32(0);

    // conditionId => outcome slot count
    mapping(bytes32 => uint256) public outcomeSlotCounts;

    // conditionId => payouts (set after resolution)
    mapping(bytes32 => uint256[]) public payouts;
    mapping(bytes32 => bool) public isResolved;

    constructor() ERC1155("") {}

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external {
        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);
        require(outcomeSlotCounts[conditionId] == 0, "Condition already prepared");
        outcomeSlotCounts[conditionId] = outcomeSlotCount;
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata _payouts) external {
        bytes32 conditionId = getConditionId(msg.sender, questionId, _payouts.length);
        require(outcomeSlotCounts[conditionId] > 0, "Condition not prepared");
        require(!isResolved[conditionId], "Already resolved");

        payouts[conditionId] = _payouts;
        isResolved[conditionId] = true;
    }

    function splitPosition(
        IERC20 collateralToken,
        bytes32, /* parentCollectionId */
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(outcomeSlotCounts[conditionId] > 0, "Condition not prepared");

        // Transfer collateral from sender
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // Mint outcome tokens
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 tokenId =
                getPositionId(collateralToken, getCollectionId(PARENT_COLLECTION_ID, conditionId, partition[i]));
            _mint(msg.sender, tokenId, amount, "");
        }
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32, /* parentCollectionId */
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(outcomeSlotCounts[conditionId] > 0, "Condition not prepared");
        require(!isResolved[conditionId], "Already resolved");

        // Burn outcome tokens
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 tokenId =
                getPositionId(collateralToken, getCollectionId(PARENT_COLLECTION_ID, conditionId, partition[i]));
            _burn(msg.sender, tokenId, amount);
        }

        // Return collateral
        collateralToken.safeTransfer(msg.sender, amount);
    }

    function redeemPositions(
        IERC20 collateralToken,
        bytes32, /* parentCollectionId */
        bytes32 conditionId,
        uint256[] calldata indexSets
    )
        external
    {
        require(isResolved[conditionId], "Not resolved");

        uint256 totalPayout = 0;
        uint256[] memory _payouts = payouts[conditionId];

        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 tokenId =
                getPositionId(collateralToken, getCollectionId(PARENT_COLLECTION_ID, conditionId, indexSets[i]));
            uint256 balance = balanceOf(msg.sender, tokenId);

            if (balance > 0) {
                // Find matching payout
                for (uint256 j = 0; j < _payouts.length; j++) {
                    if (indexSets[i] == (1 << j)) {
                        totalPayout += balance * _payouts[j];
                        break;
                    }
                }
                _burn(msg.sender, tokenId, balance);
            }
        }

        if (totalPayout > 0) {
            collateralToken.safeTransfer(msg.sender, totalPayout);
        }
    }

    // ============ View Functions ============

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(
        bytes32,
        /* parentCollectionId */
        bytes32 conditionId,
        uint256 indexSet
    )
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(conditionId, indexSet));
    }

    function getPositionId(IERC20 collateralToken, bytes32 collectionId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(address(collateralToken), collectionId)));
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCounts[conditionId];
    }
}
