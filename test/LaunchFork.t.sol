// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LpLocker} from "../src/LpLocker.sol";
import {FairLaunchToken} from "../src/FairLaunchToken.sol";
import {RHAddresses} from "../src/RHAddresses.sol";
import {INonfungiblePositionManager, ISwapRouter02, IWETH} from "../src/interfaces/UniV3.sol";

/// Fork tests against a local anvil fork of Robinhood Chain (rpc alias `rh_fork`,
/// the anvil on :8546). Proves the single-sided launch + locked-LP + fee-collect
/// closed loop on real Uniswap v3.
contract LaunchForkTest is Test {
    LaunchFactory internal factory;
    LpLocker internal locker;

    address internal feeCollector = address(0xFEE);
    address internal feeSink = address(0x51E1); // where the locker forwards fees
    address internal creator = address(0xC0DE);
    address internal buyer = address(0xB4E4);

    uint256 internal constant LAUNCH_FEE = 0.0003 ether; // ~$1
    int24 internal constant OPEN_TICK = 204200; // opening price ≈ $4.8k FDV

    address internal platform; // the platform token ($ZORCH) = the first launch

    function setUp() public {
        vm.createSelectFork("rh_fork");
        locker = new LpLocker(RHAddresses.POSITION_MANAGER, feeSink);
        factory = _newFactory();
        // This test contract is the deployer, so it performs the first launch,
        // which the contract locks in as the platform token ($ZORCH).
        vm.deal(address(this), 1 ether);
        (platform,,) = factory.launch{value: LAUNCH_FEE}("Zorch", "ZORCH", "", "", "");
    }

    function _newFactory() internal returns (LaunchFactory) {
        return new LaunchFactory(
            RHAddresses.POSITION_MANAGER,
            RHAddresses.SWAP_ROUTER_02,
            RHAddresses.WETH,
            address(locker),
            feeCollector,
            LAUNCH_FEE,
            OPEN_TICK,
            address(this) // deployer = this test contract
        );
    }

    receive() external payable {}

    function _launch() internal returns (address token, address pool, uint256 tokenId) {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (token, pool, tokenId) = factory.launch{value: LAUNCH_FEE}(
            "Test Coin", "TEST", "ipfs://bafyLOGO", "a test coin", "https://x.com/test"
        );
    }

    function test_Launch_SingleSided_ZeroEth() public {
        uint256 feeBefore = feeCollector.balance;
        (address token, address pool, uint256 tokenId) = _launch();

        // Position NFT is locked in the locker forever.
        assertEq(
            INonfungiblePositionManager(RHAddresses.POSITION_MANAGER).ownerOf(tokenId),
            address(locker),
            "NFT not in locker"
        );

        // The pool holds ~100% of supply and ZERO WETH (true single-sided launch).
        uint256 poolToken = FairLaunchToken(token).balanceOf(pool);
        uint256 poolWeth = IWETH(RHAddresses.WETH).balanceOf(pool);
        assertGt(poolToken, factory.SUPPLY() * 999 / 1000, "pool should hold ~all supply");
        assertEq(poolWeth, 0, "single-sided: pool must start with 0 WETH");

        // Nobody was pre-allocated: creator got nothing, factory keeps only the
        // tick-rounding dust (a few thousand wei left over when the full supply is
        // minted into a tick-aligned single-sided range).
        assertEq(FairLaunchToken(token).balanceOf(creator), 0, "creator has no premine");
        assertLt(FairLaunchToken(token).balanceOf(address(factory)), 1e12, "factory holds only dust");

        // Launch fee reached the collector; none of it seeded the LP.
        assertEq(feeCollector.balance - feeBefore, LAUNCH_FEE, "launch fee not collected");

        // Metadata (Robinhood Chain convention) is set on the token for GMGN.
        assertEq(FairLaunchToken(token).logo(), "ipfs://bafyLOGO", "logo not set");
        assertEq(FairLaunchToken(token).description(), "a test coin", "description not set");
    }

    function test_Launch_InsufficientValueReverts() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(bytes("insufficient value"));
        factory.launch{value: LAUNCH_FEE - 1}("X", "X", "", "", "");
    }

    // --- platform token ($ZORCH) = the first launch, front-run-proof ---

    function test_PlatformToken_IsFirstLaunch() public view {
        assertEq(factory.platformToken(), platform, "platform token != first launch");
        assertEq(FairLaunchToken(platform).symbol(), "ZORCH", "platform symbol");
    }

    function test_FirstLaunch_DeployerOnly() public {
        // A fresh factory: platformToken is unset, so only the deployer (this
        // test contract) may do the first launch. A stranger is rejected.
        LaunchFactory fresh = _newFactory();
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(bytes("first launch: deployer only"));
        fresh.launch{value: LAUNCH_FEE}("Evil", "EVIL", "", "", "");
    }

    function test_PlatformLaunch_RejectsFirstBuy() public {
        // The platform token must launch clean (no dev snipe): a first-buy on the
        // first launch reverts. (deployer = this test contract.)
        LpLocker l2 = new LpLocker(RHAddresses.POSITION_MANAGER, feeSink);
        LaunchFactory fresh = new LaunchFactory(
            RHAddresses.POSITION_MANAGER, RHAddresses.SWAP_ROUTER_02, RHAddresses.WETH,
            address(l2), feeCollector, LAUNCH_FEE, OPEN_TICK, address(this)
        );
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("no first-buy on platform launch"));
        fresh.launch{value: LAUNCH_FEE + 0.1 ether}("Zorch", "ZORCH", "", "", "");
    }

    // --- creator first-buy (pump.fun style) ---

    // The `token < weth` (token0) single-sided branch is rare (~4.6%/launch). Find
    // a name whose CREATE2 address lands below WETH OFF-CHAIN, then do ONE real
    // launch with it — deterministic + fast, and exercises the token0 invariants.
    function test_Launch_Token0Branch_SingleSided() public {
        address weth = RHAddresses.WETH;
        bytes32 salt = keccak256(abi.encodePacked(creator, block.number, block.prevrandao, factory.saltNonce()));
        string memory name;
        for (uint256 i = 0; i < 5000; i++) {
            name = string(abi.encodePacked("T0-", vm.toString(i)));
            bytes32 initHash = keccak256(
                abi.encodePacked(
                    type(FairLaunchToken).creationCode,
                    abi.encode(name, "T0", factory.SUPPLY(), address(factory), "", "", "")
                )
            );
            if (vm.computeCreate2Address(salt, initHash, address(factory)) < weth) break;
        }
        // Also exercise a first-buy on the token0 branch (swap direction weth->token0).
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token, address pool,) = factory.launch{value: LAUNCH_FEE + 0.2 ether}(name, "T0", "", "", "");
        require(token < weth, "token0 branch not reached");
        assertGt(FairLaunchToken(token).balanceOf(creator), 0, "token0 first-buy gave no tokens");
        // Pool holds ~all supply minus what the first-buy took, and now holds WETH.
        assertGt(IWETH(weth).balanceOf(pool), 0, "token0: pool should hold WETH after first-buy");
    }

    function test_DonatedWeth_GoesToFeeCollector_NotFirstBuyer() public {
        // Someone donates / mis-sends WETH to the factory.
        uint256 donation = 1 ether;
        vm.deal(address(this), 2 ether);
        IWETH(RHAddresses.WETH).deposit{value: donation}();
        IWETH(RHAddresses.WETH).transfer(address(factory), donation);

        // A first-buy launch must NOT sweep the donation to the creator.
        vm.deal(creator, 2 ether);
        vm.prank(creator);
        factory.launch{value: LAUNCH_FEE + 0.1 ether}("D", "D", "", "", "");
        assertEq(IWETH(RHAddresses.WETH).balanceOf(creator), 0, "creator swept the donation");
        assertEq(IWETH(RHAddresses.WETH).balanceOf(address(factory)), donation, "donation not retained");

        // sweepWeth() sends stray WETH to the fee collector.
        uint256 fcBefore = IWETH(RHAddresses.WETH).balanceOf(feeCollector);
        factory.sweepWeth();
        assertEq(IWETH(RHAddresses.WETH).balanceOf(feeCollector) - fcBefore, donation, "not swept to feeCollector");
        assertEq(IWETH(RHAddresses.WETH).balanceOf(address(factory)), 0, "factory not emptied");
    }

    function test_CreatorFirstBuy_GetsTokens() public {
        uint256 buyEth = 0.5 ether;
        vm.deal(creator, 2 ether);
        vm.prank(creator);
        (address token,,) = factory.launch{value: LAUNCH_FEE + buyEth}(
            "Buy Coin", "BUY", "", "", ""
        );
        // The extra ETH beyond the launch fee bought the token for the creator.
        assertGt(FairLaunchToken(token).balanceOf(creator), 0, "creator got no first-buy tokens");
    }

    function test_FirstBuy_ThenCollectFees() public {
        (address token, address pool, uint256 tokenId) = _launch();

        // Buyer wraps 1 ETH and swaps WETH -> token (the first buy).
        uint256 buyAmount = 1 ether;
        vm.deal(buyer, 2 ether);
        vm.startPrank(buyer);
        IWETH(RHAddresses.WETH).deposit{value: buyAmount}();
        IWETH(RHAddresses.WETH).approve(RHAddresses.SWAP_ROUTER_02, buyAmount);
        uint256 out = ISwapRouter02(RHAddresses.SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: RHAddresses.WETH,
                tokenOut: token,
                fee: 10000,
                recipient: buyer,
                amountIn: buyAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        // First buy is immediately tradeable — buyer received tokens.
        assertGt(out, 0, "first buy returned no tokens");
        assertEq(FairLaunchToken(token).balanceOf(buyer), out, "buyer balance mismatch");
        // Pool now holds real WETH (accumulated from the buy).
        assertGt(IWETH(RHAddresses.WETH).balanceOf(pool), 0, "pool should hold WETH after buy");

        // Anyone can collect the accrued 1% fee -> forwarded to the fee sink.
        uint256 sinkWethBefore = IWETH(RHAddresses.WETH).balanceOf(feeSink);
        locker.collect(tokenId);
        uint256 fee = IWETH(RHAddresses.WETH).balanceOf(feeSink) - sinkWethBefore;
        // 1% fee on a 1 ETH buy ≈ 0.01 WETH.
        assertGt(fee, 0, "no fee collected");
        assertApproxEqRel(fee, buyAmount / 100, 0.05e18, "fee not ~1% of buy");
    }
}
