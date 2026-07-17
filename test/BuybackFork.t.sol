// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LpLocker} from "../src/LpLocker.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {FairLaunchToken} from "../src/FairLaunchToken.sol";
import {RHAddresses} from "../src/RHAddresses.sol";
import {ISwapRouter02, IWETH} from "../src/interfaces/UniV3.sol";

/// Fork tests for the whole flywheel: fees → collect → crank → buy $ZORCH → burn.
/// Wires the contracts in the real deploy order that breaks the circular
/// dependency (burner → locker → factory → burner.init → launch $ZORCH).
///
/// The buyback has a TWAP anti-sandwich guard, so a crank only swaps when the
/// pool's spot is in-band vs its short TWAP. Tests `_settle()` (advance past the
/// window with no trades) so spot ≈ TWAP before cranking; the manipulation test
/// pushes spot far from the TWAP and asserts the buyback is skipped.
contract BuybackForkTest is Test {
    LaunchFactory internal factory;
    LpLocker internal locker;
    BuybackBurner internal burner;

    address internal feeCollector = address(0xFEE);
    address internal creator = address(0xC0DE);
    address internal buyer = address(0xB4E4);
    address internal cranker = address(0xCA47);

    uint256 internal constant LAUNCH_FEE = 0.0003 ether;
    int24 internal constant OPEN_TICK = 204200;
    uint256 internal constant REWARD_BPS = 100; // 1% crank tip

    address internal zorch;
    uint256 internal zorchTokenId;

    address internal constant WETH = RHAddresses.WETH;
    address internal constant ROUTER = RHAddresses.SWAP_ROUTER_02;
    address internal constant V3_FACTORY = RHAddresses.V3_FACTORY;
    uint24 internal constant FEE = 10000;

    function setUp() public {
        vm.createSelectFork("rh_fork");

        // Deploy order (see BuybackBurner deploy-order note):
        // 1. burner, with NO factory/zorch dependency
        burner = new BuybackBurner(WETH, ROUTER, V3_FACTORY, REWARD_BPS, address(this));
        // 2. locker whose immutable feeSink is the final burner
        locker = new LpLocker(RHAddresses.POSITION_MANAGER, address(burner));
        // 3. factory
        factory = new LaunchFactory(
            RHAddresses.POSITION_MANAGER, ROUTER, WETH,
            address(locker), feeCollector, LAUNCH_FEE, OPEN_TICK, address(this)
        );
        // 4. wire the factory into the burner (once)
        burner.init(address(factory));
        // 5. deployer launches $ZORCH (the first launch)
        vm.deal(address(this), 100 ether);
        (zorch,, zorchTokenId) = factory.launch{value: LAUNCH_FEE}("Zorch", "ZORCH", "", "", "");
    }

    receive() external payable {}

    // Advance past the TWAP window with no trades, so every pool's spot ≈ its TWAP
    // and the anti-sandwich guard lets buybacks/conversions proceed.
    function _settle() internal {
        vm.warp(block.timestamp + uint256(burner.TWAP_WINDOW()) + 5);
    }

    // Launch a meme from `creator`.
    function _launchMeme() internal returns (address token, uint256 tokenId) {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (token,, tokenId) = factory.launch{value: LAUNCH_FEE}("Meme", "MEME", "", "", "");
    }

    function _buy(address token, uint256 ethIn, address who) internal returns (uint256 out) {
        vm.deal(who, who.balance + ethIn);
        vm.startPrank(who);
        IWETH(WETH).deposit{value: ethIn}();
        IWETH(WETH).approve(ROUTER, ethIn);
        out = ISwapRouter02(ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: WETH, tokenOut: token, fee: FEE, recipient: who,
                amountIn: ethIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _sell(address token, uint256 amountIn, address who) internal returns (uint256 out) {
        vm.startPrank(who);
        FairLaunchToken(token).approve(ROUTER, amountIn);
        out = ISwapRouter02(ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token, tokenOut: WETH, fee: FEE, recipient: who,
                amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _fundBurnerWeth(uint256 amt) internal {
        vm.deal(address(this), address(this).balance + amt);
        IWETH(WETH).deposit{value: amt}();
        IWETH(WETH).transfer(address(burner), amt);
    }

    // --- init ---

    function test_Init_OnlyDeployerOnce() public {
        BuybackBurner b = new BuybackBurner(WETH, ROUTER, V3_FACTORY, REWARD_BPS, address(this));
        vm.prank(buyer);
        vm.expectRevert(bytes("only deployer"));
        b.init(address(factory));

        b.init(address(factory));
        vm.expectRevert(bytes("already init"));
        b.init(address(factory));
    }

    // --- full flywheel: meme fees → crank → buy $ZORCH → burn ---

    function test_Crank_ConvertsBuysAndBurns() public {
        (address meme, uint256 tokenId) = _launchMeme();

        // Trade the meme both ways so its locked LP accrues fees on BOTH sides:
        // a buy accrues WETH-side fees, a sell accrues meme-side fees.
        uint256 got = _buy(meme, 1 ether, buyer);
        _sell(meme, got / 2, buyer);

        // Collect the meme pool fees → forwarded to the burner (WETH + meme).
        locker.collect(tokenId);
        assertGt(IWETH(WETH).balanceOf(address(burner)), 0, "burner got no WETH fee");
        assertGt(FairLaunchToken(meme).balanceOf(address(burner)), 0, "burner got no meme fee");

        uint256 supplyBefore = FairLaunchToken(zorch).totalSupply();
        uint256 crankerWethBefore = IWETH(WETH).balanceOf(cranker);

        _settle(); // spot ≈ TWAP so the anti-sandwich guard lets the swaps through

        // Anyone cranks: convert meme → WETH, tip the cranker, buy $ZORCH, burn it.
        vm.prank(cranker);
        burner.crank(meme);

        // Meme fully converted; all WETH deployed; all bought $ZORCH burned.
        assertEq(FairLaunchToken(meme).balanceOf(address(burner)), 0, "meme not fully converted");
        assertEq(IWETH(WETH).balanceOf(address(burner)), 0, "WETH not fully deployed");
        assertEq(FairLaunchToken(zorch).balanceOf(address(burner)), 0, "bought $ZORCH not burned");

        // $ZORCH totalSupply strictly dropped (a REAL burn) ...
        assertLt(FairLaunchToken(zorch).totalSupply(), supplyBefore, "supply not reduced by burn");
        // ... and the cranker earned a WETH tip.
        assertGt(IWETH(WETH).balanceOf(cranker) - crankerWethBefore, 0, "cranker got no reward");
    }

    // --- reward is proportional to the WETH deployed ---

    function test_Crank_RewardIsProportional() public {
        (address meme, uint256 tokenId) = _launchMeme();
        _buy(meme, 1 ether, buyer);
        locker.collect(tokenId); // burner now holds WETH (buy-side fee)

        uint256 wethIn = IWETH(WETH).balanceOf(address(burner));
        uint256 expectedReward = (wethIn * REWARD_BPS) / 10000;

        _settle();
        uint256 before = IWETH(WETH).balanceOf(cranker);
        vm.prank(cranker);
        burner.crank(address(0)); // skip conversion; just tip + buyback + burn
        assertEq(IWETH(WETH).balanceOf(cranker) - before, expectedReward, "reward != rewardBps of WETH");
    }

    // --- $ZORCH accrued directly (sell-side fees) is burned without a swap ---

    function test_Crank_BurnsAccruedZorchDirectly() public {
        // Simulate $ZORCH accruing to the burner from its own pool's sell-side
        // fees by sending it $ZORCH directly (this test contract holds none post
        // single-sided launch, so buy some first, then hand it to the burner).
        uint256 got = _buy(zorch, 1 ether, address(this));
        FairLaunchToken(zorch).transfer(address(burner), got);

        uint256 supplyBefore = FairLaunchToken(zorch).totalSupply();
        vm.prank(cranker);
        burner.crank(address(0)); // no WETH held → no buyback; just burns the $ZORCH (no gate)
        assertEq(FairLaunchToken(zorch).balanceOf(address(burner)), 0, "accrued $ZORCH not burned");
        assertEq(FairLaunchToken(zorch).totalSupply(), supplyBefore - got, "supply not reduced by exact burn");
    }

    // --- anti-sandwich: a manipulated spot skips the buyback (the H-1 fix) ---

    function test_Crank_SkipsBuyback_WhenZorchSpotManipulated() public {
        // Build a real, stable TWAP on the $ZORCH pool: a calm trade, then let the
        // window elapse so an observation records the calm price.
        _buy(zorch, 0.05 ether, buyer);
        _settle();

        // Fund the burner with WETH to buy back with (simulated accrued fees).
        _fundBurnerWeth(1 ether);

        // Attacker's front-run: a large buy spikes $ZORCH spot far above the TWAP,
        // in the same block as the crank (the atomic self-sandwich setup).
        _buy(zorch, 40 ether, buyer);

        uint256 supplyBefore = FairLaunchToken(zorch).totalSupply();
        uint256 burnerWethBefore = IWETH(WETH).balanceOf(address(burner));
        uint256 crankerWethBefore = IWETH(WETH).balanceOf(cranker);

        vm.prank(cranker);
        burner.crank(address(0)); // guard sees spot ≫ TWAP → skips the buyback

        assertEq(IWETH(WETH).balanceOf(address(burner)), burnerWethBefore, "WETH must be untouched when skipped");
        assertEq(FairLaunchToken(zorch).totalSupply(), supplyBefore, "no burn when buyback is skipped");
        assertEq(IWETH(WETH).balanceOf(cranker), crankerWethBefore, "no tip paid for a skipped buyback");
    }

    // --- anti-sandwich: a calm pool DOES let the buyback through ---

    function test_Crank_ExecutesBuyback_WhenCalm() public {
        _fundBurnerWeth(1 ether);
        // Two small trades across the window → a real TWAP that tracks a stable spot.
        _buy(zorch, 0.02 ether, buyer);
        vm.warp(block.timestamp + 20);
        _buy(zorch, 0.02 ether, buyer);
        vm.warp(block.timestamp + uint256(burner.TWAP_WINDOW()) + 5);

        uint256 supplyBefore = FairLaunchToken(zorch).totalSupply();
        uint256 wethBefore = IWETH(WETH).balanceOf(address(burner));
        vm.prank(cranker);
        burner.crank(address(0));
        assertLt(IWETH(WETH).balanceOf(address(burner)), wethBefore, "calm buyback should spend WETH");
        assertLt(FairLaunchToken(zorch).totalSupply(), supplyBefore, "calm buyback should burn $ZORCH");
    }

    // --- crank never reverts on an empty / depleted state ---

    function test_Crank_EmptyState_NoRevert() public {
        _settle();
        vm.prank(cranker);
        burner.crank(address(0)); // nothing held anywhere
        assertEq(IWETH(WETH).balanceOf(address(burner)), 0);
    }

    function test_Crank_SellMemeIntoDrainedPool_NoRevert() public {
        (address meme, uint256 tokenId) = _launchMeme();
        // Round-trip hard: buy, then sell ALL back, several times. Each sell accrues
        // meme-side fees while draining the pool's WETH — the burner ends holding
        // meme it must sell into a WETH-thin pool. Price returns near the open each
        // round, so after _settle spot ≈ TWAP and the conversion proceeds; it must
        // NOT revert selling into the thin pool.
        for (uint256 i = 0; i < 3; i++) {
            uint256 got = _buy(meme, 1 ether, buyer);
            _sell(meme, got, buyer);
        }
        locker.collect(tokenId);
        assertGt(FairLaunchToken(meme).balanceOf(address(burner)), 0, "burner should hold meme fees");

        _settle();
        vm.prank(cranker);
        burner.crank(meme); // sells meme into a WETH-thin pool — tolerant, no revert
        assertEq(IWETH(WETH).balanceOf(address(burner)), 0, "WETH not deployed");
    }

    function test_Crank_DepletedMemePool_NoRevert() public {
        (address meme, uint256 tokenId) = _launchMeme();
        // A buy with no matching sell: pool has WETH fees but the burner holds no
        // meme. crank(meme) finds 0 meme to convert and proceeds to buyback+burn.
        _buy(meme, 0.5 ether, buyer);
        locker.collect(tokenId);
        _settle();
        uint256 supplyBefore = FairLaunchToken(zorch).totalSupply();
        vm.prank(cranker);
        burner.crank(meme);
        assertLt(FairLaunchToken(zorch).totalSupply(), supplyBefore, "buyback+burn should still run");
    }
}
