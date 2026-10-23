#!/bin/zsh
# Builds the App Store screenshots in docs/appstore/iphone (1206 x 2622, the 6.3" size) and docs/appstore/ipad
# (2064 x 2752, the 13" size): a headline over an iPhone or iPad showing a capture from docs/appstore/raw, tilted in 3D
# or seen straight on. The layout lives in scripts/appstore/frame.html, which lays the iPhone out at 1320 x 2868; that
# render is scaled down to 1206 x 2622 (the two differ in shape by under 0.1%).
# It also builds the wide art from scripts/appstore/banner.html: docs/appstore/header.png (3840 x 1646) and
# docs/appstore/search-result.png (3840 x 2560).
#
#   scripts/make-appstore-screenshots.sh           # everything
#   scripts/make-appstore-screenshots.sh ipad      # one set: iphone, ipad or banners
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
  iphone "8-migrate"  "flat" "Live-migrate|between nodes." "Right from your phone."
  iphone "9-ha"       "flat" "A node went down?"           "HA has your back."
  iphone "10-ceph"    "flat" "Ceph health|at a glance."    "Spot trouble fast."
  ipad   "1-cluster"  "3d"   "Your entire|Proxmox fleet."  "In your hands."
  ipad   "2-guest"    "flat" "Every VM.|Every container."  "One tap away."
  ipad   "3-hardware" "flat" "Edit hardware|on the fly."   "No laptop needed."
  ipad   "4-console"  "flat" "Server down|at 3 AM?"        "Fix it from bed."
  ipad   "5-create"   "flat" "Spin up VMs|and containers." "From the couch."
  ipad   "6-backups"  "flat" "Backups on|autopilot."       "Set it. Forget it."
  ipad   "7-more"     "flat" "Not just|start and stop."    "Fine-tune anything."
  ipad   "8-migrate"  "flat" "Live-migrate|between nodes." "Right from your iPad."
  ipad   "9-ha"       "flat" "A node went down?"           "HA has your back."
  ipad   "10-ceph"    "flat" "Ceph health|at a glance."    "Spot trouble fast."
)

encode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Renders the page at <url> into <out> at <width> x <height>; see capture.py.
render() { python3 -I "$ROOT/scripts/appstore/capture.py" "$CHROME" "$@"; }

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
  render "$url" $width $height "$tmp/$device-$name.png"
  if [[ "$width $height" == "$size" ]]; then
    mv "$tmp/$device-$name.png" "$ROOT/docs/appstore/$device/$name.png"
  else
    swift "$ROOT/scripts/appstore/crop.swift" "$tmp/$device-$name.png" "$ROOT/docs/appstore/$device/$name.png" \
      $width $height $size
  fi
  echo "docs/appstore/$device/$name.png"
done

# Layout in banner.html, file name, width and height.
BANNERS=(
  header "header"        3840 1646
  search "search-result" 3840 2560
)
[[ -n "$ONLY" && "$ONLY" != banners ]] && exit 0
for layout name width height in "${BANNERS[@]}"; do
  render "file://$ROOT/scripts/appstore/banner.html?layout=$layout" $width $height "$ROOT/docs/appstore/$name.png"
  echo "docs/appstore/$name.png"
done
