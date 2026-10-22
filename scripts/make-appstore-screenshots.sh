#!/bin/zsh
# Builds the App Store screenshots in docs/appstore (1320 x 2868, the 6.9" iPhone size): a headline over a 3D iPhone
# showing a capture from docs/appstore/raw. The layout lives in scripts/appstore/frame.html.
#
#   scripts/make-appstore-screenshots.sh
#
# Needs Google Chrome (set CHROME to use another path). The captures come from the iPhone 17 Simulator in demo mode:
#
#   scripts/run-simulator.sh --demo
#   xcrun simctl status_bar "iPhone 17" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 \
#     --batteryState discharging --batteryLevel 100
#   xcrun simctl io "iPhone 17" screenshot docs/appstore/raw/<name>.png
set -euo pipefail

ROOT="${0:A:h:h}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/docs/appstore"

# Name of the capture in docs/appstore/raw, the white headline lines separated by "|", and the orange last line.
SCREENSHOTS=(
  "1-cluster" "Your entire|Proxmox fleet." "In your pocket."
)

encode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for name title accent in "${SCREENSHOTS[@]}"; do
  url="file://$ROOT/scripts/appstore/frame.html?screen=$(encode "../../docs/appstore/raw/$name.png")&title=$(encode "$title")&accent=$(encode "$accent")"
  # The page is shorter than the window by Chrome's hidden toolbar, so render taller and keep the top.
  # Keep the GPU and real-time waiting: software rendering or virtual time leaves tiles of the 3D phone blank.
  "$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=1 --window-size=1320,3100 --timeout=3000 \
    --screenshot="$tmp/$name.png" "$url" >/dev/null 2>&1
  swift "$ROOT/scripts/appstore/crop.swift" "$tmp/$name.png" "$OUT/$name.png" 1320 2868
  echo "docs/appstore/$name.png"
done
