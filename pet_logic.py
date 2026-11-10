"""Desktop pet behavior, matched to Byte's pet and not its calendar or assistant.

The cat is clicked, dragged, and left alone. It wanders to a screen edge, hops
when it feels like it, sleeps after several quiet minutes, and reacts to
typing, deleting, music, and video. A live Claude session counts as the person
still being here, so the cat stays awake while one is open.
"""

import math
import random

IDLE = "idle"
WALKING = "walking"
TYPING = "typing"
WATCHING = "watching"
HAPPY = "happy"
SAD = "sad"
SLEEPING = "sleeping"
DRAGGING = "dragging"

PRIORITY = {
    DRAGGING: 100,
    HAPPY: 80,
    SAD: 60,
    SLEEPING: 50,
    TYPING: 45,
    WATCHING: 43,
    WALKING: 40,
    IDLE: 0,
}

HAPPY_SECONDS = 1.2
SAD_SECONDS = 2.2
SAD_STRONG = 1.35
WANDER_MIN = 30.0
WANDER_MAX = 60.0
AMBIENT_MIN = 8.0
AMBIENT_MAX = 15.0
MUSIC_HAPPY_MIN = 4.5
MUSIC_HAPPY_MAX = 9.0
SLEEP_MIN = 360.0
SLEEP_MAX = 480.0
WANDER_SPEED = 4.5
DRAG_SPEED = 16.0
TYPE_SPEED = 2.6
ARRIVE = 3.0
TYPE_ARRIVE = 14.0
EDGE_INSET = 40
DRAG_FLIP = 10.0
REANCHOR = 300.0
BUBBLE_SECONDS = 5.0
TRACK_COOLDOWN = 55.0
VIDEO_COOLDOWN = 50.0

DELETE_LINES = (
    "That one didn't stick.",
    "Backspace. Noted.",
    "Gone. Probably for the best.",
)
BURST_LINES = (
    "That's a lot of undoing.",
    "Easy. The page will still be there.",
)
PAUSE_LINE = "Still there?"
VIDEO_LINE = "I'll keep quiet."


def _lerp(current, target, speed, dt):
    t = 1.0 - math.exp(-speed * dt)
    return current + (target - current) * t


def _clamp(value, low, high):
    return min(max(value, low), high)


def typing_anim_scale(cps):
    """Byte maps key speed to how fast the paws move. 1/s is slow, 8/s is fast."""
    cps = max(0.0, cps)
    if cps <= 1.0:
        return 0.6
    if cps >= 8.0:
        return 2.4
    if cps <= 4.0:
        return 0.6 + (cps - 1.0) / 3.0 * 0.4
    return 1.0 + (cps - 4.0) / 4.0 * 1.4


class Activity:
    """One moment of the world around the cat. One-shot flags are already consumed."""

    def __init__(self, typing=False, cps=0.0, delete=None, music=False, track="",
                 video=False, video_label="", long_pause=False):
        self.typing = typing
        self.cps = cps
        self.delete = delete  # None, "tap", or "burst"
        self.music = music
        self.track = track or ""
        self.video = video
        self.video_label = video_label or ""
        self.long_pause = long_pause


class PetMind:
    def __init__(self, now, rng=None, window_size=(240, 180)):
        self.rng = rng or random.Random()
        self.window_size = window_size
        self.state = IDLE
        self.x = 0.0
        self.y = 0.0
        self.facing = 1
        self.tilt = 0.0
        self.bob = 0.0
        self.breath = 0.0
        self.stretch = 1.0
        self.anim_speed = 1.0
        self.walked = 0.0
        self.bubble = ""
        self.bubble_until = 0.0
        self.session_active = False
        self.music = False
        self.pointer = False
        self.moved = False
        self.over_pet = False
        self.phase_started = now
        self.happy_left = 0.0
        self.sad_left = 0.0
        self.walk_target = None
        self.type_spot = None
        self.type_locked = False
        self.goal = (0.0, 0.0)
        self.grab = (0.0, 0.0)
        self._velocity = (0.0, 0.0)
        self._drag_phase = 0.0
        self._breath_phase = self.rng.random() * math.tau
        self._track_shown = ""
        self._track_until = 0.0
        self._video_shown = False
        self._video_until = 0.0
        self._greeted_session = False
        self._schedule(now)

    def place(self, x, y):
        self.x = float(x)
        self.y = float(y)
        self.goal = (self.x, self.y)

    def _schedule(self, now):
        self.wander_in = self.rng.uniform(WANDER_MIN, WANDER_MAX)
        self.sleep_at = now + self.rng.uniform(SLEEP_MIN, SLEEP_MAX)
        self._schedule_ambient()

    def _schedule_ambient(self):
        if self.music:
            self.ambient_in = self.rng.uniform(MUSIC_HAPPY_MIN, MUSIC_HAPPY_MAX)
        else:
            self.ambient_in = self.rng.uniform(AMBIENT_MIN, AMBIENT_MAX)

    def _note(self, now):
        self.sleep_at = now + self.rng.uniform(SLEEP_MIN, SLEEP_MAX)

    def _to(self, nxt, now, force=False):
        if nxt == self.state:
            return True
        if not force and PRIORITY[nxt] < PRIORITY[self.state]:
            return False
        self.state = nxt
        self.phase_started = now
        self.anim_speed = 1.0
        return True

    def _say(self, now, text, seconds=BUBBLE_SECONDS):
        self.bubble = text
        self.bubble_until = now + seconds

    def _trigger_happy(self, now):
        if not self._to(HAPPY, now, force=True):
            return
        self.happy_left = HAPPY_SECONDS
        self.sad_left = 0.0
        self.walk_target = None
        self.type_locked = False
        self._note(now)
        self._schedule_ambient()

    def _trigger_sad(self, now, strong=False):
        if self.state == DRAGGING or self.pointer:
            return
        if self.state == TYPING:
            return
        if not self._to(SAD, now, force=True):
            return
        self.sad_left = SAD_SECONDS * (SAD_STRONG if strong else 1.0)
        self.happy_left = 0.0
        self.walk_target = None
        self.type_locked = False
        self._note(now)

    def hover(self, over, now):
        self.over_pet = over
        if not over:
            return
        self._note(now)
        if self.state == SLEEPING:
            self._to(IDLE, now, force=True)

    def pointer_down(self, now, mouse_x, mouse_y):
        self.pointer = True
        self.moved = False
        self.grab = (self.x - mouse_x, self.y - mouse_y)
        self.goal = (self.x, self.y)
        self._note(now)

    def pointer_drag(self, now, mouse_x, mouse_y):
        goal = (mouse_x + self.grab[0], mouse_y + self.grab[1] - 12.0)
        if abs(goal[0] - self.x) + abs(goal[1] - self.y) > 4.0:
            self.moved = True
            self._to(DRAGGING, now, force=True)
            self.walk_target = None
            self.type_locked = False
        self.goal = goal

    def pointer_up(self, now):
        self.pointer = False
        if self.moved or self.state == DRAGGING:
            self._to(IDLE, now, force=True)
            self._note(now)
            self._schedule_ambient()
            self.wander_in = self.rng.uniform(WANDER_MIN, WANDER_MAX)
            self.moved = False
            return "moved"
        self._trigger_happy(now)
        return "click"

    def note_session(self, active, now):
        started = active and not self.session_active
        self.session_active = bool(active)
        if not active:
            self._greeted_session = False
            return
        self._note(now)
        if self.state == SLEEPING:
            self._to(IDLE, now, force=True)
        if started and not self._greeted_session and self.state == IDLE:
            self._greeted_session = True
            self._trigger_happy(now)

    def tick(self, now, dt, bounds, mouse, activity):
        dt = min(max(dt, 0.0), 0.05)
        if now >= self.bubble_until:
            self.bubble = ""
        was_music = self.music
        self._apply_activity(now, activity or Activity(), mouse, bounds)
        if self.music and not was_music:
            self.ambient_in = self.rng.uniform(MUSIC_HAPPY_MIN, MUSIC_HAPPY_MAX)
        self._tick_timers(now, dt, bounds)
        self._tick_motion(now, dt, bounds)
        self._tick_visuals(now, dt, mouse)

    def _apply_activity(self, now, activity, mouse, bounds):
        self.music = bool(activity.music)
        if activity.long_pause and self.state == TYPING:
            self._say(now, PAUSE_LINE)
        if activity.delete and self.state not in (DRAGGING, TYPING, SLEEPING) and not self.pointer:
            strong = activity.delete == "burst"
            self._trigger_sad(now, strong)
            lines = BURST_LINES if strong else DELETE_LINES
            self._say(now, self.rng.choice(lines))
        if activity.music and activity.track and activity.track != self._track_shown and now >= self._track_until:
            self._track_shown = activity.track
            self._track_until = now + TRACK_COOLDOWN
            self._say(now, "♪ " + activity.track)
            if self.state in (IDLE, WATCHING):
                self._trigger_happy(now)
        if not activity.music:
            self._track_shown = ""
        if activity.video and self.state not in (DRAGGING, HAPPY, SAD, TYPING, SLEEPING):
            if self._to(WATCHING, now, force=self.state in (IDLE, WALKING)):
                self.walk_target = None
            if not self._video_shown and now >= self._video_until:
                self._video_shown = True
                self._video_until = now + VIDEO_COOLDOWN
                label = activity.video_label or "something"
                self._say(now, f"{label}. {VIDEO_LINE}")
        if not activity.video:
            self._video_shown = False
            if self.state == WATCHING:
                self._to(IDLE, now, force=True)
        if activity.typing and not self.pointer and self.state not in (DRAGGING, HAPPY, SAD, SLEEPING):
            was_typing = self.state == TYPING
            if self.state == WATCHING:
                self._to(IDLE, now, force=True)
            if self._to(TYPING, now, force=True):
                self.walk_target = None
                if not was_typing and not self.type_locked:
                    self.type_spot = self._spot_near(mouse, bounds)
                elif self.type_locked and mouse is not None:
                    cx, cy = self._center()
                    if math.hypot(mouse[0] - cx, mouse[1] - cy) > REANCHOR:
                        self.type_locked = False
                        self.type_spot = self._spot_near(mouse, bounds)
            self.anim_speed = typing_anim_scale(activity.cps)
            self._note(now)
        elif self.state == TYPING and not activity.typing:
            self.type_locked = False
            self.type_spot = None
            self.wander_in = self.rng.uniform(WANDER_MIN, WANDER_MAX)
            if activity.video:
                self._to(WATCHING, now, force=True)
            else:
                self._to(IDLE, now, force=True)

    def _spot_near(self, mouse, bounds):
        if mouse is None:
            return self.x, self.y
        jx = self.rng.uniform(-16, 16)
        jy = self.rng.uniform(-16, 16)
        return self._clamp_point(mouse[0] + 128 + jx, mouse[1] + 88 + jy, bounds)

    def _tick_timers(self, now, dt, bounds):
        if self.state == HAPPY:
            self.happy_left -= dt
            if self.happy_left <= 0:
                self._to(IDLE, now, force=True)
            return
        if self.state == SAD:
            self.sad_left -= dt
            if self.sad_left <= 0:
                self._to(IDLE, now, force=True)
            return
        if self.state in (DRAGGING, TYPING, SLEEPING):
            return
        if self.state in (IDLE, WATCHING):
            self.ambient_in -= dt
            if self.ambient_in <= 0:
                self._trigger_happy(now)
                return
        if (
            self.state == IDLE
            and not self.pointer
            and not self.over_pet
            and self.sleep_at <= now
            and not self.session_active
        ):
            self._to(SLEEPING, now)
            self.walk_target = None
            return
        if self.state == IDLE and not self.pointer and self.wander_in <= 0:
            self._start_wander(now, bounds)
        elif self.state == IDLE:
            self.wander_in -= dt

    def _start_wander(self, now, bounds):
        target = self._edge_target(bounds)
        if target is None or math.hypot(target[0] - self.x, target[1] - self.y) < ARRIVE:
            self.wander_in = self.rng.uniform(WANDER_MIN, WANDER_MAX)
            return
        self.walk_target = target
        self.facing = 1 if target[0] >= self.x else -1
        self._to(WALKING, now)

    def _edge_target(self, bounds):
        min_x, min_y, max_x, max_y = bounds
        left = min_x + EDGE_INSET
        right = max_x - EDGE_INSET
        bottom = min_y + EDGE_INSET
        top = max_y - EDGE_INSET
        if right <= left or top <= bottom:
            return None
        side = self.rng.randrange(4)
        if side == 0:
            return self.rng.uniform(left, right), bottom
        if side == 1:
            return self.rng.uniform(left, right), top
        if side == 2:
            return left, self.rng.uniform(bottom, top)
        return right, self.rng.uniform(bottom, top)

    def _tick_motion(self, now, dt, bounds):
        previous = (self.x, self.y)
        if self.state == DRAGGING:
            self.x = _lerp(self.x, self.goal[0], DRAG_SPEED, dt)
            self.y = _lerp(self.y, self.goal[1], DRAG_SPEED, dt)
        elif self.state == WALKING and self.walk_target is not None:
            self.x = _lerp(self.x, self.walk_target[0], WANDER_SPEED, dt)
            self.y = _lerp(self.y, self.walk_target[1], WANDER_SPEED, dt)
            self.facing = 1 if self.walk_target[0] >= self.x else -1
            if math.hypot(self.walk_target[0] - self.x, self.walk_target[1] - self.y) <= ARRIVE:
                self.x, self.y = self.walk_target
                self.walk_target = None
                self._to(IDLE, now, force=True)
                self.wander_in = self.rng.uniform(WANDER_MIN, WANDER_MAX)
        elif self.state == TYPING and self.type_spot is not None and not self.type_locked:
            self.x = _lerp(self.x, self.type_spot[0], TYPE_SPEED, dt)
            self.y = _lerp(self.y, self.type_spot[1], TYPE_SPEED, dt)
            self.facing = 1 if self.type_spot[0] >= self.x else -1
            if math.hypot(self.type_spot[0] - self.x, self.type_spot[1] - self.y) <= TYPE_ARRIVE:
                self.type_locked = True
        self.x, self.y = self._clamp_point(self.x, self.y, bounds)
        if dt > 0:
            self._velocity = ((self.x - previous[0]) / dt, (self.y - previous[1]) / dt)
            self.walked += math.hypot(self.x - previous[0], self.y - previous[1])

    def _clamp_point(self, x, y, bounds):
        min_x, min_y, max_x, max_y = bounds
        return _clamp(x, min_x, max_x), _clamp(y, min_y, max_y)

    def _center(self):
        return self.x + self.window_size[0] / 2.0, self.y + self.window_size[1] / 2.0

    def _tick_visuals(self, now, dt, mouse):
        self.breath = 0.0
        self.bob = 0.0
        speed = math.hypot(*self._velocity)
        if self.state == DRAGGING:
            self._drag_phase += dt * 9.0
            self.bob = math.sin(self._drag_phase) * 5.0
            if abs(self._velocity[0]) >= DRAG_FLIP:
                self.facing = -1 if self._velocity[0] < 0 else 1
            speed_t = _clamp((speed - 70.0) / (260.0 - 70.0), 0.0, 1.0)
            self.anim_speed = 0.8 + speed_t * 0.6
            self.stretch = 1.0 + speed_t * 0.06
            horiz = _clamp(self._velocity[0] * 0.06, -25.0, 25.0)
            bonus = speed_t * 25.0 * 0.35 * (1 if self._velocity[0] >= 0 else -1)
            target = _clamp(horiz + bonus, -25.0, 25.0)
            self.tilt = _lerp(self.tilt, target, 12.0, dt)
            return
        self.stretch = 1.0
        if self.state == WATCHING:
            self.anim_speed = 0.55
            self.tilt = 12.0 if self.facing > 0 else -12.0
        elif self.state == IDLE and mouse is not None:
            dx = mouse[0] - self._center()[0]
            if self.facing < 0:
                dx = -dx
            look = _clamp(dx / 320.0, -1.0, 1.0)
            self.tilt = _lerp(self.tilt, look * 6.0, 6.0, dt)
            self._breath_phase += dt * math.tau / 3.4
            self.breath = math.sin(self._breath_phase) * 1.5
        else:
            self.tilt = _lerp(self.tilt, 0.0, 6.0, dt)
        if self.music and self.state in (IDLE, WALKING, HAPPY, WATCHING):
            self.bob = math.sin(now * 9.0) * 7.0

    def animation(self, now):
        name = {
            IDLE: "idle",
            WALKING: "walk",
            TYPING: "type",
            WATCHING: "idle",
            HAPPY: "happy",
            SAD: "sad",
            SLEEPING: "sleep",
            DRAGGING: "drag",
        }[self.state]
        counts = {"idle": 6, "walk": 4, "happy": 4, "sleep": 4, "drag": 2, "type": 4, "sad": 2}
        fps = {"idle": 6, "walk": 8, "happy": 8, "sleep": 3, "drag": 6, "type": 8, "sad": 5}[name]
        elapsed = max(0.0, now - self.phase_started)
        if name == "sleep":
            if elapsed < 0.3:
                index = 0
            elif elapsed < 0.6:
                index = 1
            else:
                index = 2 + int((elapsed - 0.6) * 2) % 2
        elif name == "walk":
            index = int(self.walked / 12.0) % counts[name]
        else:
            index = int(elapsed * fps * max(self.anim_speed, 0.2)) % counts[name]
        return name, index, self.facing
