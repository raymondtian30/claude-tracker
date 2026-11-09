# Claude Tracker in Swift: design

Date: 2026-11-08
Status: approved to build in one pass (design, review, build)

## Intent

Rewrite Claude Tracker, a macOS menu bar app tracking AI coding tool token
use, from Python (rumps + PyObjC) to Swift. The owner wants:

- **Lower memory and no Python dependency.** The running app uses about
  290 MB, mostly from the Python interpreter and PyObjC. It also breaks
  when Homebrew upgrades Python or pip packages change. A native Swift app
  should use about 30-60 MB and depend only on macOS.
- **Code that's easier to read and change.** SwiftUI for the panel's
  views; plain Swift for the logic.

Success means every feature in 2.5.0 works the same, with the same data,
after one Check for Updates. The full test suite is ported and passes, and
each feature is checked in the running app.

## Goals

- Feature parity with 2.5.0 (inventory below).
- Existing users upgrade in place: totals, settings, friends list,
  Keychain entries, notification permission and start-at-login carry over.
- Every existing Python test has a Swift counterpart covering the same
  behavior.
- Readable code: small files, one concern each, plain names, comments
  that say why.

## Non-goals

- New features or behavior changes. The "names fix" (limits shown as
  "Codex (Monthly)", full names for cut-off labels) comes *after* this
  ships, as its own change.
- Pixel-identical visuals. Same layout, sizes, order, wording and colors
  as far as SwiftUI allows.
- Distributing a prebuilt binary, notarization or the Mac App Store. The
  app is still built from source on the user's Mac.

## Anti-goals (a failure even if it compiles)

- Losing or resetting anyone's totals, settings or friends on upgrade.
- An update path that strands 2.5.0 users (Check for Updates fails, or the
  app doesn't come back after updating).
- Sending any data anywhere the Python app didn't, or reading files it
  didn't. The README's privacy promises must stay true.
- Quietly dropping a feature or a test because it was awkward to port.

## Constraints

- Toolchain: Xcode Command Line Tools only (Swift 6.3 here). There's no
  full Xcode, so builds use SwiftPM (`swift build`). Swift Testing works
  with these extra flags (verified):
  `-Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks`
  `-Xlinker -F -Xlinker $CLT/Library/Developer/Frameworks`
  `-Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks`
  `-Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib`,
  where `CLT=$(xcode-select -p)`. A `test.sh` script wraps this.
- Minimum macOS rises from 11 to 13 (Swift Testing and the SwiftUI APIs
  used need it).
- Contracts that must not change:
  - Bundle: `Claude Tracker.app`, bundle id `com.raymondtian.claudetracker`,
    executable `Contents/MacOS/claude-tracker` (the LaunchAgent points
    there), accepts and ignores `--foreground`, `LSUIElement` true, ad hoc
    signed with that identifier, icon `AppIcon`.
  - LaunchAgent label `com.claudetokencounter.menubar`, plist in
    `~/Library/LaunchAgents`, logs to `agent.log` / `agent.err.log` in the
    project folder.
  - Data lives in the project folder (the git clone): `state.json`,
    `friends.json`, `.claude-tracker.lock`. Same JSON shapes and keys;
    keys the Swift app doesn't know are kept on save.
  - Keychain services: `com.raymondtian.claudetracker.apikey` (account =
    provider), `com.claudetokencounter.github`, and read-only
    `Claude Code-credentials`. API keys are still never passed on a
    command line (use Security.framework directly, which also satisfies
    this).
  - Network: only the hosts the Python app contacts
    (`api.anthropic.com`, `api.github.com`, the provider APIs in
    `accounts.py`), with the same redirect and host checks.
  - Single instance: the lock file plus the "show panel" distributed
    notification, so launching again opens the running copy's panel.
  - Updater: GitHub releases API, `git fetch` + `merge --ff-only` of the
    tag, refusing modified or non-master clones, then rebuild and restart
    through `launchctl kickstart`.

## Upgrade path from 2.5.0 (the risky part)

2.5.0's Python updater fast-forwards the clone to the new tag. It then runs
`<python> build_app.py --python <python> --dest <dir>`, expects exit code 0,
and restarts through the LaunchAgent. So the Swift release must:

1. Keep a small `build_app.py` that accepts those arguments, runs
   `./build.sh --dest <dir>`, and passes on its exit code and last output
   line. It needs only Python's standard library. It's kept for at least
   one release and deleted later.
2. `build.sh` compiles with `swift build -c release`, assembles the bundle
   at `--dest` (default `/Applications`, else `~/Applications`, as now),
   writes Info.plist, copies the icon, signs ad hoc, and prints the
   executable's path as its last line. It replaces the bundle atomically:
   build into a temporary folder, then swap, so a failed compile leaves
   the old app working.
3. The Swift executable finds the project folder through an Info.plist
   key, `ClaudeTrackerProjectDir`, written by `build.sh`.
4. If compiling fails during the update (no Command Line Tools), the old
   updater shows "rebuilding failed, run ./install.sh". That message is
   acceptable. The Python app's files remain until the user does so.
   `install.sh` checks for `swift` first and says to run
   `xcode-select --install` if it's missing.

Python sources are deleted in the same release, except `build_app.py`.

## Approaches

1. **AppKit shell + SwiftUI panel + Swift core** *(chosen)*. AppKit runs
   the status item, the popover and its fold animation, outside-click and
   Esc closing, the Settings window and dialogs. SwiftUI draws tab
   contents, cards and the Settings content. Plain Swift holds all logic.
   It's readable where most code lives (views and logic) and keeps full
   control where SwiftUI can't do the job.
2. **Straight AppKit port.** A line-by-line translation of `panel_view.py`'s
   manual frame layout. Lowest visual drift, but verbose and
   coordinate-heavy, which works against the readability goal.
3. **All SwiftUI with `MenuBarExtra`.** The least code, but `MenuBarExtra`
   can't be opened from code (breaks "open the app again shows the
   panel"), and its animation and dismissal can't be controlled.
   Rejected.

Also rejected: a Swift UI over the existing Python logic. It keeps the
Python dependency, which is the main thing being removed.

The owner delegated the choice. Approach 1 is the builder's call.

## Architecture

A SwiftPM package at the repo root:

```
Package.swift
Sources/TrackerCore/     pure logic, no AppKit: everything unit-tested
Sources/ClaudeTracker/   the app: AppKit shell, SwiftUI views, wiring
Tests/TrackerCoreTests/  Swift Testing suites, one per Python test file
build.sh  test.sh  install.sh  uninstall.sh  build_app.py (shim)
Resources/AppIcon.icns  (generated once from the Python icon renderer)
```

Python module to Swift file (same names in Swift style, same split):

| Python | Swift (TrackerCore unless noted) |
|---|---|
| token_math.py | TokenMath.swift |
| usage_stats.py | UsageStats.swift |
| pricing.py | Pricing.swift |
| limits.py | Limits.swift |
| tools.py, providers.py | Tools.swift, Providers.swift |
| codex_source.py, gemini_source.py, opencode_source.py | CodexSource.swift, GeminiSource.swift, OpencodeSource.swift (SQLite3, read-only) |
| active_sessions.py, plugins.py | ActiveSessions.swift, Plugins.swift |
| claude_usage.py, accounts.py, gist_sync.py, leaderboard.py | ClaudeUsage.swift, Accounts.swift, GistSync.swift, Leaderboard.swift (Keychain via Security.framework) |
| updater.py | Updater.swift |
| stats_tabs.py | PanelModel.swift: tabs, cards and items as plain enums and structs, as today |
| version.py, panel_speeds.py | Version.swift, PanelSpeeds.swift |
| notifications.py | ClaudeTracker/Notifier.swift |
| single_instance.py | ClaudeTracker/SingleInstance.swift |
| tool_icons.py | ClaudeTracker/ToolIcons.swift |
| panel_view.py | ClaudeTracker/Panel/*.swift (popover controller + SwiftUI views per item kind) |
| app.py | ClaudeTracker/AppController.swift (+ small files per area: Leaderboard, Updates, Accounts) |
| build_app.py | build.sh (+ shim) |

Key decisions:

- **Panel model stays plain data.** `PanelModel` builds `[Tab]`, each a
  list of `Card`s holding `Item` enum cases matching today's tuples
  (`tiles`, `chart`, `bar`, `row`, `note`, `buttons`, `segmented`,
  `popup`, `switch`, `alert`, `tags`, `choices`). Ported tests assert on
  this model exactly as the Python tests do. SwiftUI renders one view per
  case. Actions stay strings handled by `AppController.handle(action:value:)`.
- **State** is a JSON-object wrapper (`[String: Any]` from
  `JSONSerialization`) with typed accessors. It round-trips unknown keys
  and writes atomically. This mirrors the Python dict, which keeps the
  port faithful and the file compatible both ways.
- **Concurrency:** network fetches and log scans run off the main thread
  and hand results to the main actor, as the Python threads do now.
- **Dialogs** (`rumps.Window`/`alert`) become `NSAlert`, with a text field
  accessory where input is needed, and the same titles and text.
- **Heights and spacing** come from `panel_view.py`'s constants (width
  360, padding 12, card padding 12, gap 10, corner 10, item heights) so
  the panel keeps its size and rhythm.

## Feature inventory (parity checklist)

Menu bar: count (lifetime / today / icon only), font size 10-14, tool icon
or coin, monospaced digits.

Panel: header (logo, title, subtitle), tool picker when 2+ tools, icon tab
bar with underline, tab fade, fold/unfold animation (Off/Fast/Normal/Slow),
scroll when taller than the screen, outside click and Esc to close,
footer (tracking since, Settings, Quit), warnings at the top of tabs.
Tabs: Overview (tiles, 14-day chart, stats rows), Token Types, Models,
Projects (top 5 + Show more), Estimated API Cost, Usage Limits (plan bars,
Notifications card with multi-threshold choices, window switches, test
alert), Active Sessions (Sessions with plugin tags, Plugins with activity),
Leaderboard (Beta, hidden unless enabled), provider account cards (OpenAI,
DeepSeek, Kimi: keys, usage, balance).

First run: welcome picker of detected tools.

Settings window: AIs (tools and providers), Appearance, menu bar display
and font size, animation, scan interval, start at login, Percentages from
Anthropic, show Leaderboard, About (version, credits, Check for Updates,
repo link).

Background: periodic scan (interval setting), backfill on launch, Claude
usage fetch, provider account fetches, daily leaderboard sync, limit alerts
(multi-threshold, migration of old state), update check and install.

Notifications: UNUserNotificationCenter with a delegate that shows
banners while active, permission flow, "blocked" and "banners off"
dialogs pointing to System Settings.

## Testing and verification

- Port each `tests/test_*.py` to `Tests/TrackerCoreTests/*Tests.swift`,
  test for test, using the same fixtures (temp dirs, fake logs, injected
  `run`/`get` functions in place of subprocess and HTTP). Tests of
  AppKit-only Python code (panel layout math, login item, tool icon
  lookup, notifications) are ported where the logic is separable;
  otherwise they're covered by the live checks below.
- `./test.sh` runs everything. It must pass before any PR.
- Live checks in the built app: launch from the bundle, take a
  screenshot of every tab and the Settings window, switch tools, the
  fold animation, a test notification, the scan updating the count,
  single-instance reopen, and the upgrade path (a 2.5.0 checkout runs
  its updater against the Swift tag in a scratch clone, never the user's
  own clone).

## Left to the builder

File layout inside `Panel/`, SwiftUI view structure, how `[String: Any]`
accessors are spelled, test helper design, and exact concurrency
primitives, as long as the constraints and contracts above hold.
