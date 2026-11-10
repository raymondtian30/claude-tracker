"""Hand-drawn black cat frames for the desktop pet.

Each animation is a list of 32x36 pictures. `.` is empty. The other letters are
the palette below. Running this file writes the PNGs the app displays, scaled
up with nearest-neighbor so the pixels stay square.
"""

import struct
import zlib
from pathlib import Path

W, H = 32, 36
SCALE = 3

PALETTE = {
    "k": (18, 14, 22, 255),       # outline
    "b": (32, 26, 36, 255),       # fur
    "d": (14, 11, 18, 255),       # shade
    "h": (62, 54, 68, 255),       # highlight, still dark
    "w": (236, 186, 64, 255),     # amber eye
    "p": (16, 12, 18, 255),       # pupil
    "i": (196, 120, 138, 255),    # inner ear
    "n": (232, 156, 172, 255),    # nose
    "m": (186, 178, 170, 255),    # whisker
    "z": (214, 208, 220, 255),    # sleep mark
    "s": (0, 0, 0, 70),           # ground shadow
}


def _rows(text):
    rows = [line for line in text.strip("\n").split("\n")]
    if len(rows) != H:
        raise SystemExit(f"expected {H} rows, got {len(rows)}")
    for index, row in enumerate(rows):
        if len(row) != W:
            raise SystemExit(f"row {index} is {len(row)} wide, expected {W}: {row}")
    return rows


# Side view, facing right. The tail, eye, and paws change per frame.
SIT = _rows("""
................................
................................
................................
................................
................................
.................k....k.........
................kkk..kkk........
...............kiik.kiik........
..............kbbb.kbbbik.......
..............kbbbbbbbbbk.......
.............kbbbbbbbbbbk.......
............kbbbhwbbbbbbk.......
............kbbbhpbbbbbbk.......
............kbbbbbbbbbbnk.......
...........kbbbbbbbbbbbbk.mm..m.
..........bbbbbkbbbbbbbbbbk.....
.......bbbbbbbbbbbbbbbbbbb......
.....hbbbbbbbbbbbbbbbbbbbb......
....bbbbbbbbbbbbbbbbbbbbbb......
...bbbbbbbbbbbbbbbbbbbbbbb......
..bbbbbbbbbbbbbbbbbbbbbbbb......
..bbbbbbbbbbbbbbbbbbbbbbb.......
...bbbbbbbbbbbbbbbbbbbbb........
....bb....bb....bb....bb........
....bb....bb....bb....bb........
...bbbb..bbbb..bbbb..bbbb.......
...ssss..ssss..ssss..ssss.......
................................
................................
................................
................................
................................
................................
................................
................................
................................
""")


def _paint(rows, x, y, picture):
    drawn = [list(row) for row in rows]
    for dy, line in enumerate(picture.strip("\n").split("\n")):
        for dx, pixel in enumerate(line):
            if pixel != ".":
                drawn[y + dy][x + dx] = pixel
    return ["".join(row) for row in drawn]


def _shift(rows, dy):
    blank = ["." * W for _ in range(H)]
    out = [list(row) for row in blank]
    for y, row in enumerate(rows):
        ny = y + dy
        if 0 <= ny < H:
            out[ny] = list(row)
    return ["".join(row) for row in out]


def _replace_region(rows, x, y, picture):
    return _paint(rows, x, y, picture)


TAIL_LOW = """
..k
.b.
b..
.b.
"""

TAIL_MID = """
.k.
b..
.b.
..b
"""

TAIL_UP = """
k..
bk.
.bb
..b
"""


def _with_tail(rows, which):
    # Clear the left edge where tails sit, then stamp one.
    drawn = [list(row) for row in rows]
    for y in range(16, 22):
        for x in range(0, 4):
            drawn[y][x] = "."
    picture = (TAIL_LOW, TAIL_MID, TAIL_UP)[which]
    return _paint(["".join(row) for row in drawn], 0, 16, picture)


CLOSED_EYE = """
kbbbhhbbbbbbk
kbbbbbbbbbbbk
"""

HAPPY_EYE = """
kbb.h.bbbbbbk
kbb.p.bbbbbbk
"""

PAW_UP = """
....bb....bb....bb........
..........................
...bbbb..bbbb..bbbb.......
"""


def _blink(rows):
    return _replace_region(rows, 12, 11, CLOSED_EYE)


def _happy_face(rows):
    drawn = _replace_region(rows, 12, 11, HAPPY_EYE)
    # Chin lifts into a small smile of highlight pixels.
    row = list(drawn[14])
    row[24] = "h"
    row[25] = "h"
    drawn[14] = "".join(row)
    return drawn


def _zzz(rows, step):
    marks = ("z", "z.", "z.z")
    text = marks[step]
    return _paint(rows, 26, 2 + step, text)


def _curl(rows):
    """Tuck the legs and wrap the tail for sleep."""
    drawn = [list(row) for row in rows]
    for y in range(23, 27):
        drawn[y] = list("." * W)
    tucked = list("....bbbbbbbbbbbbbbbbbb..........")
    drawn[22] = list(tucked)
    drawn[23] = list("...bbbbbbbbbbbbbbbbbbbb.........")
    drawn[24] = list("....ssssssssssssssssss..........")
    # Tail wraps over the paws.
    for x, pixel in enumerate("..bbbbb............."):
        if pixel != ".":
            drawn[21][x] = pixel
    return ["".join(row) for row in drawn]


def idle_frames():
    base = _with_tail(SIT, 0)
    mid = _with_tail(SIT, 1)
    up = _with_tail(SIT, 2)
    return [
        base,
        mid,
        up,
        mid,
        _blink(mid),
        _blink(base),
    ]


def walk_frames():
    frames = []
    legs = (
        "....bb....bb....bb....bb........\n....bb....bb....bb....bb........\n...bbbb..bbbb..bbbb..bbbb.......",
        ".....bb....bb....bb....bb.......\n....bb....bb....bb....bb........\n...bbbb..bbbb..bbbb..bbbb.......",
        "....bb....bb....bb....bb........\n...bb....bb....bb....bb.........\n..bbbb..bbbb..bbbb..bbbb........",
        "....bb....bb....bb....bb........\n.....bb....bb....bb....bb.......\n...bbbb..bbbb..bbbb..bbbb.......",
    )
    for index, leg in enumerate(legs):
        body = _with_tail(SIT, index % 3)
        # Drop the sitting paws before stamping the stride.
        drawn = [list(row) for row in body]
        for y in range(23, 27):
            drawn[y] = list("." * W)
        frames.append(_paint(["".join(row) for row in drawn], 0, 23, leg))
    return frames


def happy_frames():
    face = _happy_face(_with_tail(SIT, 2))
    return [
        _shift(face, -2),
        _shift(face, -3),
        _shift(face, -1),
        face,
    ]


def sleep_frames():
    half = _blink(_with_tail(SIT, 0))
    shut = _curl(half)
    return [
        half,
        shut,
        _zzz(shut, 0),
        _zzz(shut, 2),
    ]


def drag_frames():
    lifted = _shift(_with_tail(SIT, 1), -1)
    drawn = [list(row) for row in lifted]
    for y in range(24, 28):
        drawn[y] = list("." * W)
    dangling = _paint(["".join(row) for row in drawn], 0, 24, """
....b.....b.....b.....b.......
....b.....b.....b.....b.......
...bb....bb....bb....bb.......
""")
    swing = _paint(["".join(row) for row in drawn], 0, 25, """
.....b.....b.....b.....b......
.....b.....b.....b.....b......
....bb....bb....bb....bb......
""")
    return [dangling, swing]


SAD_EYE = """
kbbbhhbbbbbbk
kbbbbpbbbbbbk
"""

SAD_SHUT = """
kbbbhhbbbbbbk
kbbbbbbbbbbbk
"""


def sad_frames():
    """Ears stay, the eye drops, then it squints. Same cat, worse mood."""
    base = _with_tail(SIT, 0)
    down = _replace_region(base, 12, 11, SAD_EYE)
    shut = _replace_region(base, 12, 11, SAD_SHUT)
    return [down, shut]


def type_frames():
    base = _with_tail(SIT, 1)
    drawn = [list(row) for row in base]
    for y in range(23, 27):
        drawn[y] = list("." * W)
    down = _paint(
        ["".join(row) for row in drawn],
        0,
        23,
        "....bb....bb....bb....bb........\n....bb....bb....bb....bb........\n...bbbb..bbbb..bbbb..bbbb.......",
    )
    left = _paint(
        ["".join(row) for row in drawn],
        0,
        22,
        "....bb..........................\n....bb....bb....bb....bb........\n....bb....bb....bb....bb........\n...bbbb..bbbb..bbbb..bbbb.......",
    )
    right = _paint(
        ["".join(row) for row in drawn],
        0,
        22,
        "....................bb..........\n....bb....bb....bb....bb........\n....bb....bb....bb....bb........\n...bbbb..bbbb..bbbb..bbbb.......",
    )
    return [down, left, down, right]


ANIMATIONS = {
    "idle": idle_frames,
    "walk": walk_frames,
    "happy": happy_frames,
    "sleep": sleep_frames,
    "drag": drag_frames,
    "type": type_frames,
    "sad": sad_frames,
}


def _png(width, height, rgba):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    return b"".join([
        b"\x89PNG\r\n\x1a\n",
        chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
        chunk(b"IDAT", zlib.compress(raw, 9)),
        chunk(b"IEND", b""),
    ])


def _scale(rows):
    width, height = W * SCALE, H * SCALE
    out = bytearray(width * height * 4)
    for y, row in enumerate(rows):
        for x, pixel in enumerate(row):
            color = PALETTE.get(pixel, (0, 0, 0, 0))
            for sy in range(SCALE):
                for sx in range(SCALE):
                    i = ((y * SCALE + sy) * width + (x * SCALE + sx)) * 4
                    out[i:i + 4] = bytes(color)
    return width, height, bytes(out)


def write_frames(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for name, builder in ANIMATIONS.items():
        for index, rows in enumerate(builder()):
            width, height, rgba = _scale(rows)
            path = directory / f"{name}_{index:02d}.png"
            path.write_bytes(_png(width, height, rgba))
            written.append(path)
    return written


def contact_sheet(destination):
    frames = [rows for builder in ANIMATIONS.values() for rows in builder()]
    tile_w, tile_h = W * SCALE, H * SCALE
    columns = 6
    grid_rows = (len(frames) + columns - 1) // columns
    sheet_w, sheet_h = columns * tile_w, grid_rows * tile_h
    sheet = bytearray(sheet_w * sheet_h * 4)
    for index, rows in enumerate(frames):
        _, _, rgba = _scale(rows)
        ox = (index % columns) * tile_w
        oy = (index // columns) * tile_h
        for y in range(tile_h):
            src = y * tile_w * 4
            dst = ((oy + y) * sheet_w + ox) * 4
            sheet[dst:dst + tile_w * 4] = rgba[src:src + tile_w * 4]
    destination = Path(destination)
    destination.write_bytes(_png(sheet_w, sheet_h, bytes(sheet)))
    return destination


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    write_frames(here)
    sheet = contact_sheet(Path("/tmp/cat-sheet.png"))
    print(f"wrote frames to {here}")
    print(sheet)
