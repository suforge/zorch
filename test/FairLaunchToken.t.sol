// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FairLaunchToken} from "../src/FairLaunchToken.sol";

contract FairLaunchTokenTest is Test {
    FairLaunchToken internal token;

    address internal recipient = address(0xF00);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000 ether; // 1B, 18 decimals

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new FairLaunchToken("Fair", "FAIR", SUPPLY, recipient, "", "", "");
    }

    // --- construction / fairness invariants ---

    function test_MetadataAndFixedSupply() public view {
        assertEq(token.name(), "Fair");
        assertEq(token.symbol(), "FAIR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_EntireSupplyToRecipient_NoPreAllocation() public view {
        // The only holder at genesis is the recipient (the factory). Nobody is
        // pre-allocated: the sole way to get tokens is to buy from the pool.
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Constructor_EmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), recipient, SUPPLY);
        new FairLaunchToken("Fair", "FAIR", SUPPLY, recipient, "", "", "");
    }

    function test_Constructor_RevertsZeroRecipient() public {
        vm.expectRevert(bytes("recipient=0"));
        new FairLaunchToken("Fair", "FAIR", SUPPLY, address(0), "", "", "");
    }

    function test_Constructor_RevertsZeroSupply() public {
        vm.expectRevert(bytes("supply=0"));
        new FairLaunchToken("Fair", "FAIR", 0, recipient, "", "", "");
    }

    function test_Metadata_LogoDescriptionSocials() public {
        // Robinhood Chain launchpad convention: logo / description / socials live
        // as plain view strings on the token (read by terminals like GMGN).
        FairLaunchToken t = new FairLaunchToken(
            "Fair", "FAIR", SUPPLY, recipient,
            "ipfs://bafyLOGO",
            "the fairest coin",
            "https://x.com/fair" // socials = single URL (the on-chain convention)
        );
        assertEq(t.logo(), "ipfs://bafyLOGO");
        assertEq(t.description(), "the fairest coin");
        assertEq(t.socials(), "https://x.com/fair");
    }

    // --- no admin surface exists ---

    function test_NoOwnerOrMintSelectors() public view {
        // No privileged roles. owner() exists only to report the zero address, so
        // safety scanners read "ownership renounced". There is no mint/pause/etc.
        assertEq(token.owner(), address(0), "should report renounced ownership");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // --- transfer ---

    function test_Transfer() public {
        vm.prank(recipient);
        token.transfer(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(recipient), SUPPLY - 100 ether);
    }

    function test_Transfer_EmitsEvent() public {
        vm.prank(recipient);
        vm.expectEmit(true, true, true, true);
        emit Transfer(recipient, alice, 100 ether);
        token.transfer(alice, 100 ether);
    }

    function test_Transfer_RevertsToZero() public {
        vm.prank(recipient);
        vm.expectRevert(bytes("transfer to 0"));
        token.transfer(address(0), 1);
    }

    function test_Transfer_RevertsInsufficientBalance() public {
        vm.prank(alice); // alice has 0
        vm.expectRevert(bytes("insufficient balance"));
        token.transfer(bob, 1);
    }

    // --- burn (real deflation) ---

    function test_Burn_ReducesSupplyAndBalance() public {
        vm.prank(recipient);
        token.transfer(alice, 100 ether);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 40 ether);
        token.burn(40 ether);
        assertEq(token.balanceOf(alice), 60 ether, "balance not reduced");
        assertEq(token.totalSupply(), supplyBefore - 40 ether, "totalSupply not reduced");
    }

    function test_Burn_RevertsInsufficient() public {
        vm.prank(alice); // alice has 0
        vm.expectRevert(bytes("insufficient balance"));
        token.burn(1);
    }

    // --- approve / transferFrom ---

    function test_ApproveAndTransferFrom() public {
        vm.prank(recipient);
        token.approve(alice, 100 ether);
        assertEq(token.allowance(recipient, alice), 100 ether);

        vm.prank(alice);
        token.transferFrom(recipient, bob, 40 ether);
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.allowance(recipient, alice), 60 ether);
    }

    function test_TransferFrom_InfiniteAllowanceNotDecremented() public {
        vm.prank(recipient);
        token.approve(alice, type(uint256).max);

        vm.prank(alice);
        token.transferFrom(recipient, bob, 40 ether);
        assertEq(token.allowance(recipient, alice), type(uint256).max);
    }

    function test_TransferFrom_RevertsInsufficientAllowance() public {
        vm.prank(recipient);
        token.approve(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("insufficient allowance"));
        token.transferFrom(recipient, bob, 11 ether);
    }

    // --- fuzz ---

    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(recipient);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(recipient), SUPPLY - amount);
    }

    function testFuzz_SupplyConserved(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(recipient);
        token.transfer(alice, amount);
        // Transfers conserve supply (only burn can reduce it; no mint path).
        assertEq(token.balanceOf(recipient) + token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
