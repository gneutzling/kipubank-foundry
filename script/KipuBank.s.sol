// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {KipuBank} from "../src/KipuBank.sol";

contract DeployKipuBank is Script {
    function run() external {
        // load deployer private key from env
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");

        // config (you ajusta esses valores pra rede alvo)
        address usdc = vm.envAddress("USDC_ADDRESS");
        uint256 bankCapUsdc = vm.envUint("BANK_CAP_USDC");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address chainlinkFeed = vm.envAddress("CHAINLINK_ETH_USD_FEED");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast(pk);

        KipuBank bank = new KipuBank(
            usdc,
            bankCapUsdc,
            universalRouter,
            permit2,
            chainlinkFeed,
            admin
        );

        vm.stopBroadcast();

        console2.log("KipuBank deployed at:", address(bank));
    }
}
