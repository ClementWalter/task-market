// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TaskMarket.sol";
import "../src/MockCTF.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");

        // Check if CTF address provided, otherwise deploy mock
        address ctf;
        try vm.envAddress("CTF_ADDRESS") returns (address _ctf) {
            ctf = _ctf;
            console.log("Using existing CTF at:", ctf);
        } catch {
            vm.startBroadcast(deployerPrivateKey);
            MockConditionalTokens mockCtf = new MockConditionalTokens();
            ctf = address(mockCtf);
            console.log("Deployed MockCTF at:", ctf);
            vm.stopBroadcast();
        }

        vm.startBroadcast(deployerPrivateKey);

        TaskMarket market = new TaskMarket(usdc, ctf);

        console.log("TaskMarket deployed at:", address(market));
        console.log("Using USDC:", usdc);
        console.log("Using CTF:", ctf);

        vm.stopBroadcast();
    }
}
