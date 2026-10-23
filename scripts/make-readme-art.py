#!/usr/bin/env python3
# Builds the images of the README: docs/readme/hero.svg (the banner, from the screenshots in docs/screenshots),
# docs/readme/why.svg (the Why ProxFleet card), docs/readme/features.svg (the feature tiles) and
# docs/readme/roadmap.svg (the Coming next tiles).
# All of them share one background and the same glass cards, so they read as one set.
# The screenshots are embedded as JPEG, because an SVG shown as an image cannot load other files.
#
#   python3 -I scripts/make-readme-art.py
#
# Needs macOS (sips) for the JPEG conversion.
import base64
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/readme"

WIDTH = 1600
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Helvetica, Arial, sans-serif"

# 24x24 glyphs drawn with round strokes.
GLYPHS = {
    "servers": '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01M11 7.5h6M11 16.5h6"/>',
    "console": '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M7 10l3 2.5L7 15M12.5 15H17"/>',
    "chip": '<rect x="7" y="7" width="10" height="10" rx="1.5"/><path d="M10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4"/>',
    "create": '<rect x="3" y="3" width="18" height="18" rx="4.5"/><path d="M12 8v8M8 12h8"/>',
    "backup": '<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3.5 4v4.5H8"/><path d="M12 7.5V12l3 2"/>',
    "storage": '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    "sliders": '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
    "shield": '<path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6z"/><path d="M8.8 12.2l2.2 2.2 4.2-4.4"/>',
    "migrate": '<path d="M4 8h15M15.5 4.5L19 8l-3.5 3.5M20 16H5M8.5 12.5L5 16l3.5 3.5"/>',
    "sync": '<path d="M20 12a8 8 0 0 1-13.7 5.7M4 12a8 8 0 0 1 13.7-5.7"/><path d="M17.7 2.5v3.8h-3.8M6.3 21.5v-3.8h3.8"/>',
    "archive": '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V9M10 13h4"/>',
    "check": '<circle cx="12" cy="12" r="9"/><path d="M8.5 12.3l2.4 2.4 4.6-4.9"/>',
    "power": '<path d="M12 3v8"/><path d="M6.3 6.8a8 8 0 1 0 11.4 0"/>',
    "phone": '<rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M10.5 5.5h3M10 18.5h4"/>',
    "grid": '<rect x="3" y="3" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2"/>',
    "lock": '<rect x="4.5" y="10.5" width="15" height="10.5" rx="2.5"/><path d="M8 10.5V7a4 4 0 0 1 8 0v3.5M12 14.5v2.5"/>',
}

WHY = [
    ("phone", "Truly native", ["Built with SwiftUI from the", "ground up, not a web page", "squeezed onto a phone."]),
    ("grid", "Full control", ["Hardware, storage, backups,", "firewall, users and a native", "VNC console, all on the go."]),
    ("lock", "Open and private", ["No analytics, no tracking,", "no servers of our own. Your", "credentials stay on device."]),
]

FEATURES = [
    ("servers", "Servers and", "clusters"),
    ("console", "Native VNC", "console"),
    ("chip", "Hardware", "editing"),
    ("create", "Create, clone", "and migrate"),
    ("backup", "Backups and", "snapshots"),
    ("storage", "Storage and", "ISO downloads"),
    ("sliders", "Node", "management"),
    ("shield", "Firewall and", "permissions"),
]

ROADMAP = [
    ("sync", "High availability", "HA resources and rules,", "plus storage replication"),
    ("archive", "Backup Server", "Datastores, sync jobs and", "file-level restore"),
]

# Phones of the banner, from left to right: screenshot, center x, center y, scale, rotation, dimming.
# The middle one stands in front; the others fan out behind it, smaller, tilted and darker.
HERO_PHONES = [
    ("4-hardware", 262, 772, 0.8, -14, 0.42),
    ("1-resources", 518, 690, 0.9, -7, 0.22),
    ("2-vm", 800, 633, 1.0, 0, 0.0),
    ("5-node", 1082, 690, 0.9, 7, 0.22),
    ("3-console", 1338, 772, 0.8, 14, 0.42),
]

# Floating cards in front of the phones: x, y, accent color, glyph, title, subtitle.
HERO_CARDS = [
    (96, 318, "#30d158", "servers", "Cluster homelab", "3 nodes · Quorate"),
    (1160, 400, "#ff9f0a", "check", "Backup finished", "VM 102 · just now"),
    (150, 690, "#4da3ff", "power", "home-assistant", "Started on pve1"),
]

# Nodes of the network drawn faintly in the upper corners, kept clear of the titles, and the ones that glow.
HERO_NETWORK = (
    [(70, 70), (190, 36), (310, 112), (150, 186), (56, 262), (262, 250), (392, 44), (360, 300),
     (1236, 58), (1372, 30), (1520, 92), (1300, 170), (1452, 200), (1556, 268), (1206, 262), (1350, 300)],
    {2, 5, 10, 12},
)
# The tile cards have room only beside their title.
CARD_NETWORK = (
    [(64, 58), (176, 34), (290, 96), (140, 140), (402, 40), (452, 128),
     (1148, 52), (1262, 104), (1376, 36), (1468, 118), (1540, 58), (1320, 150)],
    {2, 9},
)

# Height of the section title drawn at the top of the tile cards.
TITLE_HEIGHT = 100


def background_defs(height: int, glow_opacity: float, glow_radius: int = 820) -> str:
    """Definitions shared by every image: the card shape, colors of the background and the glass cards."""
    blobs = [("violet", 180, 80, 640, "#7c4dff", 0.26), ("blue", 1460, 120, 620, "#2f6bff", 0.18),
             ("amber", 1180, height * 0.68, 440, "#ff9a3c", 0.10), ("titleGlow", 800, 140, 340, "#ff8a1f", 0.10),
             ("glow", 800, height * 0.96, glow_radius, "#E57000", glow_opacity)]
    gradients = "".join(f"""
    <radialGradient id="{name}" cx="{cx}" cy="{cy}" r="{r}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{color}" stop-opacity="{opacity}"/>
      <stop offset="1" stop-color="{color}" stop-opacity="0"/>
    </radialGradient>""" for name, cx, cy, r, color, opacity in blobs)
    return f"""
    <clipPath id="card"><rect width="{WIDTH}" height="{height}" rx="44"/></clipPath>
    <linearGradient id="background" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1b1b21"/>
      <stop offset="1" stop-color="#09090b"/>
    </linearGradient>{gradients}
    <linearGradient id="cardSheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.08"/>
      <stop offset="0.5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="cardShadow" x="-30%" y="-60%" width="160%" height="240%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000" flood-opacity="0.55"/>
    </filter>"""


def background(height: int, network: tuple) -> str:
    layers = "".join(f'<rect width="{WIDTH}" height="{height}" fill="url(#{name})"/>'
                     for name in ["background", "violet", "blue", "amber", "titleGlow", "glow"])
    return f"\n    {layers}{network_lines(*network)}"


def network_lines(points: list, lit: set) -> str:
    # Each node connects to its two nearest neighbours on the same side.
    lines = set()
    for i, (x, y) in enumerate(points):
        same_side = [j for j, (ox, _) in enumerate(points) if j != i and (ox < WIDTH / 2) == (x < WIDTH / 2)]
        nearest = sorted(same_side, key=lambda j: (points[j][0] - x) ** 2 + (points[j][1] - y) ** 2)[:2]
        lines.update(tuple(sorted((i, j))) for j in nearest)
    paths = "".join(f"M{points[a][0]} {points[a][1]}L{points[b][0]} {points[b][1]}" for a, b in sorted(lines))
    nodes = "".join(
        f'<circle cx="{x}" cy="{y}" r="14" fill="#ff8a1f" fill-opacity="0.16"/><circle cx="{x}" cy="{y}" r="5" fill="#ff9f40"/>'
        if i in lit else f'<circle cx="{x}" cy="{y}" r="3.5" fill="#fff" fill-opacity="0.28"/>'
        for i, (x, y) in enumerate(points)
    )
    return f'\n    <path d="{paths}" fill="none" stroke="#fff" stroke-opacity="0.09" stroke-width="1.5"/>\n    {nodes}'


def glass(x: float, y: float, w: float, h: float, r: float, opacity: float = 0.82, dashed: bool = False) -> str:
    """A frosted card like the ones floating in the banner."""
    border = 'stroke-opacity="0.2" stroke-dasharray="10 9"' if dashed else 'stroke-opacity="0.16"'
    return f"""
    <g filter="url(#cardShadow)">
      <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="#1f1f24" fill-opacity="{opacity}"/>
    </g>
    <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="url(#cardSheen)"/>
    <rect x="{x + 0.75}" y="{y + 0.75}" width="{w - 1.5}" height="{h - 1.5}" rx="{r - 0.75}" fill="none" stroke="#fff" {border} stroke-width="1.5"/>"""


def section_title(text: str, margin: int) -> str:
    return f"""
    <text x="{WIDTH / 2}" y="{margin + 52}" text-anchor="middle" font-family="{FONT}" font-size="58" font-weight="800" letter-spacing="-1.5" fill="#fff">{text}</text>"""


def card_border(height: int) -> str:
    return f'<rect x="1" y="1" width="{WIDTH - 2}" height="{height - 2}" rx="43" fill="none" stroke="#fff" stroke-opacity="0.08" stroke-width="2"/>'


def svg(height: int, title: str, defs: str, body: str) -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {height}" width="{WIDTH}" height="{height}">
  <title>{title}</title>
  <defs>{defs}
  </defs>
  <g clip-path="url(#card)">{body}
  </g>
  {card_border(height)}
</svg>
"""


def jpeg_data_uri(source: pathlib.Path) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        target = pathlib.Path(tmp) / f"{source.stem}.jpg"
        subprocess.run(
            ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", str(source), "--out", str(target)],
            check=True, capture_output=True,
        )
        return "data:image/jpeg;base64," + base64.b64encode(target.read_bytes()).decode()


def hero() -> str:
    height = 940
    screen_w = 300
    screen_h = round(screen_w * 1311 / 603)
    rim, bezel = 4, 11
    pad = rim + bezel
    phone_w, phone_h = screen_w + 2 * pad, screen_h + 2 * pad

    def phone(index: int, image: str, cx: float, cy: float, scale: float, angle: float, dim: float) -> str:
        island_w, island_h = 92, 27
        buttons = "".join(
            f'<rect x="{x}" y="{y}" width="6" height="{h}" rx="3" fill="url(#titanium)"/>'
            for x, y, h in [(-3, 128, 36), (-3, 188, 64), (-3, 266, 64), (phone_w - 3, 214, 100)]
        )
        dimming = f'<rect x="{pad}" y="{pad}" width="{screen_w}" height="{screen_h}" fill="#000" fill-opacity="{dim}"/>' if dim else ""
        return f"""
    <g transform="translate({cx} {cy}) rotate({angle}) scale({scale}) translate({-phone_w / 2} {-phone_h / 2})">
      <clipPath id="screen{index}"><rect x="{pad}" y="{pad}" width="{screen_w}" height="{screen_h}" rx="47"/></clipPath>
      {buttons}
      <rect width="{phone_w}" height="{phone_h}" rx="62" fill="url(#titanium)" filter="url(#phoneShadow)"/>
      <rect x="1.5" y="1.5" width="{phone_w - 3}" height="{phone_h - 3}" rx="60.5" fill="none" stroke="#fff" stroke-opacity="0.22" stroke-width="1.5"/>
      <rect x="{rim}" y="{rim}" width="{phone_w - 2 * rim}" height="{phone_h - 2 * rim}" rx="58" fill="#050505"/>
      <g clip-path="url(#screen{index})">
        <image href="{image}" x="{pad}" y="{pad}" width="{screen_w}" height="{screen_h}"/>
        {dimming}
        <rect x="{pad}" y="{pad}" width="{screen_w}" height="{screen_h}" fill="url(#glare)"/>
      </g>
      <rect x="{(phone_w - island_w) / 2}" y="{pad + 11}" width="{island_w}" height="{island_h}" rx="{island_h / 2}" fill="#000"/>
    </g>"""

    def card(x: int, y: int, color: str, glyph: str, title: str, subtitle: str) -> str:
        w, h = 340, 96
        icon_cx, icon_cy = x + 46, y + h / 2
        return f"""{glass(x, y, w, h, 26)}
    <circle cx="{icon_cx}" cy="{icon_cy}" r="27" fill="{color}" fill-opacity="0.18"/>
    <g transform="translate({icon_cx - 15} {icon_cy - 15}) scale(1.25)" fill="none" stroke="{color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{GLYPHS[glyph]}</g>
    <text x="{x + 90}" y="{y + 43}" font-family="{FONT}" font-size="25" font-weight="700" fill="#fff">{title}</text>
    <text x="{x + 90}" y="{y + 72}" font-family="{FONT}" font-size="21" font-weight="500" fill="#a1a1a6">{subtitle}</text>"""

    phones = "".join(
        phone(i, jpeg_data_uri(ROOT / "docs/screenshots" / f"{name}.png"), cx, cy, scale, angle, dim)
        for i, (name, cx, cy, scale, angle, dim) in enumerate(HERO_PHONES)
    )
    cards = "".join(card(*c) for c in HERO_CARDS)

    defs = background_defs(height, 0.6) + """
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#FFB45C"/>
      <stop offset="1" stop-color="#F06A00"/>
    </linearGradient>
    <linearGradient id="titanium" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#a3a3a9"/>
      <stop offset="0.22" stop-color="#55555b"/>
      <stop offset="0.5" stop-color="#2c2c31"/>
      <stop offset="0.78" stop-color="#5f5f67"/>
      <stop offset="1" stop-color="#b0b0b6"/>
    </linearGradient>
    <linearGradient id="glare" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.13"/>
      <stop offset="0.32" stop-color="#fff" stop-opacity="0.03"/>
      <stop offset="0.5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="phoneShadow" x="-40%" y="-30%" width="180%" height="160%">
      <feDropShadow dx="0" dy="28" stdDeviation="30" flood-color="#000" flood-opacity="0.7"/>
    </filter>"""
    body = f"""{background(height, HERO_NETWORK)}
    <text x="{WIDTH / 2}" y="152" text-anchor="middle" font-family="{FONT}" font-size="108" font-weight="800" letter-spacing="-3" fill="#fff">Prox<tspan fill="url(#accent)">Fleet</tspan></text>
    <text x="{WIDTH / 2}" y="228" text-anchor="middle" font-family="{FONT}" font-size="40" font-weight="500" fill="#c7c7cc">Your entire Proxmox fleet. In your pocket.</text>
    {phones}
    {cards}"""
    return svg(height, "ProxFleet: Your entire Proxmox fleet. In your pocket.", defs, body)


def tile_icon(glyph: str, x: float, y: float, size: int) -> str:
    """An orange iOS-style icon with a white glyph, as on the feature tiles."""
    scale = size * 0.62 / 24
    offset = (size - 24 * scale) / 2
    return f"""
    <g transform="translate({x} {y})">
      <rect width="{size}" height="{size}" rx="{size * 0.25}" fill="url(#tile)"/>
      <g transform="translate({offset:.2f} {offset:.2f}) scale({scale:.4f})" fill="none" stroke="#fff" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round">{GLYPHS[glyph]}</g>
    </g>"""


TILE_GRADIENT = """
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFA640"/>
      <stop offset="1" stop-color="#E35D00"/>
    </linearGradient>"""


def why() -> str:
    columns, tile_h, gap, margin = len(WHY), 360, 32, 72
    tile_w = (WIDTH - 2 * margin - (columns - 1) * gap) // columns
    height = 2 * margin + TITLE_HEIGHT + tile_h
    icon = 96

    tiles = []
    for i, (glyph, title, lines) in enumerate(WHY):
        x, y = margin + i * (tile_w + gap), margin + TITLE_HEIGHT
        cx = x + tile_w / 2
        text = "".join(
            f'\n    <text x="{cx}" y="{y + 248 + n * 34}" text-anchor="middle" font-family="{FONT}" font-size="25" font-weight="500" fill="#a1a1a6">{line}</text>'
            for n, line in enumerate(lines)
        )
        tiles.append(f"""{glass(x, y, tile_w, tile_h, 30, 0.72)}{tile_icon(glyph, cx - icon / 2, y + 44, icon)}
    <text x="{cx}" y="{y + 198}" text-anchor="middle" font-family="{FONT}" font-size="38" font-weight="700" letter-spacing="-0.5" fill="#fff">{title}</text>{text}""")

    summary = "; ".join(f"{title.lower()}: {' '.join(lines)}" for _, title, lines in WHY)
    body = background(height, CARD_NETWORK) + section_title("Why ProxFleet", margin) + "".join(tiles)
    return svg(height, f"Why ProxFleet: {summary}", background_defs(height, 0.38, 460) + TILE_GRADIENT, body)


def features() -> str:
    columns, tile_w, tile_h, gap, margin = 4, 340, 236, 32, 72
    rows = (len(FEATURES) + columns - 1) // columns
    height = 2 * margin + TITLE_HEIGHT + rows * tile_h + (rows - 1) * gap
    left = (WIDTH - (columns * tile_w + (columns - 1) * gap)) // 2
    icon = 76

    tiles = []
    for i, (glyph, line1, line2) in enumerate(FEATURES):
        x = left + (i % columns) * (tile_w + gap)
        y = margin + TITLE_HEIGHT + (i // columns) * (tile_h + gap)
        tiles.append(f"""{glass(x, y, tile_w, tile_h, 30, 0.72)}{tile_icon(glyph, x + 36, y + 36, icon)}
    <text x="{x + 36}" y="{y + 162}" font-family="{FONT}" font-size="34" font-weight="700" letter-spacing="-0.5" fill="#fff">{line1}</text>
    <text x="{x + 36}" y="{y + 202}" font-family="{FONT}" font-size="34" font-weight="700" letter-spacing="-0.5" fill="#fff">{line2}</text>""")

    names = ", ".join(f"{a} {b}".lower() for _, a, b in FEATURES)
    defs = background_defs(height, 0.4, 520) + TILE_GRADIENT
    body = background(height, CARD_NETWORK) + section_title("Features", margin) + "".join(tiles)
    return svg(height, f"Features: {names}", defs, body)


def roadmap() -> str:
    columns, tile_h, gap, margin = len(ROADMAP), 272, 32, 72
    tile_w = (WIDTH - 2 * margin - (columns - 1) * gap) // columns
    height = 2 * margin + TITLE_HEIGHT + tile_h
    icon = 76
    scale = icon * 0.62 / 24
    offset = (icon - 24 * scale) / 2
    pill_w, pill_h = 104, 40

    tiles = []
    for i, (glyph, title, line1, line2) in enumerate(ROADMAP):
        x, y = margin + i * (tile_w + gap), margin + TITLE_HEIGHT
        tiles.append(f"""{glass(x, y, tile_w, tile_h, 30, 0.5, dashed=True)}
    <g transform="translate({x + 36} {y + 36})">
      <rect x="1.5" y="1.5" width="{icon - 3}" height="{icon - 3}" rx="18" fill="#E57000" fill-opacity="0.1" stroke="#F28A2E" stroke-width="3"/>
      <g transform="translate({offset:.2f} {offset:.2f}) scale({scale:.4f})" fill="none" stroke="#F28A2E" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round">{GLYPHS[glyph]}</g>
    </g>
    <rect x="{x + tile_w - 36 - pill_w}" y="{y + 36 + (icon - pill_h) / 2}" width="{pill_w}" height="{pill_h}" rx="{pill_h / 2}" fill="#E57000" fill-opacity="0.16" stroke="#F28A2E" stroke-opacity="0.6" stroke-width="2"/>
    <text x="{x + tile_w - 36 - pill_w / 2}" y="{y + 36 + icon / 2 + 8}" text-anchor="middle" font-family="{FONT}" font-size="21" font-weight="800" letter-spacing="2.5" fill="#FFA640">SOON</text>
    <text x="{x + 36}" y="{y + 164}" font-family="{FONT}" font-size="34" font-weight="700" letter-spacing="-0.5" fill="#fff" fill-opacity="0.92">{title}</text>
    <text x="{x + 36}" y="{y + 204}" font-family="{FONT}" font-size="25" font-weight="500" fill="#a1a1a6">{line1}</text>
    <text x="{x + 36}" y="{y + 236}" font-family="{FONT}" font-size="25" font-weight="500" fill="#a1a1a6">{line2}</text>""")

    names = ", ".join(title.lower() for _, title, _, _ in ROADMAP)
    body = background(height, CARD_NETWORK) + section_title("Coming next", margin) + "".join(tiles)
    return svg(height, f"Coming soon: {names}", background_defs(height, 0.35, 400), body)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in [("hero.svg", hero), ("why.svg", why), ("features.svg", features), ("roadmap.svg", roadmap)]:
        path = OUT / name
        path.write_text(build())
        print(f"{path.relative_to(ROOT)}: {path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
