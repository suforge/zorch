// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {INonfungiblePositionManager} from "./interfaces/UniV3.sol";

/// @title LpLocker
/// @notice Permanently holds Uniswap v3 LP position NFTs. There is deliberately
///         NO function to transfer a position out or to `decreaseLiquidity`, so
///         locked liquidity can never be withdrawn — this is the structural
///         no-rug guarantee. The only thing anyone can do is `collect()` the
///         accrued swap fees, which are forwarded to an immutable `feeSink`
///         (the buyback engine).
///
/// Immutable, ownerless. Auditable in isolation.
contract LpLocker {
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Where collected fees are sent (the BuybackBurner).
    address public immutable feeSink;

    event Locked(uint256 indexed tokenId);
    event Collected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    constructor(address _positionManager, address _feeSink) {
        require(_positionManager != address(0) && _feeSink != address(0), "zero addr");
        positionManager = INonfungiblePositionManager(_positionManager);
        feeSink = _feeSink;
    }

    /// @notice Accept LP position NFTs (from the launch factory). Once here, the
    ///         position can never leave.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        require(msg.sender == address(positionManager), "only PM NFTs");
        emit Locked(tokenId);
        return this.onERC721Received.selector;
    }

    /// @notice Permissionless: collect accrued swap fees for a locked position and
    ///         forward them straight to the fee sink. Anyone may call. Does NOT
    ///         touch principal liquidity (never calls decreaseLiquidity).
    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: feeSink,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit Collected(tokenId, amount0, amount1);
    }
}
