"""The Sheafs mark: three tilted sheets, the top one with text lines and a drop cap.

ONE drawing, in its own units (y down, origin at the centre of the top sheet), shared by
`scripts/gen-symbol` (the control's mono SF Symbol) and `scripts/gen-icon` (the app icon and the
site's icons), so the two cannot drift apart; `scripts/check-icon` reads the icon's pixels back
against this geometry. Plain Python, no dependencies: the check runs wherever python3 is.
"""
import math

W, H, R = 56.0, 74.0, 6.0          # sheet size and corner radius
GAP = 4.2                          # the symbol's knockout gap between sheets
LINE, PITCH = 4.8, 10.5            # text line thickness and pitch
RING = 2.8                         # the symbol's drop cap: a square hole with a smaller square inside
MARGIN = 7.0                       # inside the sheet
SHEETS = [                         # (rotation deg, dx, dy), back to front
    (0.0, -17.0, 15.0),
    (-5.0, -8.5, 7.5),
    (-11.0, 0.0, 0.0),
]
TOP = len(SHEETS) - 1


def text_layout():
    """The top sheet's drop-cap square and text lines, as (x0, y0, x1, y1) boxes in the sheet's
    own frame. The square spans lines 1–2; lines 1–2 start after it, lines 4 and 6 stop short."""
    x0, x1 = -W / 2 + MARGIN, W / 2 - MARGIN
    y0 = -H / 2 + MARGIN + LINE / 2
    n = int((H - 2 * MARGIN - LINE) // PITCH) + 1
    square = 2 * PITCH - (PITCH - LINE)
    cap = (x0, y0 - LINE / 2, x0 + square, y0 - LINE / 2 + square)
    lines = []
    for i in range(n):
        y = y0 + i * PITCH
        start = x0 + square + 4.0 if i < 2 else x0
        end = x1 - 10.0 if i in (3, 5) else x1
        lines.append((start, y - LINE / 2, end, y + LINE / 2))
    return cap, lines


def place(point, sheet):
    """A point of a sheet's frame → the drawing's frame (rotate about the sheet's centre, then
    move it; the same matrix as shapely's `rotate` and SVG's `rotate`)."""
    rot, dx, dy = SHEETS[sheet]
    a = math.radians(rot)
    x, y = point
    return (x * math.cos(a) - y * math.sin(a) + dx, x * math.sin(a) + y * math.cos(a) + dy)


def bounds():
    """The exact bounds (minx, miny, maxx, maxy) of the three rounded sheets together."""
    minx = miny = math.inf
    maxx = maxy = -math.inf
    for rot, dx, dy in SHEETS:
        a = math.radians(rot)
        ex = (W / 2 - R) * abs(math.cos(a)) + (H / 2 - R) * abs(math.sin(a)) + R
        ey = (W / 2 - R) * abs(math.sin(a)) + (H / 2 - R) * abs(math.cos(a)) + R
        minx, maxx = min(minx, dx - ex), max(maxx, dx + ex)
        miny, maxy = min(miny, dy - ey), max(maxy, dy + ey)
    return minx, miny, maxx, maxy


def centre():
    minx, miny, maxx, maxy = bounds()
    return (minx + maxx) / 2, (miny + maxy) / 2
