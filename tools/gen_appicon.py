#!/usr/bin/env python3
"""TripperDash++ App Store icon — SVG (vector) -> PNG via cairosvg.

Royal Enfield winged-badge DNA, modernised & flat:
  - circular badge, charcoal field, amber double ring, arc lettering
  - the WINGED emblem: two real swept wings (layered curved feathers)
  - centre: a navigation cursor on an RE-red disc
Vector curves give smooth feathers PIL polygons can't.

Output: 1024x1024, opaque sRGB, no alpha.
"""
import math
import cairosvg

S = 1024
C = S / 2

YEL    = "#F5B820"
YEL_HI = "#FFD75E"
YEL_LO = "#C68C0E"
RED    = "#D43620"
RED_HI = "#E8593A"
INK    = "#16171A"
CHAR_T = "#282B30"
CHAR_B = "#0D0E10"
CREAM  = "#F8F3E2"

EMX, EMY = C, C - 4  # emblem centre


def wing(side):
    """Return SVG for one swept wing made of 3 curved feathers + a root.
    side = +1 (right) or -1 (left). Built on the right then mirrored."""
    s = side
    g = []
    # root block fused to the disc
    g.append(
        f'<path d="M {EMX+ s*30:.1f} {EMY-64:.1f} '
        f'Q {EMX+ s*86:.1f} {EMY-70:.1f} {EMX+ s*96:.1f} {EMY-18:.1f} '
        f'L {EMX+ s*96:.1f} {EMY+30:.1f} '
        f'Q {EMX+ s*86:.1f} {EMY+78:.1f} {EMX+ s*30:.1f} {EMY+70:.1f} Z" '
        f'fill="{YEL}"/>'
    )
    # feathers: (root_y, tip_x_off, tip_y_off, width, curve)
    feathers = [
        (-58, 250, -40, 64,  60),   # top, longest, sweeps up
        (-6,  236,   2, 70,  40),   # middle
        ( 44, 196,  44, 60,  20),   # bottom, sweeps down
    ]
    for (ry, tx, ty, w, cv) in feathers:
        rx = EMX + s * 84
        ry_ = EMY + ry
        tipx = EMX + s * tx
        tipy = EMY + ty
        # upper edge (root -> tip) bowed outward, lower edge (tip -> root) bowed in
        c1x = EMX + s * (tx * 0.45)
        c1y = ry_ - cv
        c2x = EMX + s * (tx * 0.80)
        c2y = tipy - cv * 0.4
        b1x = EMX + s * (tx * 0.78)
        b1y = tipy + w * 0.5
        b2x = EMX + s * (tx * 0.40)
        b2y = ry_ + w * 0.9
        g.append(
            f'<path d="M {rx:.1f} {ry_:.1f} '
            f'C {c1x:.1f} {c1y:.1f} {c2x:.1f} {c2y:.1f} {tipx:.1f} {tipy:.1f} '
            f'C {b1x:.1f} {b1y:.1f} {b2x:.1f} {b2y:.1f} {rx:.1f} {ry_ + w*0.55:.1f} Z" '
            f'fill="{YEL}" stroke="{YEL_LO}" stroke-width="4"/>'
        )
    return "\n".join(g)


# nav cursor centred on the emblem
def cursor(scale, fill, dy=0):
    p = [(EMX, EMY - 118*scale + dy), (EMX + 76*scale, EMY + 94*scale + dy),
         (EMX, EMY + 52*scale + dy), (EMX - 76*scale, EMY + 94*scale + dy)]
    d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in p) + " Z"
    return f'<path d="{d}" fill="{fill}"/>'


def star(x, y, ro, ri, fill, rot=-90):
    pts = []
    for i in range(10):
        r = ro if i % 2 == 0 else ri
        a = math.radians(rot + i * 36)
        pts.append(f"{x + r*math.cos(a):.1f},{y + r*math.sin(a):.1f}")
    return f'<polygon points="{" ".join(pts)}" fill="{fill}"/>'


svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <radialGradient id="field" cx="50%" cy="42%" r="62%">
      <stop offset="0%" stop-color="{CHAR_T}"/>
      <stop offset="100%" stop-color="{CHAR_B}"/>
    </radialGradient>
    <radialGradient id="disc" cx="50%" cy="38%" r="65%">
      <stop offset="0%" stop-color="{RED_HI}"/>
      <stop offset="100%" stop-color="{RED}"/>
    </radialGradient>
    <linearGradient id="ringg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{YEL_HI}"/>
      <stop offset="100%" stop-color="{YEL_LO}"/>
    </linearGradient>
    <path id="arcTop" d="M {C-359} {C} A 359 359 0 0 1 {C+359} {C}" fill="none"/>
    <path id="arcBot" d="M {C-411} {C} A 411 411 0 0 0 {C+411} {C}" fill="none"/>
  </defs>

  <!-- field -->
  <rect width="{S}" height="{S}" fill="url(#field)"/>

  <!-- rings -->
  <circle cx="{C}" cy="{C}" r="498" fill="none" stroke="{INK}" stroke-width="10"/>
  <circle cx="{C}" cy="{C}" r="486" fill="none" stroke="url(#ringg)" stroke-width="30"/>
  <circle cx="{C}" cy="{C}" r="452" fill="none" stroke="{INK}" stroke-width="6"/>
  <circle cx="{C}" cy="{C}" r="320" fill="none" stroke="{YEL_LO}" stroke-width="5"/>

  <!-- arc lettering (centred in the wide ring band, between r=452 and r=320) -->
  <text font-family="DejaVu Sans" font-weight="bold" font-size="74"
        fill="{YEL}" letter-spacing="4" text-anchor="middle">
    <textPath href="#arcTop" startOffset="50%">TRIPPERDASH</textPath>
  </text>
  <text font-family="DejaVu Sans" font-weight="bold" font-size="68"
        fill="{CREAM}" letter-spacing="6" text-anchor="middle">
    <textPath href="#arcBot" startOffset="50%">NAVIGATION</textPath>
  </text>

  {star(C-386, C, 18, 7, YEL_HI)}
  {star(C+386, C, 18, 7, YEL_HI)}

  <!-- wings (behind disc) -->
  {wing(+1)}
  {wing(-1)}

  <!-- red emblem disc -->
  <circle cx="{EMX}" cy="{EMY}" r="150" fill="url(#disc)" stroke="{YEL}" stroke-width="9"/>
  <ellipse cx="{EMX}" cy="{EMY-58}" rx="120" ry="58" fill="#FFFFFF" opacity="0.10"/>

  <!-- nav cursor -->
  {cursor(1.05, INK)}
  {cursor(0.92, YEL)}
  <path d="M {EMX} {EMY-104} L {EMX-62} {EMY+78}" stroke="{YEL_HI}" stroke-width="7" fill="none"/>
</svg>'''

with open("/tmp/appicon.svg", "w") as f:
    f.write(svg)

# render to PNG on a black background (then it's opaque, no alpha)
cairosvg.svg2png(bytestring=svg.encode(), write_to="/tmp/appicon_raw.png",
                 output_width=S, output_height=S, background_color="#0D0E10")

# flatten to guaranteed-opaque RGB
from PIL import Image
im = Image.open("/tmp/appicon_raw.png").convert("RGB")
out = "/root/TripperDashPlusPlus/TripperDashPP/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
im.save(out, "PNG")
print("wrote", out, im.size, im.mode)
