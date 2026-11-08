"""The panel's open/close animation speeds, kept free of AppKit so the
Settings tab (stats_tabs.py) can list them.

Each is (key, label, seconds). The panel unfolds down from the menu bar when
it opens and folds back up when it closes.
"""

ANIMATION_SPEEDS = [("off", "Off", 0.0), ("fast", "Fast", 0.12),
                    ("normal", "Normal", 0.22), ("slow", "Slow", 0.4)]
DEFAULT_ANIMATION = "normal"

# Light or dark look for the panel and Settings; "auto" follows macOS.
APPEARANCES = [("auto", "Auto"), ("light", "Light"), ("dark", "Dark")]
DEFAULT_APPEARANCE = "auto"


def animation_seconds(key):
    return dict((k, s) for k, _, s in ANIMATION_SPEEDS).get(key, 0.22)
