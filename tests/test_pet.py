"""Byte's pet behavior: click, drag, wander, sleep, typing, delete, music, video."""

import random

from pet_activity import PulseCounter, parse_player, parse_video
from pet_logic import (
    DRAGGING,
    HAPPY,
    IDLE,
    SAD,
    SLEEPING,
    TYPING,
    WALKING,
    WATCHING,
    Activity,
    PetMind,
    typing_anim_scale,
)
from pet_sprites import FRAME_COUNTS, frame_path
from stats_tabs import settings_tab


def _mind(now=0.0):
    mind = PetMind(now, random.Random(0), window_size=(240, 180))
    mind.place(200, 200)
    mind.ambient_in = 10_000
    mind.wander_in = 10_000
    mind.sleep_at = 10_000
    return mind


def _tick(mind, now, activity=None, mouse=(400, 400), bounds=(0, 0, 1200, 700)):
    mind.tick(now, 0.05, bounds, mouse, activity or Activity())


def test_click_is_a_short_happy_hop():
    mind = _mind()
    mind.pointer_down(0, 200, 200)
    assert mind.pointer_up(0) == "click"
    assert mind.state == HAPPY
    now = 0.0
    while now < 1.0:
        now += 0.05
        _tick(mind, now)
    assert mind.state == HAPPY
    while now < 1.4:
        now += 0.05
        _tick(mind, now)
    assert mind.state == IDLE


def test_drag_wins_over_wander_and_is_not_a_click():
    mind = _mind()
    mind.wander_in = 0
    mind.pointer_down(0, 200, 200)
    mind.pointer_drag(0.1, 260, 200)
    _tick(mind, 0.2)
    assert mind.state == DRAGGING
    assert mind.pointer_up(0.3) == "moved"
    assert mind.state == IDLE


def test_wander_lerps_to_a_screen_edge_then_rests():
    mind = _mind()
    mind.wander_in = 0
    _tick(mind, 0)
    assert mind.state == WALKING
    assert mind.walk_target is not None
    target = mind.walk_target
    now = 0.0
    for _ in range(80):
        now += 0.05
        _tick(mind, now)
        if mind.state == IDLE:
            break
    assert mind.state == IDLE
    assert abs(mind.x - target[0]) < 4
    assert abs(mind.y - target[1]) < 4


def test_sleeps_after_being_left_alone_and_wakes_when_hovered():
    mind = _mind()
    mind.sleep_at = 5
    _tick(mind, 5)
    assert mind.state == SLEEPING
    assert mind.animation(5.1)[0] == "sleep"
    mind.hover(True, 6)
    assert mind.state == IDLE


def test_a_claude_session_wakes_the_cat_and_keeps_it_up():
    mind = _mind()
    mind.sleep_at = 1
    _tick(mind, 1)
    assert mind.state == SLEEPING
    mind.note_session(True, 2)
    assert mind.state == HAPPY
    mind.sleep_at = 3
    _tick(mind, 4)
    assert mind.state != SLEEPING


def test_typing_walks_toward_the_cursor_and_ignores_delete():
    mind = _mind()
    _tick(mind, 0.1, Activity(typing=True, cps=4), mouse=(10, 10))
    assert mind.state == TYPING
    spot = mind.type_spot
    assert spot[0] > 10
    now = 0.1
    for _ in range(40):
        now += 0.05
        _tick(mind, now, Activity(typing=True, cps=8), mouse=(10, 10))
    assert mind.x < 200
    assert abs(mind.x - spot[0]) < abs(200 - spot[0])
    _tick(mind, now + 0.05, Activity(typing=True, delete="burst"), mouse=(10, 10))
    assert mind.state == TYPING


def test_delete_makes_the_cat_sad_unless_it_is_asleep():
    mind = _mind()
    _tick(mind, 1, Activity(delete="tap"))
    assert mind.state == SAD
    assert mind.bubble
    mind = _mind()
    mind.sleep_at = 1
    _tick(mind, 1)
    _tick(mind, 1.1, Activity(delete="burst"))
    assert mind.state == SLEEPING


def test_video_stops_the_wander_and_music_is_announced_once():
    mind = _mind()
    mind.wander_in = 0
    _tick(mind, 0, Activity(video=True, video_label="YouTube"))
    assert mind.state == WATCHING
    assert "YouTube" in mind.bubble
    _tick(mind, 0.2, Activity(video=True, video_label="YouTube"))
    assert mind.state == WATCHING
    mind = _mind()
    _tick(mind, 0, Activity(music=True, track="Song — Artist"))
    assert mind.bubble.startswith("♪ ")
    again = mind.bubble
    mind.ambient_in = 10_000
    mind.state = IDLE
    _tick(mind, 1, Activity(music=True, track="Song — Artist"))
    assert mind.bubble == again or mind.bubble == ""


def test_typing_speed_scales_the_paws():
    assert typing_anim_scale(1) == 0.6
    assert typing_anim_scale(4) == 1.0
    assert typing_anim_scale(8) == 2.4


def test_two_quick_pulses_start_typing_and_a_delete_is_not_stored_as_a_key():
    pulses = PulseCounter()
    assert not pulses.snapshot(0).typing
    pulses.push_typing(1.0)
    pulses.push_typing(1.1)
    seen = pulses.snapshot(1.1)
    assert seen.typing
    pulses.push_delete(1.2)
    assert pulses.snapshot(1.2).delete == "tap"
    assert not hasattr(pulses, "keys")


def test_player_and_video_text_become_labels_only():
    assert parse_player("playing\nNight\nCat") == (True, "Night — Cat")
    assert parse_player("stopped") == (False, "")
    assert parse_video("Safari", "lofi hip hop - YouTube") == (True, "YouTube")
    assert parse_video("Safari", "Bank statement") == (False, "")
    assert parse_video("VLC", "lecture.mp4") == (True, "VLC")


def test_frames_exist_for_every_animation():
    for name, count in FRAME_COUNTS.items():
        for index in range(count):
            data = frame_path(name, index).read_bytes()
            assert data.startswith(b"\x89PNG")


def test_settings_has_the_pet_switches():
    tab = settings_tab({}, interval_choices=[15], detected=[])
    general = next(card for card in tab["cards"] if card["title"] == "General")
    actions = [item[-1] for item in general["items"] if item[0] == "switch"]
    assert actions[:5] == [
        "login", "pet_enabled", "pet_typing", "pet_deleting", "pet_media",
    ]
