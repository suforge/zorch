// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FairLaunchToken} from "./FairLaunchToken.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Factory,
    IUniswapV3Pool,
    ISwapRouter02,
    IWETH
} from "./interfaces/UniV3.sol";

/// @title LaunchFactory
/// @notice One-click memecoin launch on Robinhood Chain:
///         deploy a plain ERC-20, seed a SINGLE-SIDED Uniswap v3 range order
///         (100% token, ZERO ETH), and lock the LP forever. First buy is
///         immediately tradeable; there is no migration. A single-sided range
///         holding 100% of supply and 0 WETH makes the token live from block one.
///
/// A flat launch fee (≈ $1 in ETH) goes to `feeCollector`. The 1% swap fee that
/// the pool earns is not handled here — it accrues in the locked position and is
/// swept by the buyback engine via the locker.
///
/// Immutable and ownerless after deploy (`feeCollector` is fixed). Bug fixes ship
/// as a NEW factory version, never as an upgrade to this one.
contract LaunchFactory {
    uint256 public constant VERSION = 1;

    // Uniswap v3 params for the 1% tier on Robinhood Chain.
    uint24 public constant FEE = 10000;
    int24 public constant TICK_SPACING = 200;
    // Widest tick-spacing-aligned bounds within [MIN_TICK, MAX_TICK].
    int24 internal constant MIN_ALIGNED = -887200;
    int24 internal constant MAX_ALIGNED = 887200;

    /// @notice Fixed total supply for every launched token (1B, 18 decimals).
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    /// @notice Observation-buffer size bootstrapped on every pool at launch, so
    ///         the BuybackBurner has a TWAP to sanity-check spot against before it
    ///         swaps (its anti-sandwich guard). Robinhood Chain produces blocks
    ///         sparsely, so 100 observations comfortably span the burner's short
    ///         TWAP window; if a pool ever gets so active the window isn't covered,
    ///         the burner just defers that buyback (never loses funds).
    uint16 public constant ORACLE_CARDINALITY = 100;

    INonfungiblePositionManager public immutable positionManager;
    address public immutable weth;
    address public immutable locker;
    address public immutable feeCollector;
    uint256 public immutable launchFee;

    /// @notice Uniswap SwapRouter02 — used only for the optional creator first-buy.
    address public immutable swapRouter;

    /// @notice Uniswap v3 factory (read from the position manager). Used to assert
    ///         a launched token's pool does not already exist before we create it.
    address public immutable v3Factory;

    /// @notice Opening tick magnitude; sets the opening price / market cap. The
    ///         single-sided range runs from here out to the aligned bound, so
    ///         price can climb (roughly) the full curve as buyers come in.
    int24 public immutable openTick;

    /// @notice The account allowed to perform the very first launch. That first
    ///         launch is the platform token ($ZORCH) — see `platformToken`.
    address public immutable deployer;

    /// @notice The platform token: the FIRST coin launched, set once and never
    ///         changed. All fees buy it back and burn it. Because only `deployer`
    ///         can do the first launch, no one can front-run this designation.
    address public platformToken;

    /// @notice Monotonic counter mixed into the CREATE2 salt so each launched
    ///         token gets a distinct address (see `launch`). Public because it
    ///         is derivable from history anyway; the launch's safety does not
    ///         rely on the salt being secret (see `launch`).
    uint256 public saltNonce;

    event Launched(
        address indexed token,
        address indexed pool,
        uint256 tokenId,
        address creator,
        string name,
        string symbol
    );
    event PlatformTokenSet(address indexed token);

    /// @param _positionManager Uniswap v3 NonfungiblePositionManager
    /// @param _swapRouter      Uniswap SwapRouter02 (creator first-buy)
    /// @param _weth            wrapped native token
    /// @param _locker          LpLocker that will hold every position NFT
    /// @param _feeCollector    receives the flat launch fee
    /// @param _launchFee       flat launch fee in wei (≈ $1)
    /// @param _openTick        opening tick magnitude (>0, multiple of TICK_SPACING)
    /// @param _deployer        the account allowed to do the first launch ($ZORCH);
    ///                         passed explicitly so it does not depend on how the
    ///                         factory itself is deployed (EOA vs CREATE2 helper)
    constructor(
        address _positionManager,
        address _swapRouter,
        address _weth,
        address _locker,
        address _feeCollector,
        uint256 _launchFee,
        int24 _openTick,
        address _deployer
    ) {
        require(
            _positionManager != address(0) && _swapRouter != address(0) && _weth != address(0)
                && _locker != address(0) && _feeCollector != address(0) && _deployer != address(0),
            "zero addr"
        );
        require(_openTick > 0 && _openTick < MAX_ALIGNED && _openTick % TICK_SPACING == 0, "bad openTick");
        positionManager = INonfungiblePositionManager(_positionManager);
        v3Factory = INonfungiblePositionManager(_positionManager).factory();
        swapRouter = _swapRouter;
        weth = _weth;
        locker = _locker;
        feeCollector = _feeCollector;
        launchFee = _launchFee;
        openTick = _openTick;
        deployer = _deployer;
    }

    /// @notice Launch a new token: mint 100% supply into a single-sided locked LP.
    /// @dev Caller pays exactly `launchFee` in ETH (nothing is used to seed the LP).
    /// @param logo         IPFS URI of the avatar image (may be empty)
    /// @param description  short text description (may be empty)
    /// @param socials      community links, e.g. JSON of twitter/telegram/website (may be empty)
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata logo,
        string calldata description,
        string calldata socials
    ) external payable returns (address token, address pool, uint256 tokenId) {
        // msg.value = launchFee + optional creator first-buy amount.
        require(msg.value >= launchFee, "insufficient value");

        // The FIRST launch is the platform token ($ZORCH): set once, immutable.
        // Only `deployer` may perform it, so the designation cannot be front-run.
        // No creator first-buy is allowed on it — $ZORCH must launch clean, with
        // no dev snipe, so everyone buys it on the open market on equal footing.
        bool isFirst = platformToken == address(0);
        if (isFirst) {
            require(msg.sender == deployer, "first launch: deployer only");
            require(msg.value == launchFee, "no first-buy on platform launch");
        }

        // 1. Deploy the token, 100% supply to this factory. Metadata (logo /
        //    description / socials) follows the Robinhood Chain convention so
        //    terminals like GMGN can display it — read straight off the token.
        //    CREATE2 with a salt mixing caller + block data + a nonce makes the
        //    token address vary per block/attempt. Note the salt is NOT secret
        //    (prevrandao is weak on this L2, the nonce is derivable) — so a griefer
        //    who knows a launch's exact metadata could still pre-create its pool.
        //    That is only a TEMPORARY grief now, not the old permanent brick: the
        //    `getPool()==0` guard below turns it into a clean revert, and a retry
        //    (next block, or one changed metadata byte) lands on a fresh address.
        //    On this FCFS chain with no public mempool, reactively targeting a
        //    specific pending launch is also impractical.
        bytes32 salt = keccak256(
            abi.encodePacked(msg.sender, block.number, block.prevrandao, saltNonce++)
        );
        FairLaunchToken t = new FairLaunchToken{salt: salt}(
            name, symbol, SUPPLY, address(this), logo, description, socials
        );
        token = address(t);
        if (isFirst) {
            platformToken = token;
            emit PlatformTokenSet(token);
        }

        // 2. Sort vs WETH and place the single-sided range on the token-only side.
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        int24 initTick;
        uint256 amount0Desired;
        uint256 amount1Desired;

        if (token < weth) {
            // TOKEN = token0. 100% token0 ⇒ current tick at/below range bottom.
            token0 = token;
            token1 = weth;
            tickLower = -openTick;
            tickUpper = MAX_ALIGNED;
            initTick = tickLower; // current == tickLower ⇒ position is all token0
            amount0Desired = SUPPLY;
            amount1Desired = 0;
        } else {
            // TOKEN = token1. 100% token1 ⇒ current tick at/above the range top.
            token0 = weth;
            token1 = token;
            tickLower = MIN_ALIGNED;
            tickUpper = openTick;
            initTick = tickUpper; // current == tickUpper ⇒ position is all token1
            amount0Desired = 0;
            amount1Desired = SUPPLY;
        }

        // 3. Create + initialize the pool at the opening price. Defense-in-depth:
        //    the pool must NOT already exist — otherwise `createAndInitialize…`
        //    would silently reuse a pool someone pre-initialized at a wrong price,
        //    breaking the single-sided mint. (The CREATE2 address above already
        //    makes this practically impossible; this makes it explicit.)
        require(IUniswapV3Factory(v3Factory).getPool(token0, token1, FEE) == address(0), "pool exists");
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(initTick);
        pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, FEE, sqrtPriceX96);

        // Bootstrap the pool's price oracle so the buyback engine can read a TWAP
        // and reject a manipulated spot before swapping (its anti-sandwich guard).
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(ORACLE_CARDINALITY);

        // 4. Mint the single-sided position straight to the locker (permanent lock).
        t.approve(address(positionManager), SUPPLY);
        (tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: locker,
                deadline: block.timestamp
            })
        );

        // 5. Forward the launch fee.
        if (launchFee > 0) {
            (bool ok,) = feeCollector.call{value: launchFee}("");
            require(ok, "fee xfer failed");
        }

        // 6. Optional creator first-buy: any ETH beyond the launch fee immediately
        //    buys the new token for the creator (pump.fun style). The 1% fee on
        //    this buy accrues in the locked LP — it already feeds the flywheel.
        //    Being the first swap in this same tx, it cannot be sandwiched.
        uint256 firstBuy = msg.value - launchFee;
        if (firstBuy > 0) {
            // Snapshot any stray WETH already sitting here (donated / mis-sent) so
            // we refund the creator ONLY their own unspent amount, never the stray.
            uint256 wethBefore = IWETH(weth).balanceOf(address(this));
            IWETH(weth).deposit{value: firstBuy}();
            IWETH(weth).approve(swapRouter, firstBuy);
            ISwapRouter02(swapRouter).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: token,
                    fee: FEE,
                    recipient: msg.sender,
                    amountIn: firstBuy,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            // Refund only THIS buy's unspent WETH (an over-large buy that ran out
            // of curve). Stray WETH is left untouched — see `sweepWeth`.
            uint256 unspent = IWETH(weth).balanceOf(address(this)) - wethBefore;
            if (unspent > 0) IWETH(weth).transfer(msg.sender, unspent);
        }

        emit Launched(token, pool, tokenId, msg.sender, name, symbol);
    }

    /// @notice Send any stray WETH held by this factory (donated or mistakenly
    ///         sent) to the fee collector. Permissionless — the destination is
    ///         fixed, so anyone may trigger it; nobody can redirect the funds.
    function sweepWeth() external {
        uint256 bal = IWETH(weth).balanceOf(address(this));
        if (bal > 0) IWETH(weth).transfer(feeCollector, bal);
    }
}
