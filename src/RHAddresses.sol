// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RHAddresses
/// @notice Canonical Uniswap v3 + WETH addresses on Robinhood Chain (chainId 4663).
/// @dev Snapshot 2026-07; re-verify against the official Uniswap deployment page
///      before any mainnet use. Robinhood Chain uses the OFFICIAL Uniswap v3
///      deployment (not a fork), so aggregators/terminals recognize our pools.
library RHAddresses {
    uint256 internal constant CHAIN_ID = 4663;

    // Uniswap v3
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    // Wrapped native
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
}
