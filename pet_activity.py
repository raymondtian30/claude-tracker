"""What the cat is allowed to notice.

Typing and delete are pulses only: a key is either "typing" or "delete".
The key itself is never stored, logged, or shown. Music and video are the
player name or a short label, checked every few seconds.
"""

import ctypes
import subprocess
import threading
import time

IGNORE_CODES = set(range(54, 64)) | {48, 53, 123, 124, 125, 126}
DELETE_CODES = {51, 117}

BROWSERS = {
    "Safari", "Google Chrome", "Chromium", "Firefox", "Arc",
    "Brave Browser", "Microsoft Edge", "Orion",
}
PLAYERS = {"VLC", "IINA", "TV", "QuickTime Player", "Netflix", "Infuse", "Plex"}

MUSIC_SCRIPT = r'''
if application "Spotify" is running then
  tell application "Spotify"
    if player state is playing then
      return "playing" & linefeed & name of current track & linefeed & artist of current track
    end if
  end tell
end if
if application "Music" is running then
  tell application "Music"
    if player state is playing then
      return "playing" & linefeed & name of current track & linefeed & artist of current track
    end if
  end tell
end if
return "stopped"
'''

VIDEO_SCRIPT = r'''
tell application "System Events"
  set front_app to first application process whose frontmost is true
  set app_name to name of front_app
  set window_name to ""
  try
    set window_name to name of front window of front_app
  end try
  return app_name & linefeed & window_name
end tell
'''


def parse_player(text):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    if not lines or lines[0] != "playing":
        return False, ""
    title = lines[1] if len(lines) > 1 else ""
    artist = lines[2] if len(lines) > 2 else ""
    if title and artist:
        return True, f"{title} — {artist}"
    return True, title


def parse_video(app_name, window_title):
    """Reduce a front app to a yes/no. The raw window title is not kept."""
    name = (app_name or "").strip()
    if name in PLAYERS:
        return True, name
    if name in BROWSERS:
        title = (window_title or "").lower()
        if "youtube" in title:
            return True, "YouTube"
        if "netflix" in title:
            return True, "Netflix"
    return False, ""


class PulseCounter:
    """Turns key pulses into 'typing', 'paused', or 'deleting'. No key codes."""

    def __init__(self):
        self._types = []
        self._deletes = []
        self.typing = False
        self._cooldown_until = 0.0
        self._burst_until = 0.0
        self._last_delete = 0.0
        self._session_started = None

    def push_typing(self, now):
        self._types.append(now)

    def push_delete(self, now):
        if now - self._last_delete < 0.12:
            return
        self._last_delete = now
        self._deletes.append(now)

    def snapshot(self, now):
        from pet_logic import Activity

        self._types = [stamp for stamp in self._types if now - stamp <= 8.0]
        self._deletes = [stamp for stamp in self._deletes if now - stamp <= 3.0]
        long_pause = False
        if self.typing and (not self._types or now - self._types[-1] > 1.8):
            self.typing = False
            self._cooldown_until = now + 1.5
            if self._session_started is not None and now - self._session_started >= 8.0:
                long_pause = True
            self._session_started = None
        recent = [stamp for stamp in self._types if now - stamp <= 0.35]
        if not self.typing and now >= self._cooldown_until and len(recent) >= 2:
            self.typing = True
            self._session_started = recent[0]
        span_keys = [stamp for stamp in self._types if now - stamp <= 2.0]
        if len(span_keys) >= 2 and span_keys[-1] > span_keys[0]:
            cps = (len(span_keys) - 1) / (span_keys[-1] - span_keys[0])
        else:
            cps = 0.0
        fresh = [stamp for stamp in self._deletes if stamp > now - 0.2]
        # Deliver each delete once. snapshot is called often; 0.2s covers one tick.
        delete = None
        if fresh and fresh[-1] != getattr(self, "_delivered_delete", None):
            self._delivered_delete = fresh[-1]
            burst = [stamp for stamp in self._deletes if now - stamp <= 3.0]
            if len(burst) >= 5 and now >= self._burst_until:
                delete = "burst"
                self._burst_until = now + 18.0
            else:
                delete = "tap"
        return Activity(
            typing=self.typing,
            cps=cps if self.typing else 0.0,
            delete=delete,
            long_pause=long_pause,
        )


def _run_osascript(script):
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout


class Senses:
    """Live pulses and media. Safe to snapshot from the UI timer."""

    def __init__(self, run_script=_run_osascript):
        self.pulses = PulseCounter()
        self.typing_enabled = True
        self.deleting_enabled = True
        self.media_enabled = True
        self._run_script = run_script
        self._music = (False, "")
        self._video = (False, "")
        self._lock = threading.Lock()
        self._tap = None
        self._media_thread = None
        self._stop = False
        self.keyboard_ready = None  # None unknown, True tapping, False no permission

    def snapshot(self, now):
        activity = self.pulses.snapshot(now)
        if not self.typing_enabled:
            activity.typing = False
            activity.cps = 0.0
            activity.long_pause = False
        if not self.deleting_enabled:
            activity.delete = None
        if self.media_enabled:
            with self._lock:
                activity.music, activity.track = self._music
                activity.video, activity.video_label = self._video
        return activity

    def start(self):
        self._stop = False
        if self._media_thread is None:
            self._media_thread = threading.Thread(target=self._media_loop, daemon=True)
            self._media_thread.start()
        if self.typing_enabled or self.deleting_enabled:
            self._start_tap()

    def stop(self):
        self._stop = True
        self._stop_tap()

    def _media_loop(self):
        while not self._stop:
            if self.media_enabled:
                music = parse_player(self._run_script(MUSIC_SCRIPT))
                video_text = self._run_script(VIDEO_SCRIPT)
                lines = [line.strip() for line in video_text.splitlines()]
                app_name = lines[0] if lines else ""
                title = lines[1] if len(lines) > 1 else ""
                video = parse_video(app_name, title)
                with self._lock:
                    self._music = music
                    self._video = video
            else:
                with self._lock:
                    self._music = (False, "")
                    self._video = (False, "")
            for _ in range(12):
                if self._stop:
                    return
                time.sleep(1)

    def _start_tap(self):
        if self._tap is not None:
            return
        tap = KeyboardTap(self.pulses)
        if tap.start():
            self._tap = tap
            self.keyboard_ready = True
        else:
            self.keyboard_ready = False

    def _stop_tap(self):
        if self._tap is not None:
            self._tap.stop()
            self._tap = None


class KeyboardTap:
    """Listen-only. Writes nothing. Classifies a key as typing or delete."""

    def __init__(self, pulses):
        self.pulses = pulses
        self._port = None
        self._callback = None

    def start(self):
        try:
            app_services = ctypes.CDLL(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
            )
            app_services.AXIsProcessTrusted.restype = ctypes.c_bool
            if not app_services.AXIsProcessTrusted():
                return False
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            callback_type = ctypes.CFUNCTYPE(
                ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p
            )

            def _on_key(proxy, event_type, event, refcon):
                if event_type in (0xFFFFFFFE, 0xFFFFFFFF):
                    if self._port:
                        cg.CGEventTapEnable(self._port, True)
                    return event
                if event_type != 10 or not event:
                    return event
                code = cg.CGEventGetIntegerValueField(event, 9)
                if code in IGNORE_CODES:
                    return event
                now = time.time()
                if code in DELETE_CODES:
                    self.pulses.push_delete(now)
                else:
                    self.pulses.push_typing(now)
                return event

            self._callback = callback_type(_on_key)
            cg.CGEventTapCreate.restype = ctypes.c_void_p
            cg.CGEventTapCreate.argtypes = [
                ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint64,
                callback_type, ctypes.c_void_p,
            ]
            cg.CGEventGetIntegerValueField.restype = ctypes.c_int64
            cg.CGEventGetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            cg.CGEventTapEnable.argtypes = [ctypes.c_void_p, ctypes.c_bool]
            port = cg.CGEventTapCreate(1, 0, 1, 1 << 10, self._callback, None)
            if not port:
                return False
            self._port = port
            cf.CFMachPortCreateRunLoopSource.restype = ctypes.c_void_p
            cf.CFMachPortCreateRunLoopSource.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
            cf.CFRunLoopGetMain.restype = ctypes.c_void_p
            cf.CFRunLoopAddSource.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
            source = cf.CFMachPortCreateRunLoopSource(None, port, 0)
            modes = ctypes.c_void_p.in_dll(cf, "kCFRunLoopCommonModes")
            cf.CFRunLoopAddSource(cf.CFRunLoopGetMain(), source, modes)
            cg.CGEventTapEnable(port, True)
            return True
        except Exception:
            return False

    def stop(self):
        port = self._port
        self._port = None
        if not port:
            return
        try:
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cg.CGEventTapEnable.argtypes = [ctypes.c_void_p, ctypes.c_bool]
            cg.CGEventTapEnable(port, False)
        except Exception:
            return
