#!/usr/bin/env bash
#
# Verify the deployed Zorch contracts on Robinhood Chain (Blockscout).
#
# The deploy page (deploy.html) prints a "Deployment Record" — a block of
# `export ...` lines with the exact deploy-time values. Paste that block into
# your shell, then run this script from the repo root:
#
#     export DEPLOYER=0x...   BURNER=0x...   LOCKER=0x...   FACTORY=0x...
#     export REWARD_BPS=100   LAUNCH_FEE_WEI=300000000000000   OPEN_TICK=204200
#     # optional, to also verify the platform token $ZORCH:
#     export ZORCH=0x...  ZORCH_NAME=Zorch  ZORCH_SYMBOL=ZORCH
#     export ZORCH_LOGO=ipfs://...  ZORCH_DESC='...'  ZORCH_SOCIALS='https://x.com/...'
#
#     bash script/verify.sh
#
# Constructor args are re-derived here from those values, so verification
# reproduces the exact bytecode. Compiler version / optimizer / via-IR are read
# from foundry.toml automatically.

set -euo pipefail

# --- required deploy-time values ---
: "${DEPLOYER:?set DEPLOYER (your wallet = feeCollector = deployer)}"
: "${BURNER:?set BURNER (BuybackBurner address)}"
: "${LOCKER:?set LOCKER (LpLocker address)}"
: "${FACTORY:?set FACTORY (LaunchFactory address)}"
: "${REWARD_BPS:?set REWARD_BPS}"
: "${LAUNCH_FEE_WEI:?set LAUNCH_FEE_WEI}"
: "${OPEN_TICK:?set OPEN_TICK}"

# --- optional $ZORCH platform token ---
ZORCH="${ZORCH:-}"
ZORCH_NAME="${ZORCH_NAME:-Zorch}"
ZORCH_SYMBOL="${ZORCH_SYMBOL:-ZORCH}"
ZORCH_LOGO="${ZORCH_LOGO:-}"
ZORCH_DESC="${ZORCH_DESC:-}"
ZORCH_SOCIALS="${ZORCH_SOCIALS:-}"

# --- fixed Robinhood Chain constants (must match src/RHAddresses.sol) ---
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
PM=0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3
ROUTER=0xCaf681a66D020601342297493863E78C959E5cb2
V3F=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
SUPPLY=1000000000000000000000000000 # 1e27, fixed total supply

VERIFIER=(--chain 4663 --verifier blockscout
  --verifier-url https://robinhoodchain.blockscout.com/api/ --watch)

echo "==> BuybackBurner  $BURNER"
forge verify-contract "$BURNER" src/BuybackBurner.sol:BuybackBurner "${VERIFIER[@]}" \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,uint256,address)' \
    "$WETH" "$ROUTER" "$V3F" "$REWARD_BPS" "$DEPLOYER")"

echo "==> LpLocker  $LOCKER"
forge verify-contract "$LOCKER" src/LpLocker.sol:LpLocker "${VERIFIER[@]}" \
  --constructor-args "$(cast abi-encode 'constructor(address,address)' "$PM" "$BURNER")"

echo "==> LaunchFactory  $FACTORY"
# constructor(positionManager, swapRouter, weth, locker, feeCollector, launchFee, openTick, deployer)
# feeCollector == deployer == your wallet
forge verify-contract "$FACTORY" src/LaunchFactory.sol:LaunchFactory "${VERIFIER[@]}" \
  --constructor-args "$(cast abi-encode \
    'constructor(address,address,address,address,address,uint256,int24,address)' \
    "$PM" "$ROUTER" "$WETH" "$LOCKER" "$DEPLOYER" "$LAUNCH_FEE_WEI" "$OPEN_TICK" "$DEPLOYER")"

if [ -n "$ZORCH" ]; then
  echo "==> FairLaunchToken (\$ZORCH)  $ZORCH"
  # constructor(name, symbol, supply, recipient=factory, logo, description, socials)
  forge verify-contract "$ZORCH" src/FairLaunchToken.sol:FairLaunchToken "${VERIFIER[@]}" \
    --constructor-args "$(cast abi-encode \
      'constructor(string,string,uint256,address,string,string,string)' \
      "$ZORCH_NAME" "$ZORCH_SYMBOL" "$SUPPLY" "$FACTORY" "$ZORCH_LOGO" "$ZORCH_DESC" "$ZORCH_SOCIALS")"
fi

echo
echo "Done. Inspect verified source at:"
echo "  https://robinhoodchain.blockscout.com/address/$FACTORY?tab=contract"
