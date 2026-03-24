// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/LoopVault.sol";
import "../src/LoopStrategy.sol";
import "../src/KeeperModule.sol";
import "../src/interfaces/IMorpho.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Deploy — Full deployment script for weETH Looping Vault
/// @dev NEW-6: Includes KeeperModule registration on vault and strategy
contract Deploy is Script {
    // ── Ethereum Mainnet addresses ──
    address constant MORPHO          = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WETH            = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LIQUIDITY_POOL  = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant EETH            = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant WEETH           = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant PRICE_FEED      = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22; // Chainlink weETH/ETH
    address constant SWAP_ROUTER     = address(0); // TODO: Set to deployed UniV3Adapter address

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy Strategy
        MarketParams memory mp = MarketParams({
            loanToken: WETH,
            collateralToken: WEETH,
            oracle: 0xbDd2F2D473E8D63d1BFb0185B5bDB8046ca48a72,
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC,
            lltv: 0.945e18
        });

        LoopStrategy strategy = new LoopStrategy(
            MORPHO, LIQUIDITY_POOL, EETH, WEETH, WETH, PRICE_FEED, SWAP_ROUTER, mp
        );

        // 2. Deploy Vault (UUPS proxy)
        LoopVault vaultImpl = new LoopVault();
        bytes memory initData = abi.encodeCall(
            LoopVault.initialize,
            (WETH, address(strategy), deployer)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        LoopVault vault = LoopVault(payable(address(proxy)));

        // 3. Deploy KeeperModule
        KeeperModule keeperModule = new KeeperModule(
            address(vault), address(strategy), deployer
        );

        // ── NEW-6: Register KeeperModule on vault and strategy ──

        // 4. Set KeeperModule as keeper on Vault
        vault.setKeeper(address(keeperModule));

        // 5. Set Vault and KeeperModule on Strategy
        strategy.setVault(address(vault));
        strategy.setKeeper(address(keeperModule));

        // 6. Whitelist deployer as initial keeper on KeeperModule
        // (already done in KeeperModule constructor for _owner)

        vm.stopBroadcast();

        // ── Verification ──
        console.log("=== Deployment Complete ===");
        console.log("Strategy:     ", address(strategy));
        console.log("Vault Impl:   ", address(vaultImpl));
        console.log("Vault Proxy:  ", address(vault));
        console.log("KeeperModule: ", address(keeperModule));
        console.log("");
        console.log("=== Registration Verified ===");
        console.log("vault.keeper() =", vault.keeper());
        console.log("strategy.vault() =", strategy.vault());
        console.log("strategy.keeper() =", strategy.keeper());
        console.log("keeperModule.whitelisted(deployer) =", keeperModule.whitelisted(deployer));
    }
}
