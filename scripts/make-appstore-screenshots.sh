#!/bin/zsh
# Builds the App Store screenshots in docs/appstore/iphone (1206 x 2622, the 6.3" size) and docs/appstore/ipad
# (2064 x 2752, the 13" size): a headline over an iPhone or iPad showing a capture from docs/appstore/raw, tilted in 3D
# or seen straight on. The layout lives in scripts/appstore/frame.html, which lays the iPhone out at 1320 x 2868; that
# render is scaled down to 1206 x 2622 (the two differ in shape by under 0.1%).
#
#   scripts/make-appstore-screenshots.sh           # both devices
#   scripts/make-appstore-screenshots.sh ipad      # one device
#
# Needs Google Chrome (set CHROME to use another path). The captures come from the iPhone 17 and iPad Pro 13-inch (M5)
# Simulators in demo mode and dark appearance, relaunched in US English so numbers and times read like the headlines.
# The iPad's status bar also shows the date, so the iPad Simulator itself must be in English (AppleLanguages and
# AppleLocale, then a reboot) while capturing:
#
#   SIMULATOR_DEVICE=<device> scripts/run-simulator.sh --demo
#   xcrun simctl launch --terminate-running-process <device> <bundle id> -inMemory -demo -AppleLocale en_US -AppleLanguages "(en)"
#   xcrun simctl status_bar <device> override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 \
#     --batteryState discharging --batteryLevel 100
#   xcrun simctl io <device> screenshot docs/appstore/raw/<iphone or ipad>/<name>.png
set -euo pipefail

ROOT="${0:A:h:h}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ONLY="${1:-}"

# Device, name of the capture in docs/appstore/raw/<device>, the device's look (3d or flat), the white headline lines
# separated by "|", and the orange last line. The first one is the eye-catcher in search results; the rest show the
# app up close. The iPad shows the same screens; an iPad does not fit in a pocket, though.
SCREENSHOTS=(
  iphone "1-cluster"  "3d"   "Your entire|Proxmox fleet."  "In your pocket."
  iphone "2-guest"    "flat" "Every VM.|Every container."  "One tap away."
  iphone "3-hardware" "flat" "Edit hardware|on the fly."   "No laptop needed."
  iphone "4-console"  "flat" "Server down|at 3 AM?"        "Fix it from bed."
  iphone "5-create"   "flat" "Spin up VMs|and containers." "From the couch."
  iphone "6-backups"  "flat" "Backups on|autopilot."       "Set it. Forget it."
  iphone "7-more"     "flat" "Not just|start and stop."    "Fine-tune anything."
  ipad   "1-cluster"  "3d"   "Your entire|Proxmox fleet."  "In your hands."
  ipad   "2-guest"    "flat" "Every VM.|Every container."  "One tap away."
  ipad   "3-hardware" "flat" "Edit hardware|on the fly."   "No laptop needed."
  ipad   "4-console"  "flat" "Server down|at 3 AM?"        "Fix it from bed."
  ipad   "5-create"   "flat" "Spin up VMs|and containers." "From the couch."
  ipad   "6-backups"  "flat" "Backups on|autopilot."       "Set it. Forget it."
  ipad   "7-more"     "flat" "Not just|start and stop."    "Fine-tune anything."
)

encode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for device name style title accent in "${SCREENSHOTS[@]}"; do
  [[ -n "$ONLY" && "$device" != "$ONLY" ]] && continue
  # The size of the page, then the size of the screenshot.
  case "$device" in
    iphone) width=1320 height=2868 size=(1206 2622) ;;
    ipad) width=2064 height=2752 size=(2064 2752) ;;
  esac
  mkdir -p "$ROOT/docs/appstore/$device"
  query="device=$device&style=$style&title=$(encode "$title")&accent=$(encode "$accent")"
  url="file://$ROOT/scripts/appstore/frame.html?screen=$(encode "../../docs/appstore/raw/$device/$name.png")&$query"
  # The page is shorter than the window by Chrome's hidden toolbar, so render taller and keep the top.
  # Keep the GPU and real-time waiting: software rendering or virtual time leaves tiles of the 3D device blank.
  "$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=1 --window-size=$width,$((height + 232)) \
    --timeout=3000 --screenshot="$tmp/$device-$name.png" "$url" >/dev/null 2>&1
  swift "$ROOT/scripts/appstore/crop.swift" "$tmp/$device-$name.png" "$ROOT/docs/appstore/$device/$name.png" \
    $width $height $size
  echo "docs/appstore/$device/$name.png"
done
