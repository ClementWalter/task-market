// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ErdosBounty.sol";

contract DeployErdosScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        ErdosBounty erdos = new ErdosBounty(usdc);

        console.log("ErdosBounty deployed at:", address(erdos));
        console.log("Using USDC:", usdc);

        vm.stopBroadcast();
    }
}
