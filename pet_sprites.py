"""Where the cat's frames live. Drawn by assets/pet/draw_cat.py."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent / "assets" / "pet"

# Pixel size of one frame after nearest-neighbor scale (32×36 at 3×).
CAT_W = 96
CAT_H = 108
# Extra room above the cat so a short line can sit over its head.
HEADROOM = 72
WINDOW_W = 240
WINDOW_H = CAT_H + HEADROOM

FRAME_COUNTS = {
    "idle": 6,
    "walk": 4,
    "happy": 4,
    "sleep": 4,
    "drag": 2,
    "type": 4,
    "sad": 2,
}


def frame_path(name, index):
    return ROOT / f"{name}_{index:02d}.png"
