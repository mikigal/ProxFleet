#!/bin/zsh
# Builds ProxFleet, installs it in a Simulator and launches it.
#
#   scripts/run-simulator.sh            # normal launch
#   scripts/run-simulator.sh --demo     # open the demo cluster, nothing saved
#   scripts/run-simulator.sh --test     # sign in to the test server from Config/TestServer.local.env
#   scripts/run-simulator.sh --test-pbs # sign in to the backup server from Config/TestServerPBS.local.env
#
# The env files are ignored by git. See Config/TestServer.example.env.
set -euo pipefail

ROOT="${0:A:h:h}"
DEVICE="${SIMULATOR_DEVICE:-iPhone 17}"
BUNDLE_ID="$(grep -E '^BUNDLE_ID_PREFIX' "$ROOT/Config/Signing.local.xcconfig" 2>/dev/null | awk -F'= *' '{print $2}' || true)"
BUNDLE_ID="${BUNDLE_ID:-dev.example}.proxfleet"
DERIVED="$ROOT/build/DerivedData"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

xcodebuild -project "$ROOT/ProxFleet.xcodeproj" -scheme ProxFleet \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DERIVED" -quiet build

xcrun simctl install "$DEVICE" "$DERIVED/Build/Products/Debug-iphonesimulator/ProxFleet.app"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true

args=()
case "${1:-}" in
  --demo)
    args=(-inMemory -demo)
    ;;
  --test|--test-pbs)
    env_file="$ROOT/Config/TestServer.local.env"
    if [[ "$1" == --test-pbs ]]; then
      env_file="$ROOT/Config/TestServerPBS.local.env"
      export SIMCTL_CHILD_PROXFLEET_DEBUG_PRODUCT=backupServer
    fi
    [[ -f "$env_file" ]] || { echo "Missing $env_file (copy Config/TestServer.example.env)"; exit 1; }
    # Variables prefixed with SIMCTL_CHILD_ are passed to the app's environment.
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      export "SIMCTL_CHILD_PROXFLEET_DEBUG_${key}=${value}"
    done < "$env_file"
    args=(-inMemory)
    ;;
esac

xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "${args[@]}"
