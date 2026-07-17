// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwapRouter02, IWETH, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/UniV3.sol";

/// @dev Minimal ERC-20 surface the burner needs from launched tokens.
interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev The real deflationary burn on FairLaunchToken (reduces totalSupply).
interface IBurnable {
    function burn(uint256) external;
}

/// @dev Read the platform token off the factory at runtime. Reading it lazily
///      (instead of taking it as a constructor immutable) is what breaks the
///      factory↔locker↔burner deploy cycle: the burner can exist before $ZORCH.
interface ILaunchFactory {
    function platformToken() external view returns (address);
}

/// @title BuybackBurner
/// @notice The flywheel engine. Every launched token's locked LP forwards its 1%
///         swap fees here (this contract is the locker's immutable `feeSink`).
///         Over time this contract accrues, per pool: WETH (from buys) and the
///         meme token (from sells) — plus, from the $ZORCH pool, $ZORCH itself.
///
///         Anyone can `crank(memeToken)`:
///           1. sell this contract's balance of `memeToken` → WETH,
///           2. pay the caller a small proportional reward in WETH (the on-chain
///              incentive so cranking is profitable, not just gas-neutral),
///           3. buy $ZORCH with the remaining WETH,
///           4. `burn()` all $ZORCH held (the just-bought lot + any accrued from
///              the $ZORCH pool's own fees) — a REAL supply reduction.
///
///         So 100% of platform trading fees (minus the crank tip) become a
///         permanent $ZORCH burn. There is no admin, no withdrawal, no parameter
///         to change: the only exit for value that lands here is "buy $ZORCH and
///         burn it". Immutable and ownerless after `init`.
///
/// ### Deploy order (breaks the circular dependency)
///   1. deploy BuybackBurner(weth, swapRouter, rewardBps, deployer)  // no factory
///   2. deploy LpLocker(positionManager, feeSink = this burner)
///   3. deploy LaunchFactory(..., locker, ...)
///   4. burner.init(factory)                                          // deployer, once
///   5. deployer launches $ZORCH via the factory
///   From step 5 on, `feeSink` is already the final burner and $ZORCH is set.
///
/// ### Slippage / MEV — anti-sandwich TWAP guard
///   Naively swapping with `amountOutMinimum = 0` would be exploitable even
///   though Robinhood Chain has no public mempool: an attacker doesn't need to
///   see a victim's pending crank — they can bracket their OWN crank call inside
///   one atomic tx (front-run buy → crank → back-run sell) and skim the buyback.
///   To stop this, before EITHER swap the burner checks the pool's spot tick
///   against a short TWAP (`_priceInBand`): if spot has been pushed more than
///   `MAX_DEV_TICKS` from the time-averaged price, it SKIPS that leg this round
///   (leaving the funds to convert on a later, calm crank) rather than swapping
///   into a manipulated price. A front-run therefore makes the crank a no-op —
///   the attacker just loses their own fees. The skip (never a revert) also
///   preserves the "a dead/thin pool can't brick the crank" property. Once past
///   the guard, `amountOutMinimum = 0` is safe because spot ≈ TWAP means no
///   manipulation is in flight. Funds are never stolen from the contract's
///   resting balance; the guard protects the *flow* destined for the burn.
contract BuybackBurner {
    /// @notice 1% fee tier — every launch pool (incl. $ZORCH) uses this tier.
    uint24 public constant FEE = 10000;

    /// @notice Reward tip paid to the crank caller, in basis points of the WETH
    ///         deployed that round. Fixed at deploy; bounded to a sane maximum.
    uint256 public constant MAX_REWARD_BPS = 500; // 5% hard cap

    /// @notice Anti-sandwich guard: TWAP averaging window (seconds) and the max
    ///         allowed spot-vs-TWAP tick deviation. ~200 ticks ≈ 2%; since every
    ///         pool is the 1% fee tier, a round-trip sandwich pays ~2% in fees, so
    ///         a price push kept within this band cannot be profitably exploited,
    ///         while normal sub-2% drift still lets buybacks proceed.
    uint32 public constant TWAP_WINDOW = 30;
    int24 public constant MAX_DEV_TICKS = 200;

    IWETH public immutable weth;
    ISwapRouter02 public immutable swapRouter;
    /// @notice Uniswap v3 factory — used to find each pool for its TWAP guard.
    IUniswapV3Factory public immutable v3Factory;
    uint256 public immutable rewardBps;

    /// @notice May call `init` exactly once, to wire the factory.
    address public immutable deployer;

    /// @notice The launch factory. Set once via `init`. `$ZORCH` is read from it
    ///         at crank time (`factory.platformToken()`), never cached as immutable.
    ILaunchFactory public factory;

    uint256 private _locked; // reentrancy guard

    event Converted(address indexed token, uint256 amountIn, uint256 wethOut);
    event RewardPaid(address indexed caller, uint256 wethAmount);
    event BoughtBack(uint256 wethSpent, uint256 zorchBought);
    event Burned(uint256 zorchAmount);
    event Initialized(address indexed factory);

    modifier nonReentrant() {
        require(_locked == 0, "reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    /// @param _weth       wrapped native token
    /// @param _swapRouter Uniswap SwapRouter02
    /// @param _v3Factory  Uniswap v3 factory (to locate pools for the TWAP guard)
    /// @param _rewardBps  crank tip in bps of WETH deployed (<= MAX_REWARD_BPS)
    /// @param _deployer   the account allowed to call `init` once
    constructor(address _weth, address _swapRouter, address _v3Factory, uint256 _rewardBps, address _deployer) {
        require(
            _weth != address(0) && _swapRouter != address(0) && _v3Factory != address(0) && _deployer != address(0),
            "zero addr"
        );
        require(_rewardBps <= MAX_REWARD_BPS, "reward too high");
        weth = IWETH(_weth);
        swapRouter = ISwapRouter02(_swapRouter);
        v3Factory = IUniswapV3Factory(_v3Factory);
        rewardBps = _rewardBps;
        deployer = _deployer;
    }

    /// @notice Wire the launch factory. Callable once, by the deployer only. This
    ///         is the single late-bound edge that lets the burner be deployed
    ///         before the factory (see the deploy-order note above).
    function init(address _factory) external {
        require(msg.sender == deployer, "only deployer");
        require(address(factory) == address(0), "already init");
        require(_factory != address(0), "zero addr");
        // Sanity: the target must implement platformToken() (reverts otherwise),
        // so a wrong address can't be wired in and silently brick every crank.
        ILaunchFactory(_factory).platformToken();
        factory = ILaunchFactory(_factory);
        emit Initialized(_factory);
    }

    /// @notice Permissionless crank: convert one meme's accrued fees to WETH, tip
    ///         the caller, buy $ZORCH with the rest, and burn all $ZORCH held.
    /// @param memeToken The token to convert this round. Pass address(0) (or WETH,
    ///                  or $ZORCH itself) to SKIP conversion and just run the
    ///                  buyback+burn on already-accrued WETH/$ZORCH. Never reverts
    ///                  on an empty or depleted state — it simply does less.
    function crank(address memeToken) external nonReentrant {
        address zorch = address(factory) == address(0) ? address(0) : factory.platformToken();

        // 1. Convert the meme's accrued balance → WETH. Skip WETH/$ZORCH/zero:
        //    we never sell $ZORCH (we burn it), and WETH needs no conversion. Only
        //    swap if the meme pool's spot is in-band vs its TWAP (anti-sandwich);
        //    otherwise skip — the meme stays and converts on a later calm crank.
        if (memeToken != address(0) && memeToken != address(weth) && memeToken != zorch) {
            uint256 memeBal = IERC20Min(memeToken).balanceOf(address(this));
            if (memeBal > 0 && _priceInBand(memeToken, address(weth))) {
                _approve(memeToken, memeBal);
                uint256 out = swapRouter.exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                        tokenIn: memeToken,
                        tokenOut: address(weth),
                        fee: FEE,
                        recipient: address(this),
                        amountIn: memeBal,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                );
                emit Converted(memeToken, memeBal, out);
            }
        }

        // Before $ZORCH exists there is nothing to buy or burn. (In practice the
        // burner receives no fees pre-launch, since the first launch IS $ZORCH.)
        if (zorch != address(0)) {
            // 2+3. Only buy $ZORCH (and tip the caller) when the $ZORCH pool's spot
            //      is in-band vs its TWAP. A manipulated price makes this a no-op:
            //      the WETH simply waits for a later calm crank. No tip is paid when
            //      no buyback happens, so nobody is rewarded for a skipped round.
            uint256 wethBal = weth.balanceOf(address(this));
            if (wethBal > 0 && _priceInBand(address(weth), zorch)) {
                uint256 reward = (wethBal * rewardBps) / 10000;
                if (reward > 0) {
                    require(weth.transfer(msg.sender, reward), "reward xfer");
                    wethBal -= reward;
                    emit RewardPaid(msg.sender, reward);
                }
                if (wethBal > 0) {
                    _approve(address(weth), wethBal);
                    uint256 bought = swapRouter.exactInputSingle(
                        ISwapRouter02.ExactInputSingleParams({
                            tokenIn: address(weth),
                            tokenOut: zorch,
                            fee: FEE,
                            recipient: address(this),
                            amountIn: wethBal,
                            amountOutMinimum: 0,
                            sqrtPriceLimitX96: 0
                        })
                    );
                    emit BoughtBack(wethBal, bought);
                }
            }

            // 4. Burn every $ZORCH held: the lot just bought plus any $ZORCH accrued
            //    directly from the $ZORCH pool's own sell-side fees. A real burn.
            //    Always runs (no swap, no price risk) so accrued $ZORCH never lingers.
            uint256 zorchBal = IERC20Min(zorch).balanceOf(address(this));
            if (zorchBal > 0) {
                IBurnable(zorch).burn(zorchBal);
                emit Burned(zorchBal);
            }
        }
    }

    /// @dev True if the pool's current spot tick is within MAX_DEV_TICKS of its
    ///      TWAP over TWAP_WINDOW seconds. Returns false (→ caller skips the swap)
    ///      when the pool doesn't exist or the oracle can't yet serve the window,
    ///      so a manipulated OR not-yet-ready pool defers rather than swaps blind.
    ///      Only integer tick arithmetic — no price/amount math — so it is simple
    ///      to audit and cannot itself mis-price a swap.
    function _priceInBand(address tokenIn, address tokenOut) internal view returns (bool) {
        address pool = v3Factory.getPool(tokenIn, tokenOut, FEE);
        if (pool == address(0)) return false;
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        try IUniswapV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
            int24 twapTick = int24((tc[1] - tc[0]) / int56(uint56(TWAP_WINDOW)));
            (, int24 spot,,,,,) = IUniswapV3Pool(pool).slot0();
            int24 diff = spot - twapTick;
            if (diff < 0) diff = -diff;
            return diff <= MAX_DEV_TICKS;
        } catch {
            return false; // oracle window not available yet → defer, don't swap blind
        }
    }

    /// @dev Approve exactly `amount` of `token` to the router, checking the return.
    function _approve(address token, uint256 amount) internal {
        require(IERC20Min(token).approve(address(swapRouter), amount), "approve failed");
    }
}
