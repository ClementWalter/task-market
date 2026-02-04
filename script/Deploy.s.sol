// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TaskMarket.sol";

contract DeployScript is Script {
    function run() external {
        // Get private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // USDC addresses (testnet)
        // Sepolia USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
        // Base Sepolia USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
        address usdc = vm.envAddress("USDC_ADDRESS");
        
        vm.startBroadcast(deployerPrivateKey);
        
        TaskMarket market = new TaskMarket(usdc);
        
        console.log("TaskMarket deployed at:", address(market));
        
        vm.stopBroadcast();
    }
}
