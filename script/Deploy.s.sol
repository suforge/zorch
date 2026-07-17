// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {LpLocker} from "../src/LpLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {RHAddresses} from "../src/RHAddresses.sol";

/// @title Deploy
/// @notice Deploys the Zorch launchpad in the ONE order that resolves the
///         circular dependency between the burner, the locker, and the factory.
///
///         The cycle is: the burner is the locker's immutable `feeSink`; the
///         factory needs the locker (immutable); and the burner needs the factory
///         (to read $ZORCH). It only unwinds because the burner takes the factory
///         via a one-time `init` instead of a constructor immutable — so the
///         burner can be deployed first, before either the locker or the factory.
///
///         Steps 1-4 (deploy + wire) run here. Step 5 — launching $ZORCH — is a
///         deliberate, irreversible one-shot done separately with real metadata,
///         by the same `deployer`, and is only allowed once (see LaunchFactory).
///
/// Env (all addresses/values for MAINNET; the deployer is the tx sender):
///   FEE_COLLECTOR  dev-income address (flat launch fees + swept stray WETH)
///   LAUNCH_FEE_WEI flat launch fee in wei (≈ $1)
///   OPEN_TICK      opening tick magnitude (multiple of 200; ≈ 204200 → ~$4.8k FDV)
///   REWARD_BPS     crank tip in bps of WETH deployed (<= 500)
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url rh --broadcast --private-key $PK
contract Deploy is Script {
    function run() external {
        address feeCollector = vm.envAddress("FEE_COLLECTOR");
        uint256 launchFee = vm.envUint("LAUNCH_FEE_WEI");
        int24 openTick = int24(vm.envInt("OPEN_TICK"));
        uint256 rewardBps = vm.envUint("REWARD_BPS");

        // The deployer is the broadcasting account. It is the ONLY account that can
        // (a) call burner.init and (b) perform the first launch ($ZORCH).
        address deployer = msg.sender;

        vm.startBroadcast();

        // 1. Burner — no factory/$ZORCH dependency, so it can exist first.
        BuybackBurner burner = new BuybackBurner(
            RHAddresses.WETH, RHAddresses.SWAP_ROUTER_02, RHAddresses.V3_FACTORY, rewardBps, deployer
        );

        // 2. Locker — its immutable feeSink is the final burner.
        LpLocker locker = new LpLocker(RHAddresses.POSITION_MANAGER, address(burner));

        // 3. Factory — needs the (now-known) locker.
        LaunchFactory factory = new LaunchFactory(
            RHAddresses.POSITION_MANAGER,
            RHAddresses.SWAP_ROUTER_02,
            RHAddresses.WETH,
            address(locker),
            feeCollector,
            launchFee,
            openTick,
            deployer
        );

        // 4. Wire the factory into the burner (once, deployer only).
        burner.init(address(factory));

        vm.stopBroadcast();

        console2.log("BuybackBurner:", address(burner));
        console2.log("LpLocker:     ", address(locker));
        console2.log("LaunchFactory:", address(factory));
        console2.log("deployer:     ", deployer);
        console2.log("");
        console2.log("Step 5 (separate, one-shot): deployer calls");
        console2.log("  factory.launch{value: launchFee}(\"Zorch\",\"ZORCH\",logo,desc,x)");
        console2.log("to mint $ZORCH as the immutable platform token.");
    }
}
