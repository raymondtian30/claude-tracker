from panel_view import SCREEN_MARGIN, panel_height


def all_views(view):
    """Every view inside `view`, nested ones too (tabs draw into their own)."""
    found = []
    for child in view.subviews():
        found += [child] + all_views(child)
    return found


def test_short_content_uses_its_own_height():
    assert panel_height(500, screen_height=800) == 500


def test_tall_content_is_capped_to_the_screen():
    assert panel_height(900, screen_height=800) == 800 - SCREEN_MARGIN


def test_tool_switcher_is_a_dropdown():
    from AppKit import NSPopUpButton, NSSegmentedControl

    from panel_view import Panel

    tab = {"key": "overview", "title": "Overview", "short": "Home", "icon": "square.grid.2x2",
           "cards": [{"title": None, "items": [("note", "hi")]}]}
    panel = Panel(on_action=lambda action, value: None)

    panel.render([tab], "footer",
                 tool_choices=[("claude_code", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode")],
                 selected_tool="codex")

    popups = [v for v in all_views(panel.root) if isinstance(v, NSPopUpButton)]
    assert len(popups) == 1
    assert list(popups[0].itemTitles()) == ["Claude Code", "Codex", "opencode"]
    assert popups[0].indexOfSelectedItem() == 1
    assert not [v for v in all_views(panel.root) if isinstance(v, NSSegmentedControl)]


TAB = {"key": "overview", "title": "Overview", "short": "Home", "icon": "square.grid.2x2",
       "cards": [{"title": None, "items": [("note", "hi")]}]}


def test_settings_button_asks_the_app_to_open_the_settings_window():
    from AppKit import NSButton

    from panel_view import Panel

    calls = []
    panel = Panel(on_action=lambda action, value: calls.append((action, value)))
    panel.render([TAB], "footer")

    button = next(v for v in all_views(panel.root)
                  if isinstance(v, NSButton) and v.toolTip() == "Settings")
    panel._fire(button.tag(), None)

    assert calls == [("open_settings", None)]
    assert panel.selected == "overview"  # the popover itself doesn't change


def test_popover_no_longer_shows_settings_inline():
    from panel_view import Panel

    panel = Panel(on_action=lambda action, value: None, selected_tab="settings")
    panel.render([TAB], "footer")

    assert panel.selected == "overview"


def test_settings_window_draws_the_settings_cards():
    from AppKit import NSSwitch, NSTextField

    from panel_view import SettingsWindow

    calls = []
    settings = {"key": "settings", "title": "Settings", "short": "Settings", "icon": "gear",
                "cards": [{"title": "AI tools", "items": [("switch", "Codex", True, "tool:codex")]}]}
    window = SettingsWindow(on_action=lambda action, value: calls.append((action, value)))

    window.render(settings)

    assert window.window.title() == "Claude Tracker Settings"
    labels = [v.stringValue() for v in window.root.subviews() if isinstance(v, NSTextField)]
    assert "AI tools" in labels and "Codex" in labels
    switch = next(v for v in window.root.subviews() if isinstance(v, NSSwitch))
    window._fire(switch.tag(), False)
    assert calls == [("tool:codex", False)]


def test_header_shows_the_selected_ais_logo_instead_of_the_coin():
    from AppKit import NSImage, NSImageView, NSTextField

    from panel_view import Panel

    logo = NSImage.alloc().initWithSize_((16, 16))
    panel = Panel(on_action=lambda action, value: None)
    panel.render([TAB], "footer", logo=logo)

    images = [v.image() for v in all_views(panel.root) if isinstance(v, NSImageView)]
    labels = [v.stringValue() for v in all_views(panel.root) if isinstance(v, NSTextField)]
    assert logo in images
    assert "🪙" not in labels


def test_header_keeps_the_coin_without_a_logo():
    from AppKit import NSTextField

    from panel_view import Panel

    panel = Panel(on_action=lambda action, value: None)
    panel.render([TAB], "footer")

    assert "🪙" in [v.stringValue() for v in all_views(panel.root) if isinstance(v, NSTextField)]


def test_clicking_the_menu_bar_icon_is_left_to_the_icon_to_toggle():
    """The icon's own click closes an open panel. If the outside-click
    monitor closed it first, the icon's toggle would just reopen it."""
    from types import SimpleNamespace

    from panel_view import Panel

    panel = Panel(on_action=lambda action, value: None)
    status_window, settings_window = object(), object()
    panel._button = SimpleNamespace(window=lambda: status_window)

    assert not panel._click_closes(status_window)
    assert not panel._click_closes(panel.root.window())
    assert panel._click_closes(settings_window)


def test_animation_speeds():
    from panel_view import ANIMATION_SPEEDS

    assert ANIMATION_SPEEDS == [("off", "Off", 0.0), ("fast", "Fast", 0.12),
                                ("normal", "Normal", 0.22), ("slow", "Slow", 0.4)]


def test_unfolding_grows_from_a_strip_to_full_height():
    from panel_view import FOLDED_HEIGHT, fold_height

    heights = [fold_height(t / 10, 600, unfolding=True) for t in range(11)]

    assert heights[0] == FOLDED_HEIGHT
    assert heights[-1] == 600
    assert heights == sorted(heights)


def test_no_frame_jumps_much_more_than_the_average():
    """Big jumps in the first frames looked choppy: the motion eases in and
    out, so no step is more than twice the average one."""
    from panel_view import fold_height

    frames = 26  # 0.22 s at 120 Hz
    for unfolding in (True, False):
        heights = [fold_height(i / frames, 600, unfolding) for i in range(frames + 1)]
        steps = [abs(b - a) for a, b in zip(heights, heights[1:])]
        assert max(steps) <= 2 * sum(steps) / len(steps), unfolding
        assert steps[0] <= steps[frames // 2] and steps[-1] <= steps[frames // 2]


def test_folding_shrinks_back_to_the_strip():
    from panel_view import FOLDED_HEIGHT, fold_height

    heights = [fold_height(t / 10, 600, unfolding=False) for t in range(11)]

    assert heights[0] == 600
    assert heights[-1] == FOLDED_HEIGHT
    assert heights == sorted(heights, reverse=True)


def test_progress_past_the_end_is_clamped():
    from panel_view import fold_height

    assert fold_height(1.7, 600, unfolding=True) == 600
    assert fold_height(-1, 600, unfolding=True) == fold_height(0, 600, unfolding=True)


def test_opening_the_panel_goes_back_to_home():
    from panel_view import Panel

    limits = {**TAB, "key": "limits", "title": "Usage Limits", "short": "Limits"}
    panel = Panel(on_action=lambda action, value: None)
    panel.render([TAB, limits], "footer")
    panel._select_tab(1)
    assert panel.selected == "limits"

    panel._go_home()

    assert panel.selected == "overview"


def test_switching_tabs_reuses_each_tabs_views():
    """A tab is built once per render; going back to it doesn't rebuild it."""
    from panel_view import Panel

    limits = {**TAB, "key": "limits", "title": "Usage Limits", "short": "Limits",
              "cards": [{"title": "Plan limits", "items": [("note", "a"), ("note", "b")]}]}
    panel = Panel(on_action=lambda action, value: None)
    panel.render([TAB, limits], "footer")
    home = panel._shown_tab_view

    panel._select_tab(1, fade=False)
    limits_view = panel._shown_tab_view
    panel._select_tab(0, fade=False)

    assert panel._shown_tab_view is home
    assert limits_view is not home and limits_view.superview() is None
    assert home.superview() is panel.root and home.alphaValue() == 1.0


def test_new_data_rebuilds_the_tabs():
    from panel_view import Panel

    panel = Panel(on_action=lambda action, value: None)
    panel.render([TAB], "footer")
    before = panel._shown_tab_view

    panel.render([TAB], "footer")

    assert panel._shown_tab_view is not before


def test_appearance_follows_the_setting():
    from AppKit import NSApplication

    from panel_view import apply_appearance

    app = NSApplication.sharedApplication()
    apply_appearance("dark")
    assert app.appearance().name() == "NSAppearanceNameDarkAqua"
    apply_appearance("light")
    assert app.appearance().name() == "NSAppearanceNameAqua"
    apply_appearance("auto")
    assert app.appearance() is None  # follows macOS
