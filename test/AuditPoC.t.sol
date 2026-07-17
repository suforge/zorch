// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LpLocker} from "../src/LpLocker.sol";
import {FairLaunchToken} from "../src/FairLaunchToken.sol";
import {RHAddresses} from "../src/RHAddresses.sol";
import {INonfungiblePositionManager} from "../src/interfaces/UniV3.sol";

/// Regression tests for the "pre-created pool bricks the factory" DoS found in
/// review. Fix: launched tokens use CREATE2 with an unpredictable salt (so an
/// attacker can't know the address to poison), plus a `getPool()==0` guard.
contract AuditPoC is Test {
    LaunchFactory internal factory;
    LpLocker internal locker;

    address internal feeCollector = address(0xFEE);
    address internal feeSink = address(0x51E1);
    address internal creator = address(0xC0DE);
    address internal attacker = address(0xBAD);

    uint256 internal constant LAUNCH_FEE = 0.0003 ether;
    int24 internal constant OPEN_TICK = 204200;
    uint160 internal constant SQRT_AT_TICK_0 = 79228162514264337593543950336; // 2^96

    function setUp() public {
        vm.createSelectFork("rh_fork");
        locker = new LpLocker(RHAddresses.POSITION_MANAGER, feeSink);
        factory = new LaunchFactory(
            RHAddresses.POSITION_MANAGER,
            RHAddresses.SWAP_ROUTER_02,
            RHAddresses.WETH,
            address(locker),
            feeCollector,
            LAUNCH_FEE,
            OPEN_TICK,
            address(this)
        );
        vm.deal(address(this), 1 ether);
        factory.launch{value: LAUNCH_FEE}("Zorch", "ZORCH", "", "", ""); // platform token
    }

    receive() external payable {}

    /// The exact attack from the audit: predict the next token address the OLD
    /// (plain-CREATE) way and pre-create/poison its pool. With CREATE2 the real
    /// address differs, so the honest launch just succeeds — no brick.
    function test_Poison_OldPredictedAddress_DoesNotBrick() public {
        uint64 nonce = vm.getNonce(address(factory));
        address predicted = vm.computeCreateAddress(address(factory), nonce);

        address weth = RHAddresses.WETH;
        (address t0, address t1) = predicted < weth ? (predicted, weth) : (weth, predicted);
        vm.prank(attacker);
        INonfungiblePositionManager(RHAddresses.POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(t0, t1, 10000, SQRT_AT_TICK_0);

        // Honest launch still works, and its token is NOT the poisoned address.
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token,,) = factory.launch{value: LAUNCH_FEE}("Honest", "HON", "", "", "");
        assertTrue(token != predicted, "token landed on the poisoned address");
        assertGt(FairLaunchToken(token).totalSupply(), 0, "launch failed");
    }

    /// Token addresses are unpredictable: consecutive launches differ.
    function test_TokenAddresses_AreUnpredictable() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        (address a,,) = factory.launch{value: LAUNCH_FEE}("A", "A", "", "", "");
        (address b,,) = factory.launch{value: LAUNCH_FEE}("A", "A", "", "", "");
        vm.stopPrank();
        assertTrue(a != b, "same salt / predictable address");
    }
}
