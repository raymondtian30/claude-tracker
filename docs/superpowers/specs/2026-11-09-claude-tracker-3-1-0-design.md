# Claude Tracker 3.1.0: ten changes

*   **Author:** Raymond Tian
*   **Status:** Draft 2. Revised to resolve the Goldfish review (5 Blockers, 17 Majors, 18 Minors). The owner is unavailable and waived all questions, so every open point was decided in the Decision Log. See "Review disposition" at the end.
*   **Date:** 2026-11-09
*   **Input:** `concepts_brief.md`
*   **Code read:** repo `raymondtian30/claude-tracker`, master at 3.0.0, commit `4c49a4b` (read-only checkout; paths below are relative to the repo root; code is cited by symbol, not line number)

--------------------------------------------------------------------------------

## Overview

Claude Tracker is a macOS menu bar app (AppKit shell, SwiftUI panel, Swift 5.9, macOS 13 minimum) that reads the logs of AI coding tools on the Mac and shows token use and plan limits. Version 3.1.0 bundles ten changes the owner has already decided: consistent limit names, a way to read cut-off names, folder-name rows with a full path and Show in Finder, an accounts view with a filter, an interactive graph, model effort, a FAQ card, an optional pace alert, a fix for repeating alerts, and a read-only Hooks tab.

This document is a build plan an engineer can follow without making design choices. It records every decision, the data and state changes, the privacy effects, the tests per PR, and the order of work: one foundation PR, one PR per owner change, one release PR.

**Naming used throughout.** "Change n" is one of the ten owner changes (numbered as in the brief). "PR n" is a build-order number from the table at the top of the Detailed Implementation Plan. Nothing else is numbered as a PR.

## Terms

*   **Level**: one plan limit shown as a bar and alerted on (`Limits.Level`). It has a **window** (`five_hour`, `weekly`, `monthly`), an optional **kind** (Anthropic's name for it, such as `weekly_opus`) and an `id` of the form `tool:kind-or-window`.
*   **Per-limit notification switch**: the switches in the Notifications card (for example "5-hour limit") that choose which windows alert. Code name: `alert_windows`.
*   **Tracking menu**: the dropdown labelled "Tracking" at the top of the panel (`PanelLayout.toolPicker`). It picks one AI tool, one AI company, or "All AIs".
*   **Account** (UI) is what the code calls an **identity** (`Identities`, `AccountScope`). It is unrelated to the existing `Accounts.swift` and `state["accounts"]`, which hold optional provider API keys.
*   **Gist**: the GitHub Gist the optional Leaderboard writes to.
*   **Hysteresis**: requiring a level to drop well below a threshold before it can alert again.

## The Problem

1.  **Limit names are inconsistent.** The Limits tab shows "Weekly · resets Nov 20" in a single tool's view and "Codex Weekly" in All AIs. Notifications say "Codex: Weekly usage is at 80%." Three places build names with three formats. Anthropic's fetched Opus and Sonnet levels already carry distinct labels ("Weekly · Opus"), but the log-based fallback gives two bars both named "Weekly".
2.  **Long labels are cut off with no way to read them.**
3.  **Projects and Sessions rows show long paths** that are cut in the middle. A bug hides most project rows: any project under the home folder is merged into the single "~" row when a session ran in the home folder.
4.  **There is no view of accounts.** Codex logs record which account created a session, but the app adds everything together.
5.  **The graph is a picture only.** No dates, no numbers, no breakdown.
6.  **The model effort level** (Codex `effort`, Claude Code `effort`) is in the logs but not shown.
7.  **The words "Anthropic", "Tracking" and "AI tools"** confuse people; nothing in the app explains them.
8.  **Nothing warns before a limit runs out.** Alerts fire only after a threshold is passed.
9.  **Alerts repeat after launch.** Root cause is in `Limits.alertsToSend` (see Change 9).
10. **Users cannot see which automatic commands their AI tools run** at session start and on other events.

## Goals

*   All ten changes as the owner decided, each as its own PR with tests (one PR per change), after one foundation PR, then one release PR for 3.1.0.
*   One name function used by the panel and notifications (Change 1); chevron plus inline full text for cut-off `bar` and `row` labels (Change 2).
*   Folder-name rows with same-name labels, full path, Show in Finder, and the home-folding fix (Change 3).
*   Accounts: who is signed in, tokens per account, plan limits per account, and a "Show only" filter, for Codex where logs allow; "not available" elsewhere (Change 4).
*   Graph on Home: hover numbers, click a day for a breakdown by model and project, range 7/14/30 (Change 5).
*   Effort next to the model name, display only, with pricing and model keys unchanged (Change 6).
*   FAQ card in Settings with the real UI labels (Change 7).
*   Pace alert, off by default (Change 8). No repeat alerts at launch (Change 9).
*   Read-only Hooks tab, Claude Code first (Change 10).
*   Every PR that reads something new updates the README privacy text in the same PR.
*   `state.json` changes are additive so 3.0.0 can still read the file.
*   **Intended exceptions to "one PR per change":** PR 0 (foundation, no owner change) and PR 11 (release). Nothing else. Change 3 includes the home-folding fix; Change 4 includes both the Accounts card and the "Show only" filter (the filter is the part to cut, see D28).

## Non-Goals

*   Changing the saved `label` in `state.json`, or any stored-text migration.
*   Changing which account Codex or Claude Code uses.
*   Splitting past Claude Code usage by account; Gemini or opencode accounts.
*   Account nicknames or renaming (not among the four decided account capabilities; dropped, D41).
*   Storing or syncing tokens, emails, JWTs, raw account ids or hook commands.
*   Editing or disabling hooks from the app.
*   A model-by-project cross-table in the graph breakdown.
*   Chevrons on tiles, tag lines, leaderboard bars, Settings rows and note lines.
*   Renaming notification switch labels, note-line prefixes ("Codex: ..."), or the test alert text.
*   Saving open-row or selected-day state across launches.
*   A trailing-hour pace rate with stored samples; hysteresis on alerts.
*   Swift Charts (hover and click are built on the existing `Canvas` chart).
*   Reading `~/.codex/config.toml` (no TOML parser is added).

## Open Questions

None. The owner waived questions and every point is decided in the Decision Log. Five checks that need a real build (and one manual list) each have a pass/fail rule and a fallback under "Checks that need a real build".

--------------------------------------------------------------------------------

## Critical User Journeys (CUJs)

### CUJ 1: Reading limits (Change 1)

*   **Given**: Claude Code and Codex are tracked; Codex has a monthly limit at 80%.
*   **When**: The user opens the Limits tab in All AIs, then in Codex alone.
*   **Then**: Both show "Codex (Monthly)" with "80%" on the right and "Resets Nov 20" in small grey text under the bar. The notification reads "Codex (Monthly) usage is at 80%. Resets on Nov 20."

### CUJ 2: Reading a cut-off name (Change 2)

*   **Given**: A bar label is wider than its slot.
*   **When**: The user clicks the row.
*   **Then**: A chevron on the row rotates and a line with the full text opens under it. Hovering shows the same text. Clicking again, switching tab, or closing the panel closes it. Switching away and back shows the row closed.

### CUJ 3: Finding a project folder (Change 3)

*   **Given**: Projects shows "assets" twice (two different parents).
*   **When**: The user clicks one row.
*   **Then**: Rows read "assets · FPS Game" and "assets · Robot" (parent in grey). The click opens a line with the full path and a Show in Finder button. A row for "Unknown" has no button.

### CUJ 4: Two Codex accounts (Change 4)

*   **Given**: Codex logs hold two account ids plus older logs with none.
*   **When**: The user opens Limits, then picks "Account 2" under "Show only".
*   **Then**: The Accounts card lists Account 1 (signed in), Account 2, and Unattributed with tokens each, and the last-seen limits for the account that is not signed in, marked "Last seen ...". After picking, the Codex tabs and graph show Account 2 only and the header says "Account 2 only". Claude Code, Gemini CLI and opencode are not split by account: their own tabs show all their usage with a note "Not split by account".
*   **Verification note**: this Mac has one account id in its logs, so CUJ 4 cannot be run end to end here. Tests use fixtures; the release PR runs it on a fixture `state.json`.

### CUJ 5: Inspecting a day (Change 5)

*   **Given**: The Home graph shows the last 14 days.
*   **When**: The user hovers a point, clicks a day, switches the range to 30 days.
*   **Then**: Hover shows "Nov 7th · 1.2M". Click marks the day and shows a card with that day's models and projects (top 5 plus "N more"). The range choice persists.

### CUJ 6: Codex effort (Change 6)

*   **Given**: Codex sessions used `gpt-5.6-luna` at medium effort.
*   **When**: The user opens Models.
*   **Then**: The row reads "gpt-5.6-luna (MEDIUM)". Totals and cost are the same as before.

### CUJ 7: Pace warning (Change 8)

*   **Given**: Pace alert is on; the weekly window is 40% elapsed and 70% used.
*   **When**: The next check runs.
*   **Then**: One notification says the limit may run out about Thu 4:15 PM before it resets, once for that window.

### CUJ 8: Launch without repeat alerts (Change 9)

*   **Given**: Claude Code is at 80%, the 75% alert was already sent; the Mac starts with no network.
*   **When**: The app launches and the network returns.
*   **Then**: No alert is sent. A limit that is reached after launch still alerts, including a log-only (fallback) limit that first appears after launch.

### CUJ 9: Hooks (Change 10)

*   **Given**: `~/.claude/settings.json` has hooks.
*   **When**: The user opens the Hooks tab and clicks a row.
*   **Then**: Rows show event, matcher and program name only. Click reveals the arguments (secrets masked, best effort) and the file path with a Show in Finder button. Gemini CLI and opencode show "not available" with a reason.

### CUJ 10: FAQ (Change 7)

*   **Given**: A user sees "Anthropic" in the Tracking menu and "Claude Code" next to it.
*   **When**: They open Settings and scroll to FAQ.
*   **Then**: Each question uses the exact labels of the UI and the Anthropic answer says it is a company view counting `claude-*` models from every tracked tool.

### CUJ 11: Projects under the home folder (Change 3)

*   **Given**: A session ran in the home folder and others ran in `~/a` and `~/b`.
*   **When**: The user opens Projects.
*   **Then**: Rows "Home (~)", "a" and "b" are separate.

### CUJ 12: Claude Code effort (Change 6)

*   **Given**: Claude Code logs carry `effort` on assistant entries.
*   **When**: The user opens Models after the 3.1.0 first launch.
*   **Then**: Rows read "Opus 5.5 (XHIGH)" and so on; history still on disk is backfilled once; history whose files are gone shows plain model rows.

### CUJ to test map

| CUJ | Change / PR | Tests that prove it |
| --- | --- | --- |
| 1 | 1 / PR 2 | `displayNameAllTools`, `limitsTabUsesDisplayNameInAllViews`, `notificationTextMonthly` |
| 2 | 2 / PR 4 | `cutOffAtBudgetBoundary`, `openRowInsertsDetail`, `chevronBudgetBoundary`; manual check "open, switch away, switch back" |
| 3 | 3 / PR 5 | `sameNameParentsGetGreyTail`, `unknownRowHasNoButton`, `revealBoolFromOpenRows` |
| 4 | 4 / PR 6 | `scopeFiltersCodex`, `unattributedOnlyInAll`, `lastSeenLimitsForOtherAccount`, `combinedViewUnderScopeExcludesOtherTools`; fixture run in PR 11 |
| 5 | 5 / PR 8 | `chartRangeClamp`, `dayBreakdownTop5PlusRest`, `chartDayActionParse` |
| 6, 12 | 6 / PR 7 | `codexEffortSplitsPerTurn`, `claudeEffortField`, `effortRowsSumToModelTotal`, `backfillEffortsOnce` |
| 7 | 8 / PR 9 | `paceSteadyRateAlerts`, `paceKeyIgnoresJitter` |
| 8 | 9 / PR 1 | `launchWithLevelOverThresholdSendsNothing`, `fallbackLevelFirstSeenAfterLaunchAlerts`, `fetchErrorCarriesKeys` |
| 9 | 10 / PR 10 | `redactsSecretsOnReveal`, `parsesUserSettings`, `notAvailableForGeminiAndOpencode` |
| 10 | 7 / PR 3 | `faqUsesUiConstants`, `faqAnthropicAnswerMatchesProviderView` |
| 11 | 3 / PR 5 | `foldSkipsHomeAndRoot`, `homeRowIsSeparate` |

--------------------------------------------------------------------------------

## Technical Plan (Architecture)

Sections follow PR order: PR 0 foundation, then Changes 9, 1, 7, 2, 3, 4, 6, 5, 8, 10 (PR 1 to PR 10), then data, privacy, errors and checks.

### Code facts this plan depends on

*   Package: `TrackerCore` (pure Swift, no AppKit), `ClaudeTracker` (AppKit shell, SwiftUI views), tests in `TrackerCoreTests`. Platform `.macOS(.v13)`, tools 5.9.
*   `PanelLayout.height(of:)` returns a fixed number by item kind (`heights` table). Bar 36, row 22, note 16, chart 84.
*   `PanelController.draw()` rebuilds every view on each data render (every refresh while the panel shows, and after each action). No SwiftUI `@State` survives. `PanelController.selectTab` does not call `draw()` when the chrome exists: it swaps cached `TabViewCache` views via `showTab`. `PanelController` has an `onTabChange` callback that `AppController` does not use today, and `onWillShow`, which `AppController` sets to `renderPanel()` and which runs before every open. `PanelController` owns an `NSScrollView` for the tab content.
*   `AppController.projectsExpanded` is the existing example of UI state kept outside views.
*   `state.json` is untyped JSON in the project folder (gitignored). `applyLaunchDefaults` fills missing keys. There is no schema version.
*   The Codex cache is per file: `sources.codex.files[path] = {size, mtime, daily, limits}`. A file is re-read when `saved["limits"] == nil` or size/mtime changed. A deleted file keeps its entry. `CodexSource.codexRateLimits` takes the newest `limits` across all files.
*   Claude Code usage is read incrementally by byte offset (`file_offsets`) into `daily`. `backfillDaily` re-reads each file from 0 up to its saved offset.
*   Daily buckets: `addUsage` writes `models`, `projects` and `model_projects`. Older buckets (written before `model_projects` existed) lack it.
*   The Gist leaderboard payload (`AppState.leaderboardPayload`) holds exactly four keys: `name`, `total_tokens` (from `state["grand_total"]`, a Claude Code figure), `yesterday_tokens`, `updated_at`.
*   `Plugins.hookDetails(_:) -> (events: Set<String>, strings: Set<String>)` is called by `Plugins.profile`. Its output is unordered sets.
*   Tabs per view in `PanelModel.buildPanel`: Overview, Token Types, Models, Projects, Cost, Limits (6), plus Live when the view is not a provider view, plus Leaderboard only when the view is Claude Code (`showLeaderboard: ... && view.key == "claude_code"`). So today: provider view 6, All AIs 7, Codex 7, Claude Code 7 or 8 with the Leaderboard on.
*   Tab captions are already drawn at 9 pt (`PanelChromeView.tabButton`); slots are equal, `336 / tabCount` points.
*   `AppController.start` order: `loadState`, `applyLaunchDefaults`, `backfillDaily`, `backfillLimits`, `scan`.

### Facts observed in real logs (one Mac, 2026-11-09; names and counts only, no values of secrets printed)

These were re-checked read-only for this revision. They are one machine's evidence, not a guarantee for other users.

| Item | Observed |
| --- | --- |
| Codex effort | `turn_context.payload.effort` (string). 189 of 190 turn contexts have it; the only value seen is `medium`. `payload.collaboration_mode.settings.reasoning_effort` is present on the same 189. No file of the 53 changed effort mid-session. |
| Codex account | `session_meta.payload.creator_account_id`: present in 23 of 53 files, one distinct id; 30 older files have none. The id equals `~/.codex/auth.json` `tokens.account_id`. `auth.json` keys: `auth_mode` (value `chatgpt` here), `OPENAI_API_KEY`, `tokens.{id_token, access_token, refresh_token, account_id}`, `last_refresh`. |
| Codex limits | `token_count` events carry `rate_limits` with only a `primary` slot here, `window_minutes` 43200 (exactly 30 days) in all 961 records. `timestamp` is an ISO string with milliseconds and `Z` (24 characters). So "Monthly" is a rolling 30-day window on this plan. |
| Claude effort | Top-level `effort` on `assistant` entries that hold `message.usage`: present on 21165 of 21229 usage entries across 185 files; values `medium` (16614), `high` (4420), `xhigh` (131). `perTurnEffort` is on 21224 entries (values include null on 247) and differs from `effort` on 245 of the 21165 entries that have both. |
| Claude account | `~/.claude.json` is 95 KB; `oauthAccount` has `accountUuid`, `emailAddress`, `displayName`, `fullName`, `organizationName` and 15 other keys. |
| Claude hooks | `~/.claude/settings.json` `hooks`: 7 events here (PostToolUse, PreCompact, PreToolUse, SessionEnd, SessionStart, Stop, UserPromptSubmit), 11 hook entries, all `type: "command"`; group keys `matcher` (optional) and `hooks`; hook keys `type`, `command`, `timeout`, optional `statusMessage`. 10 plugin `hooks/hooks.json` files: top-level `hooks` (and sometimes `description`, `modules`); hook keys also `shell`, `async`, `if`, `asyncRewake`, `rewakeMessage`, `rewakeSummary`. No `~/.claude/settings.local.json` and no managed-settings file exists here. User settings keys here: `enabledPlugins`, `env`, `extraKnownMarketplaces`, `hooks`, `model`, `modelSettings`, `switchModelsOnFlag`, `theme` (no `disableAllHooks`). |
| Codex hooks | No `~/.codex/hooks.json`. `~/.codex/config.toml` has no "hook" text (sections: `projects`, `features`, `memories`, `notice`). The only `hooks.json` files under Codex-style paths are `.codex/hooks.json` inside two copies of the installed caveman plugin (same shape as Claude's) and one inside a Codex-managed plugin folder; so the format is inferred from plugins, and the user-level location `~/.codex/hooks.json` is unverified. |
| Gemini, opencode | `gemini` is not installed; `~/.gemini` has only `antigravity` and `config`; no `settings.json`. opencode is installed; `~/.config/opencode` has `cli.json` and `service.json`; no `plugin` key, no plugin folder. |
| Alert state | `alert_thresholds` `[50, 75, 90]`. `alerts_above` now holds 5 keys (`claude_code:five_hour@50`, `claude_code:weekly@50`, `claude_code:weekly@75`, `codex:monthly@50`, `codex:monthly@75`). |
| Daily buckets | 12 saved days in the Claude Code bucket set: 10 have only `models` and `projects`; 2 have `model_projects`. The 3 opencode days all have `model_projects` and `recorded_cost`. Days 15 to 30 of history cannot be confirmed here (12 days exist). The draft's earlier claim "no `model_projects`" was wrong and is corrected; the design does not depend on it (D18). |

**Corrected from draft 1:** Claude entries 21229 (not 6144), effort on 21165 (not 6117), `perTurnEffort` on 21224 (not 6143); hooks events 7 (not 8); buckets are mixed, not "none with `model_projects`"; alert keys now five. Codex counts (189/190, 53 files, 23 with id) were confirmed unchanged. "Monthly is a rolling 30 days" is confirmed by `window_minutes` 43200.

### Facts that differ from the brief

1.  **Claude Code effort is available** (`effort` on assistant entries), so Claude is not "show nothing"; it shows effort for entries read from now on, plus a one-time backfill from files still on disk.
2.  **Fallback alert ids differ only for Opus and Sonnet.** `reachedClaudeLimits` builds levels with window only; their ids come out `claude_code:five_hour` and `claude_code:weekly`, equal to the fetched ids for those two. Fallback Opus and Sonnet levels also get `claude_code:weekly` (no kind), colliding with the plain weekly id; fetched ones are `weekly_opus` and `weekly_sonnet`.
3.  **`fetchUsage` drops old percentages on error on purpose** (comment: "old percentages could be wrong"). The brief's option to "keep the previous limits on error" is rejected; the fix is at the alert level only.
4.  **Gemini rows can have real paths** (`GeminiSource.projectOf` uses `.project_root` or `projects.json`), so "Show in Finder only if the label starts with `~/` or `/`" is correct, not "never for Gemini".
5.  **Codex and opencode Live rows have no folder stored.** `runningToolSessions` builds `Session(label:tokens:)` without `cwd`; Change 3 adds it.
6.  **Tab bar:** equal slots of `336 / tabCount`. Today 6 to 8 tabs; a Hooks tab makes 9 only in the Claude Code view with the Leaderboard on (about 37 pt per slot); All AIs and Codex get 8. Captions are already 9 pt, so no font step is left to try (see Change 10).
7.  **README says** Gemini rows come from `.project_root` for "the folder name"; it must now also say full paths are shown.

### PR 0: shared foundation (item heights, open rows, measuring, scroll)

Needed by Changes 1, 2, 3, 5 and 10. No visible change except that bars gain the optional second line when `sub` is set (not yet set by anyone).

**Item data.** In `PanelItems.swift`:

*   `Item.bar(label:value:fraction:sub:extras:)` and `Item.row(label:value:extras:)`. `sub: String?` is the second line under the bar. `extras` is a plain struct `LabelExtras` with default `.none`:
    *   `greyTail: String?` text drawn grey after the label (same-name parent).
    *   `expandID: String?` the row id; nil means the row is not clickable.
    *   `isOpen: Bool` whether it is open now.
    *   `tip: String?` hover and accessibility text (full name).
*   Defaults keep `.bar(label:value:fraction:)` and `.row(label:value:)` call sites compiling. Pattern matches that destructure the old three-value `bar` (`CardView.swift`, a few tests) are updated to the new arity in this PR. The view side (chevron drawn when `expandID != nil`) lands with Change 2 (PR 4); PR 0 only carries the data.
*   `Item.detail` is not added here; it lands in PR 4 with its height rule and tests, so each new case lands once with its first user.

**Heights.** `PanelLayout.height(of:)` reads item data, not only `kind`. PR 0 rule: `bar` is 36 plus `barSubHeight = 14` when `sub != nil`. All other kinds use the `heights` table. (The `detail` rule is PR 4.)

**Measuring.** `public enum LabelWeight { case regular, semibold }` in `TrackerCore` (the app maps it to `Font.Weight`). `typealias TextMeasure = (_ text: String, _ size: CGFloat, _ weight: LabelWeight) -> CGFloat` in `PanelModel`. The app target provides `TextMeasure.live` (`NSString.size(withAttributes:)` with `NSFont.systemFont(ofSize:weight:)` at the size and weight `LabelText` uses). Tests pass a stub (7 points per character).

**One budget function.** `PanelLayout.labelBudget(kind:hasChevron:) -> CGFloat`, the only source of the widths. Without a chevron: bar `width - 120 = 192`, row `width - 110 = 202`, where width is `PanelLayout.inner - 2 * cardPad = 312`. With a chevron: 14 pt less (178 and 188). `ItemViews.swift` (`BarItem`, `RowItem`) calls it instead of the literals `width - 120` and `width - 110`.

**Cut-off rule (D6).** A label is cut off when `measure(text) > budget - 1`, where `budget` already accounts for the chevron when the row has one for another reason. Two cases:

*   Row that gets a chevron regardless (a path row in Change 3): test against the chevron budget (bar 178, row 188). Boundary: width 177 is not cut off, 178 is (row: 187 and 188).
*   Row that gets a chevron only if cut off: test against the plain budget (bar 192, row 202). Boundary: 191 is not cut off, 192 is. If it is cut off, the chevron takes 14 pt and the label stays cut off (a label above 191 is above 177), so the two cases agree. Limit bars use the second case.

**Detail wrapping (M9).** Revealed text is wrapped by measured width, not by character count: `PanelModel.wrapMeasured(_ text: String, width: CGFloat, size: CGFloat, measure: TextMeasure) -> [String]` breaks at spaces and, for a word wider than the line, by character. Line width is 312 minus 8 pt padding. Detail text style is 11 pt, secondary colour, regular weight. Hook text is capped (Change 10). The existing `PanelModel.wrap` (46 characters) stays for notes only.

**Open rows.** `AppController.openRows: [String: Bool]` (row id to "may reveal in Finder", decided at click time). Passed into the model through `PanelContext`:

```swift
public struct PanelContext {
    public var open: [String: Bool] = [:]          // PR 0
    public var measure: TextMeasure = { _, _, _ in 0 }   // PR 0
    public var identities: Identities.Snapshot? = nil    // PR 6
    public var selectedDay: String? = nil                // PR 8
    public var hooks: [String: Hooks.Result] = [:]       // PR 10
    public var hooksExpanded: Set<String> = []           // PR 10
}
```

`buildPanel(... context: PanelContext = PanelContext())` keeps old calls compiling. A second entry point `PanelModel.buildPanelResult(...) -> (tabs: [Tab], rows: [String: RowInfo])` returns the ids of the rows that exist (`RowInfo { path: String? }`, the full path for reveal, nil if none); `buildPanel` is a wrapper returning `tabs`. So "ids the model reports as present" is the keys of `rows`, and the Finder path travels with the tabs instead of being parsed back out of an id.

*   Action `toggle_row:<id>`: `AppAction.toggleRow(id:)` parses it (split on the first colon only; the id may contain colons). Handled in `AppController` through a pure helper `OpenRows.toggle(_ open: inout [String: Bool], id:, path: String?, fileExists: (String) -> Bool)`: closes if open; else opens and stores `path.map(fileExists) ?? false`. The closure is injected so tests never touch disk; the app passes `FileManager.default.fileExists` with `~` expanded via `UsageStats.homeDirectory`.
*   Pruning: `renderPanel` drops open ids not in `rows` (`OpenRows.prune`).
*   Clearing: `openRows` is cleared in `PanelController.onTabChange` (and the panel redrawn with `renderPanel()` only when something was cleared, because `selectTab` swaps cached views without redrawing; `draw()` runs inside `selectTab` before `showTab`, so the callback must not re-enter: it schedules `renderPanel()` on the next run-loop turn). It is also cleared in the existing `onWillShow` hook, which runs before every open; no new close callback is added. Esc keeps closing the whole panel.
*   Multiple rows may be open at once (D5).

**Row ids** (stable; never saved):

*   `limit:<level id>`
*   `project:<full label>` (project labels are unique after folding, so no `#n`)
*   `session:<log path>` for Claude Code sessions (`Session.log`); `session:<tool>:<label>#<n>` for Codex and opencode, with `n` the position among identical labels in a list sorted by tokens then label. Sessions in the same folder have identical paths, so a swapped `n` changes nothing visible.
*   `hook:<tool>:<sha1 prefix (8 hex) of source path>:<event>:<n>`, with `n` the position in file order within that event and file (a stable hash instead of the path, so ids have no colons from paths).
*   `account:<digest>`

**Scroll.** `PanelController.draw()` records the content scroll offset of the selected tab before rebuilding and restores it after, when the tab key is unchanged. A toggle, a day click and the 15 s refresh therefore do not jump to the top. A real-build check records pass or fail (manual check 6).

**View keys.** `CardView` keeps keying items by position; safe because every render rebuilds all views and the only added `@State` is the chart's hover.

**Tests, PR 0:** see PR 0 in the plan.

### Change 9: milestone-only alerts (PR 1)

**Root cause (confirmed in code).** `alertsToSend` rebuilds `newAbove` from the levels present in the current pass only, and `AppState.checkAlerts` saves it as `alerts_above`. A level missing in one pass loses its keys and the next pass alerts again. The usual trigger is `fetchUsage` returning an empty `limits` list on any error (offline, Keychain not ready, expired sign-in); `claudeLimits` then falls back to the log-based "reached" levels (`Limits.reachedClaudeLimits`), which exist only at 100% and before their reset. A login-item start before the network is ready hits this every time. Secondary: a per-limit notification switch toggled off and on, a tool disabled, and fallback Opus/Sonnet ids that differ from fetched ids.

**Rules (decided).**

1.  Present and switched on: its reached thresholds become keys of the new `above` list. A key is dropped when the level is present and below that threshold (this includes a reset to 0%).
2.  Absent: an old key is **carried only when absence means "unknown"**. Absence means unknown for: (a) a tool that is disabled, (b) a level that is present but whose per-limit notification switch is off, (c) Claude Code while Percentages from Anthropic is on and the fetched list is empty (fetch failed or not yet done), (d) Codex when no `rate_limits` record exists. Absence means "gone" (keys dropped) for: a fallback level whose window ended (`reachedClaudeLimits` drops the level after its reset, which is what the old code relied on), a fetched level that vanished from a successful fetch (plan change), a Codex window no longer present in a record that exists, and Claude Code with Percentages from Anthropic switched off (the fallback list is then authoritative).
3.  Seeding happens **only on the process's first pass**, not per level. On that pass new keys are written to `above` and no message is sent. After it, any level crossing a threshold alerts, including a fallback level that first appears after launch (the case a per-level seed would have silenced).
4.  "Seeded" is a flag in `AppController` (`alertsSeeded`, memory only). It is set on the first `checkAlerts` call whether or not "Notify me" is on, so turning "Notify me" on later alerts normally (as 3.0.0 does).
5.  `reachedClaudeLimits` is fixed so fallback Opus and Sonnet levels carry kind `weekly_opus` / `weekly_sonnet` (new table `Limits.claudeLimitKinds`). Before the fix those levels had id `claude_code:weekly`; after, `claude_code:weekly_opus` and `claude_code:weekly_sonnet`, equal to the fetched ids. The id format is unchanged; only fallback Opus and Sonnet get a new id.
6.  No hysteresis; `fetchUsage` unchanged.

**New signatures.** The return type stays a 2-tuple so existing destructures compile.

```swift
// Limits.swift
public static func alertsToSend(_ levels: [Level], thresholds: [Int], windowsOn: [String],
                                above: [String], seeding: Bool = false,
                                unknownIDPrefixes: Set<String> = [],
                                now: Double? = nil) -> (messages: [String], above: [String])

// AppState+Changes.swift
public static func checkAlerts(_ state: inout JSONObject, now: Double, seeding: Bool = false)
    -> (messages: [String], changed: Bool)

// Limits.swift: the "unknown" prefixes, e.g. "claude_code:", derived from state by rules 2(a), 2(c), 2(d)
static func unknownIDPrefixes(_ state: JSONObject, now: Double) -> Set<String>
```

Loop: for each level whose window switch is on, compute keys; add to `newAbove`; send a message unless `seeding` or all its keys were already in `above`. Then, for each old key whose level id is not present-and-switched-on: keep it when the id is present with its switch off (2b) or its prefix is in `unknownIDPrefixes`; otherwise drop it. `AppController+Alerts.checkAlerts` computes `let seeding = !alertsSeeded; alertsSeeded = true` and passes it. Defaults keep every existing call compiling.

**Tests that must change (listed so PR 1 owns them).** `LimitsTests` `reachedClaudeLimits` equality (kinds added to expected Levels) and the fallback ids test; no destructure changes (return type unchanged). `AppStateChangesTests.reachedLimitAlertsOnceAndIsRemembered` stays valid unchanged (it never passes `seeding`). Text assertions are not touched here (PR 2 owns them).

**Risks kept.** A threshold crossed while the app was closed or during a failed-fetch gap is seeded silently and not announced. While a Claude fetch keeps failing, a reached limit whose key was carried does not alert again; it is dropped on the next successful fetch.

### Change 1: names (PR 2)

**One function.** `Limits.displayName(_ level: Level) -> String` (pure, in `Limits.swift`):

*   tool = `level.name`, else the tool name looked up from the id prefix, else the id prefix.
*   window text = `windowLabels[level.window]`, else `level.label`.
*   model suffix: if `kind` is non-nil, not equal to the window, and starts with `window + "_"`, take the rest, split on `_`, capitalise each word, join with a space. `weekly_opus` gives "Opus".
*   result `"Tool (Window)"` or `"Tool (Window, Suffix)"`. An unknown kind not shaped like the above is ignored. Codex levels have no kind: "Codex (Weekly)".
*   Never built from the saved `label`. The saved label and `Level.id` stay, so there is no migration.

**Panel.** In `PanelModel+Tabs.limitsTab`, every bar label is `displayName(level)` in both All AIs and single-tool views. The reset text leaves the label: `sub = "Resets \(formatReset)"` when `resetsAt` is non-nil and not 0, else `nil`. Value stays "80%" or "Reached". Row id for the chevron is `limit:<id>`.

**Notification.** `Limits.alertsToSend` builds `"\(displayName(level)) usage is at 80%."` plus the existing " Resets at 4:00 PM." / " Resets on Nov 20." Test pins "Codex (Monthly) usage is at 80%. Resets on Nov 20." (the old test used a 5-hour label; use a monthly level).

**Window naming.** "Monthly" is a rolling 30-day window (observed `window_minutes` 43200). Kept as the owner chose; explained in the FAQ.

**This PR owns the text rewrite**: every `"Codex: 5-hour usage is at ..."` / `"Claude Code: ..."` assertion in `LimitsTests` (about 15) and `AppStateChangesTests.reachedLimitAlertsOnceAndIsRemembered` (`hasPrefix("Claude Code: 5-hour usage...")`).

**Out of scope, seen:** note prefixes, switch labels ("5-hour limit"), test alert text.

### Change 7: FAQ card (PR 3)

*   New `Item.heading(String)` (semibold 12 pt, 18 high; also used by Changes 5 and 10). A card "FAQ" is appended to `settingsTab` (the Settings window scrolls when tall).
*   Each entry: `.heading(question)` then answer lines from `PanelModel.wrap(answer, width: noteWidth)` as `.note`. Content is a static list `PanelModel.faqEntries: [(question, answer)]`.
*   Labels cannot drift because the text is built from constants the UI also uses: `PanelLayout.trackingLabel = "Tracking"` (used by `PanelLayout.toolPicker`), `PanelModel.aiToolsTitle = "AI tools"` (used by `toolsCard` and the first-run text), `PanelModel.claudeUsageSwitchLabel = "Percentages from Anthropic"` (used by the inline General card in `settingsTab`; there is no `generalcard` function), `Providers.providerNames["anthropic"]`, `Tools.toolNames["claude_code"]`.
*   Five entries (checked against `Providers.providerView`, `Providers.modelPatterns`, `Accounts.keyHelp` and the README "OpenAI, DeepSeek, Kimi and other AI companies" and privacy sections):
    1.  "What is the \"Tracking\" menu?": It picks what the panel shows: one AI tool, one AI company, or "All AIs" (every tool turned on under "AI tools" in Settings, added together; company views are not added on top).
    2.  "What is the difference between \"Claude Code\" and \"Anthropic\"?": "Claude Code" is everything the Claude Code app logged on this Mac. "Anthropic", which you can turn on under "AI tools", is a company view: it counts every model whose name starts with `claude-` that any tracked tool ran on this Mac (Claude Code, Codex or opencode). They overlap and are never added together in "All AIs". There is no API key for Anthropic.
    3.  "What does \"Percentages from Anthropic\" do?": In Settings under General, shown when Claude Code is on. It asks Anthropic for Claude Code's plan limit percentages, using Claude Code's saved sign-in. It belongs to Claude Code, not to the "Anthropic" company view.
    4.  "What does \"Codex (Monthly)\" mean?": A rolling 30-day window, not a calendar month.
    5.  "Does my data leave this Mac?": Only what the README lists: the percentage request to Anthropic (on by default; turn it off with "Percentages from Anthropic"), optional API keys for OpenAI, DeepSeek and Kimi, the optional Leaderboard, and update checks when you click Check for Updates.
*   Entries added later in their own PRs: "What does \"Show only\" do?" (PR 6) and "What is the pace warning?" (PR 9).

### Change 2: cut-off names (PR 4)

Adds `Item.detail`, the shared chevron and the use of `toggleRow` (which PR 0 already added; this PR adds no new action).

*   `Item.detail(id: String, lines: [String], button: Item.Button?)`. Height: `detailPad (4) + 14 * lines.count + (button != nil ? 30 : 0)`. Lines are wrapped by measured width (PR 0). Style: 11 pt secondary.
*   In the model, for each limit bar (and each plain row that opts in; projects and sessions in Change 3): compute the cut-off per PR 0's rule. If cut off, set `extras.expandID` and `extras.tip` (the full label). If the id is in `context.open`, set `isOpen` and insert directly after the item `.detail(id:, lines: wrapMeasured(full label), button: nil)`.
*   View: one shared `ChevronLabel` in `Style.swift` replaces `LabelText` inside `BarItem` and `RowItem` when `expandID != nil`: the row is a button (whole row clickable), a `chevron.down` symbol (11 pt, secondary colour) rotates 180 degrees when open, `.help(tip)` gives the hover text, `.accessibilityLabel(tip)` plus an expanded/collapsed accessibility value. Click calls `onAction("toggle_row:<id>", .none)`. The label width is `labelBudget(kind:hasChevron: true)`.
*   Only `bar` and `row` get chevrons in this release. After Change 1 most names fit ("Claude Code (Weekly, Sonnet)" is about 28 characters, near the 192 pt budget), so the chevron is a fallback; verified by check 1.

### Change 3: Projects and Live rows, plus the home-folding fix (PR 5)

**Fold fix.** `UsageStats.foldSubfolders` folds `project` into any earlier project `p` where `project.hasPrefix(trim(p) + "/")`. With `p == "~"` the prefix is `"~/"`, so every `~/x` folds into `~`. With `p == "/"` the trimmed text is empty and the prefix is `"/"`, so every absolute path folds. Fix: a project is never a fold parent when its trimmed text is empty, or equals `"~"`, `"/"`, `UsageStats.homeDirectory` or `"Unknown"`. The textual prefix test stays (`~/a` and `/Users/x/a` still do not fold together; left alone).

**Names.** New pure `ProjectNames` (TrackerCore): `labels(for paths: [String]) -> [Entry]`, `Entry { name; greyTail: String?; fullName; path: String? }`.

*   `name` is the last path component (`"~/a/b"` gives `b`; `"/Volumes/x/y"` gives `y`); `"~"` gives `Home (~)`; `Unknown` and labels with no `/` (Gemini fallback slugs) stay as they are with `path == nil`.
*   Over the whole visible list, group by `name`. For a group of more than one different path, add parents one at a time (nearest first) until each is unique; the added part is `greyTail`, shown as `name` + ` · ` + parents joined with " / " (`assets · FPS Game`). Identical paths are not a collision.
*   `tip`/accessibility: `name in parent` plus the full path.
*   Recomputed on every render from the visible list (a label can change when a same-name folder appears; accepted).

**Expansion line.** One `.detail` per row. Lines: the full name if the name is cut off (measured), then the full path (`~/...` as stored, wrapped by measure), then, only when allowed, a `Show in Finder` button (`reveal:<id>`).

**When the row is clickable.** Rows with a real path (`path != nil`: label starts with `~/`, equals `~`, or starts with `/`) always get a chevron and use the chevron budget (PR 0); other rows ("Unknown", slugs) get one only if cut off.

**Finder button.** `openRows[id]` is set at click time by `OpenRows.toggle` (PR 0) using `rows[id].path` from `buildPanelResult`, so no id parsing is needed and no path table is stored. The model only reads the Bool. The `reveal:<id>` handler re-checks existence; if the folder is gone it closes the row; otherwise it **closes the panel first**, then calls `NSWorkspace.activateFileViewerSelecting` (as `.openSettings` already does). Never offered on the Leaderboard tab.

**Live tab.** `runningToolSessions` gets `cwd` on Codex and opencode sessions. The model feeds `session.cwd` (converted to `~/` form via `UsageStats.projectLabel`) into `ProjectNames`.

**README:** full paths appear on screen only; nothing leaves the Mac. Gemini sentence updated.

### Change 4: accounts, view and "Show only" filter (PR 6)

**Word.** Code: `Identities`, `AccountScope`, `AppController+Identities.swift` (not the existing `AppController+Accounts.swift`). UI: card "Accounts", filter "Show only", help "Does not change which account Codex uses."

**Per-file account.** `readCodex` records `account = digest(session_meta.payload.creator_account_id)` or `null` per file, with `"v": 2` (`CodexSource.fileVersion = 2`). The re-read rule changes from `saved["limits"] != nil` to `(saved["v"] as Int ?? 1) >= CodexSource.fileVersion`; a re-read replaces the file's own entry, so nothing is counted twice. Digest: first 12 hex characters of SHA-256 of the id (CryptoKit). The raw id is never written to `state.json`. The last four characters are shown as `····ab12` for display only; they are not guaranteed unique. Wording everywhere: the account that **created** a session (`creator_account_id`); a resumed session may have been run by another account.

**Signed-in readers (decided; see D40).**

*   `Identities.codexSignedIn(authFile:) -> CodexSignIn` reads `~/.codex/auth.json` into memory, keeps `tokens.account_id` (digest it) and `auth_mode`, drops everything else at once, and never logs the content or echoes it in errors. Results: `.account(digest)`, `.apiKey` (no `tokens.account_id` and a non-null `OPENAI_API_KEY`; shown as "Signed in with an API key"), `.none` (missing file; "Not signed in"), `.unreadable` ("Couldn't read the Codex sign-in"). The result is cached in `AppController` by file modification time and size, so the file is not re-read every 15 s render. This file read is the largest new privacy surface of 3.1; it is kept because "who is signed in" is one of the four decided capabilities, and a log-derived guess (the newest session's `creator_account_id`) would show the wrong account after a switch until the next session. The README states it exactly.
*   `Identities.claudeSignedIn(file:) -> (email, displayName)?` reads `~/.claude.json` (95 KB here; skipped above 20 MB), plucks `oauthAccount.emailAddress` and `displayName`, caches by modification time in `AppController`, never saved or synced. Screen only.

**Account list.** A pure function over `sources.codex.files`: identities sorted by earliest day in their files (ties by digest), named "Account 1", "Account 2"; plus "Unattributed" (files with `account == null`). Per identity: lifetime tokens, first and last day.

**Accounts card (Limits tab, below Plan limits).**

| Tool | Signed in | Tokens per account | Limits per account |
| --- | --- | --- | --- |
| Codex | "Account n ····ab12 (signed in)" from the auth digest; "Not signed in" or "Signed in with an API key" per above | rows per identity plus Unattributed (note "Older sessions don't record the account.") | Signed-in account: the newest `limits` among files with that digest (`CodexSource.codexLatest(_, account:)`), falling back to the global newest only when the signed-in digest is unknown. Each other identity: its newest file's `limits` with sub "Last seen Nov 4, 3:10 PM". Windows that have reset show 0% as `codexLimits` already does. |
| Claude Code | email or display name | "Past usage can't be split by account." | Signed-in account only (the API returns only that) |
| Gemini CLI | "Not available for Gemini CLI." | same | same |
| opencode | "Not available for opencode." | same | same |

`CodexSource.codexLatest(_ sourceState: JSONObject, account: String? = nil) -> (at: String, rateLimits: JSONObject)?` is created here (nil account means all files). `codexRateLimits` becomes a wrapper over it. Change 8 only consumes it.

**Show only (the filter).**

*   `state["account_scope"]`: null (all) or a digest, persisted like `selected_tool`. Invalid, vanished, or fewer than two identities at launch or render reads as all and is cleared in state (a persisted scope never outlives its UI).
*   A second popup "Show only" under "Tracking", shown only when two or more identities exist. Options: "All accounts", then each identity. Action `select_account` (index).
*   `AccountScope` is `.all | .only(digest)`. `CodexSource.codexDaily/codexTotal` take a scope and filter files by `account` (Unattributed files appear only under All). `Tools.toolView(state, key, scope)`, `Tools.combinedView(state, enabled:, scope:)` and `Providers.providerView(state, key, scope:)` take it; `AppState.currentView` passes it from state (`AppController.updateTitle` and `renderPanel` call `currentView`, so the menu bar count follows).

**Scope semantics (decided; D36).** With a scope active:

*   Codex tool view: that account's data only. Header subtitle: " · Account 2 only".
*   **All AIs, company views and the menu bar count: only the scoped Codex data.** Tools that cannot be split (Claude Code, Gemini CLI, opencode) are excluded from those views, and the view lists them: a note at the top "Not included (not split by account): Claude Code, opencode". The header reads "Account 2 only" because the numbers really are Account 2's.
*   Claude Code, Gemini CLI and opencode single-tool views: unfiltered (all their usage), header unchanged (no "Account 2 only"), with the note "Not split by account".
*   `Tools.toolChoices` keeps using the unscoped view to decide which tools exist. Per-tool existence in Settings is not scoped.
*   Plan bars on the Limits tab: Codex shows the scoped account's last-seen limits; `Limits.planLevels` (alerts) reads state directly and is **not** scoped. So there are two deliberate paths: panels show the chosen account, alerts and the pace alert follow the signed-in account. The Leaderboard push (`leaderboardPayload`) is not scoped, and `total_tokens` is `state["grand_total"]`, a Claude Code figure, so scope cannot affect it; a test pins this.
*   `PanelLayout.contentTop(hasToolPicker:hasScopePicker: Bool = false)` adds `toolPickerHeight` for the second popup; `PanelChromeView` draws the second picker; `PanelController.render` passes both.

### Change 6: model effort (PR 7)

*   **Data.** New per-day map in the Codex and Claude Code buckets: `efforts: {model: {effort: tokens}}`, `tokens` being the sum of all categories for the responses at that effort. Gemini and opencode buckets have none. The model key and `models`, `projects`, pricing and `recorded_cost` are untouched.
*   **Normalising.** Lowercase, trim; accept only `[a-z0-9_-]{1,12}`; otherwise treat as absent.
*   **Codex.** `CodexSource.fileVersion` becomes 3 (a second one-time re-read; see D10). In `readCodex`, a running `effort` is kept like `model`: on each `turn_context`, `effort = nonEmpty(payload.effort) ?? nonEmpty(payload.collaboration_mode.settings.reasoning_effort) ?? effort`. Each token record adds to `efforts[model][effort]` when `effort != nil`, so a mid-session change is counted per turn. `addUsage` gains an optional `effort` argument.
*   **Claude Code.** `recordEntry` reads top-level `effort`, falling back to `perTurnEffort` (the two differ on 245 of 21165 entries here; which one the Claude Code UI shows is not known, so `effort` is preferred as the primary field and both cases are tested). One-time backfill `TokenMath.backfillEfforts`, guarded by `state["efforts_backfilled"]`: for each tracked file it reads 0 up to its saved offset with the same entry parser into a scratch daily and copies only the `efforts` maps into buckets that have none, then sets the flag. **Run order in `AppController.start`:** `backfillDaily`, `backfillLimits`, `backfillEfforts`, then `scan()`. Files already deleted have no effort; their tokens show as a plain model row.
*   **Merging and filtering.** `UsageStats.combineBuckets` (used by `mergeDaily` and `mergeMaxDaily`) carries `efforts` (nested sum for `.sum`, nested max for `.max`). `UsageStats.filterDaily` (used by `Providers.providerView`) rebuilds buckets from scratch today and would drop `efforts`; it keeps `efforts` for the models it keeps.
*   **Reading.** `UsageStats.effortsInRange(daily, start, end) -> [String: [String: Int]]` and `effortsAllTime(daily)`, next to `modelsInRange`. `PanelModel.PanelData` gets `todayEfforts` and `lifetimeEfforts`. `modelsCard(_ title:, _ models:, efforts:)` (new parameter, default `[:]`) builds the rows.
*   **Display.** Owner format: `modelDisplayName(model)` + ` (` + effort uppercased + `)`, e.g. `gpt-5.6-luna (HIGH)`, `Opus 5.5 (XHIGH)`. For each model in the range: if it has efforts, one row per effort sorted by tokens; each effort amount is **clamped** so the running sum never exceeds the model's total (merging with `.max` or a backfill into incomplete buckets can make the raw sum larger); a plain model row holds `model total - sum` and shows only when greater than 0. No efforts: plain row as today. Rows sum to the model total. Never "unknown".
*   **Day breakdown (Change 5).** `UsageStats.dayBreakdown` returns models as `[DayModelRow]` (`model`, `effort: String?`, `tokens`) so effort rows exist there too.
*   **Cost tab and other totals** use `models`, so are unchanged.
*   **Backup.** In `AppController.start`, after `loadState` succeeds and **before** `applyLaunchDefaults`, and not when `freshInstall`: copy `state.json` to `state.json.pre-3.1.bak` if that file does not exist (existence is the marker). Add the file name to `.gitignore`. If the copy fails, log the error and continue (the migrations are additive).

### Change 5: interactive graph (PR 8)

*   **Data.** `Item.chart(values:caption:)` becomes `Item.chart(points: [Item.ChartPoint], caption: String, selected: String?, action: String)`. `ChartPoint { day: String (ISO), label: String, tokens: Int, partial: Bool }`. `label` is "Nov 7th": month abbreviation plus the day with an ordinal suffix (1st, 2nd, 3rd, otherwise th; 11, 12, 13 are th). `partial` is true for today. Days are local time (`Day`).
*   **Range.** `state["chart_days"]` is 7, 14 or 30, default 14, anything else reads as 14 through `PanelModel.chartDays(from:)`. The control is `.segmented(label: nil, options: ["7 days", "14 days", "30 days"], selected: index, action: "chart_range")` in the chart card above the chart; the app gets `chart_range:<index>` (0, 1, 2 maps to 7, 14, 30, other indexes clamp to 14), parsed like `title_mode`. The card title is "Last N days".
*   **Series.** Existing `UsageStats.dailySeries(daily, today, days)` (missing days are 0).
*   **Hover (view only).** `ChartItem` adds `.onContinuousHover`; the nearest point index becomes a local `@State` shown as a vertical rule plus a small label "Nov 7th · 1.2M" (today: "Nov 9th (today, so far)"). It resets on every redraw (every 15 s and after any action); accepted, and listed in the manual checks.
*   **Click.** `SpatialTapGesture` finds the nearest point and calls `onAction("chart_day:<iso>")`. `AppController.selectedChartDay: String?` toggles (same day again clears) and is passed in `PanelContext.selectedDay`. Cleared in `onTabChange` (with a redraw if it was set), in `onWillShow`, on range change, and when the day leaves the range. The selected point is drawn with a filled dot and an accent rule.
*   **Accessibility.** The chart is one element with label "Tokens per day" and value "Peak 1.2M". Its adjustable increment/decrement calls `onAction("chart_day:<iso of the neighbouring day>")` starting from the selected day (or the last point when none is selected).
*   **Breakdown card** (after the chart card when a day is selected): title is the long date; a total row; "Models" heading with up to `breakdownShown = 5` bars (effort rows per Change 6) and one "N more" row for the rest; "Projects" heading with up to 5 bars (folder names per Change 3) and one "N more" row; a "Close" button (`chart_day:<iso>` again). A day with no `models` shows "No detail for this day". `model_projects` is not used (some buckets lack it). Heights are bounded at 2 x 6 bars plus headings.
*   **Pure function.** `UsageStats.dayBreakdown(daily, day) -> (total, models: [DayModelRow], projects: [NamedTotal])`. The view's `daily` is already scoped (Change 4).
*   **Scroll.** The panel scrolls past its height cap; PR 0 keeps the offset across redraws.

### Change 8: pace alert (PR 9)

*   **Setting.** `state["pace_alerts"]`, default false. A `.switch` in the Notifications card after "When usage reaches": "Warn me if I'm on pace to run out". Effective only when "Notify me" is on and the level's per-limit notification switch is on.
*   **Unit.** Percent used against the elapsed share of the window. `Level` gains `windowSeconds: Double? = nil` and `sampledAt: Double? = nil` (defaults keep `Equatable` tests and every constructor call compiling; tests that compare `codexLimits` or fetched-level output with `Level` equality are updated in this PR). Sources:
    *   Codex: `Limits.codexLimits(_ rateLimits: JSONObject?, now: Double, sampledAt: Double? = nil)`; `planLevels` passes `Limits.parseISO(latest.at)` from `CodexSource.codexLatest` (created in PR 6). `windowSeconds` is `window_minutes * 60`. `Limits.parseISO(_ text: String) -> Double?` uses `ISO8601DateFormatter` with fractional seconds (the logs carry milliseconds and `Z`).
    *   Claude, fetched: `windowSeconds` 18000 for five_hour and 604800 for weekly (there is no Claude monthly window; the old 2592000 constant is dropped); `sampledAt` is `claude_usage.fetched_at`.
    *   Fallback (log-based) Claude levels have nil `sampledAt`, so **nil `sampledAt` means no pace alert**.
*   **Projection.** `Limits.paceProjection(level, now) -> Projection?`: `elapsed = windowSeconds - (resetsAt - now)`, `fraction = elapsed / windowSeconds`, `projected = percent / fraction`, `runOutAt = now - elapsed + elapsed * 100 / percent`.
*   **Guards (constants in `Limits`; all must hold).**

| Guard | Value |
| --- | --- |
| `resetsAt` exists and is later than now | required |
| Level is not `reached` | required |
| Percent | `5 <= percent < 100` |
| Elapsed fraction | `>= 0.20` |
| Time left until reset | `>= 10 minutes` |
| Projected use at reset | `>= 110%` |
| Sample age | `<= 20 minutes` (Codex), `<= 15 minutes` (Claude) |

    Codex samples exist only while Codex runs, so a Codex pace alert can fire only during or shortly after Codex use; the FAQ says so.
*   **Dedup.** `state["pace_alerted"]: [String]` of `pace:<level id>@<n>` with `n = Int(resetsAt / 600)` (the reset time rounded to 10 minutes, because Claude's `resets_at` is re-parsed from the API on every fetch and a one-second jitter must not mint a new key). A key is recorded only when a pace sentence was actually delivered (in its own message or appended to a threshold message). Keys whose reset time has passed are dropped each pass. Own key space; `alerts_above` is untouched.
*   **Same pass as a threshold alert.** The pace sentence is appended to the threshold message and the key is recorded, so the single pace warning of the window is not lost.
*   **Launch and switch.** Keys persist, so no seeding: a level already on pace at launch, or when the switch is turned on, alerts once if the sample is fresh. This is intended.
*   **Message.** "At your current pace, Codex (Weekly) may run out around Thu 4:15 PM, before it resets on Fri. This is an estimate." Same day: "...around 4:15 PM, before it resets at 6:00 PM." Run-out time rounded to the nearest 15 minutes; weekday abbreviations from a fixed table with `Calendar(identifier: .gregorian)` in the local time zone.
*   **Wiring.** `AppState.checkAlerts` runs the threshold pass, then the pace pass; both return messages. The pace pass is skipped entirely when `pace_alerts` is off.
*   **FAQ entry (written here):** "What is the pace warning?": An optional warning, off by default (Settings, Notifications). If you have used a bigger share of a limit than the share of its window that has passed, it estimates when the limit would run out and tells you once per window. It is an estimate. For Codex it can only appear while Codex is in use, because Codex records its limits only then.

### Change 10: Hooks tab (PR 10)

*   **Pure module `Hooks` (TrackerCore).** `Hooks.Entry { event, matcher: String?, type, program, arguments, statusMessage, timeout, source: Source { path, scopeLabel } }`; `Hooks.Result { entries: [Entry], problems: [String], notRead: [String] }` per tool. File reads are injected (a closure), so tests use fixtures.
*   **Parser.** New `Hooks.parse(_ json: Any?, source:) -> [Entry]` with events sorted by name and groups and hooks in file order (arrays keep order). `Plugins.hookDetails` and its tuple return stay **untouched** (`Plugins.profile` and `PluginsTests` keep passing); the new parser is separate. A plugin manifest `hooks` that is a path string is resolved with the same rule `Plugins` uses (absolute, or relative to the plugin root).
*   **Adapters.**
    *   Claude Code: `~/.claude/settings.json` and `~/.claude/settings.local.json`; managed settings `/Library/Application Support/ClaudeCode/managed-settings.json` if present; each enabled plugin's `hooks/hooks.json` and manifest `hooks`; and `.claude/settings.json` and `settings.local.json` in the folders of running Claude Code sessions (`Session.cwd`). Sources are de-duplicated by resolved path; a session folder of `~` or `/` is skipped (it would repeat the user file). `disableAllHooks: true` in a file adds a line "Hooks in <file> are turned off by disableAllHooks".
    *   Codex: reads `~/.codex/hooks.json` with the same parser **only if it exists**. The tab says exactly what was read: "Read: ~/.codex/hooks.json (not found). Not read: hooks in config.toml and in plugins." The format is inferred from plugin-shipped `.codex/hooks.json` files; the user-level location is unverified (Facts), which is why the wording says "only this file is read".
    *   Gemini CLI: "Not available: Gemini CLI hooks aren't read yet." opencode: "opencode uses JavaScript plugins, not shell commands. Not shown."
    *   Each tool card ends with a list of not-read sources, so an empty list never reads as "no hooks exist".
*   **Types.** `type: "command"` is the normal case. Any other `type` (such as `prompt`, `agent`, `http`) shows as a row whose program is the type name and whose reveal says "Type: <type>. Content not shown."
*   **Program name.** Take the command text; skip leading `NAME=value` assignments (quote-aware tokenizer for leading tokens only); the first remaining token's last path component is the program. `$CLAUDE_PLUGIN_ROOT/hooks/x.sh` gives `x.sh`. For interpreters (`node`, `python`, `python3`, `bash`, `sh`, `zsh`, `uv`, `npx`, `bun`, `deno`, `ruby`, `env`) the program is the interpreter plus the basename of the next token that does not start with `-` (`bash x.sh`). Everything after is `arguments` (in memory; shown only when the row is open).
*   **Redaction (revealed text only, best effort).** Applied in this order:
    1.  `NAME=value` where NAME contains KEY, TOKEN, SECRET, PASSWORD, PASSWD, AUTH or CREDENTIAL (quoted or not) gives `NAME=•••`.
    2.  `Authorization:` headers of any scheme (`Bearer`, `Basic`, `token`) and `Cookie:`/`Set-Cookie:` values give the header name and `•••`; `-H`/`--header` values containing a secret-looking name are masked the same way.
    3.  `--token`, `--key`, `--api-key`, `--secret`, `--password`, `--pass`, `-p`, `--auth`, followed by `=` or a space then a value (quoted or not) give the flag and `•••`.
    4.  `-u user:pass` and `--user user:pass` give the flag and `•••`.
    5.  URL userinfo `://user:pass@` gives `://•••@`.
    6.  Any run of 32 or more `[A-Za-z0-9_-]` characters, or any token starting `sk-`, `ghp_`, `xox`, gives `•••`.
    Settings `env` blocks are never read or shown. The revealed arguments are cut at 400 characters with an ellipsis and shown on at most 8 lines (then "…"). Examples in tests: `API_KEY="abc" run.sh`, `curl -H "Authorization: Basic Zm9v" ...`, `tool -u me:hunter2`, `--pass hunter2`. A screenshot of a revealed row can still leak anything the patterns miss (Risks).
*   **Layout.** A tab "Hooks" (key `hooks`, short "Hooks", symbol `link`) placed **after Live and before Leaderboard**, built only for tool views and All AIs, never for provider views (the guard is `Providers.providerNames[view.key] == nil`, the same as Live). One card per tool; inside, `.heading(event)` then rows: label = program name, value = matcher (or "all"); a chevron row opens a `.detail` with the wrapped redacted command, "Defined in: <path>" and a `Show in Finder` button for the file (existence checked at click, closing the panel first, as in Change 3). A line at the top: "Commands your AI tools run automatically at set moments, such as when a session starts. Read-only." and a note: "The Plugins list on the Live tab shows what ran; this shows what is set up." Cap 8 entries per tool then "Show more" (`hooks_expand:<tool key>`); `AppController.hooksExpanded: Set<String>` of tool keys.
*   **Errors per file.** Missing: not listed (listed under "not read" for the tool's primary file); unreadable or invalid JSON: "Couldn't read ~/.claude/settings.json".
*   **Reading time.** Live at render, only when the Hooks tab exists in the view (about 10 small files every 15 s, only while the panel is open); no `state.json` keys. Ids use a hash of the source path (PR 0), so they survive re-reads.
*   **Tab bar (decided).** Captions are already 9 pt. With nine tabs the slot is `336 / 9 = 37.3` pt. Rule: a caption fails when `measure(short, 9, semibold) > slot - 4`. `PanelLayout.captions(tabs, measure) -> [String]` returns each tab's `short`. When the tab count is 9, a failing caption is replaced by its entry in the fixed table `PanelLayout.compactCaptions = ["Projects": "Folders"]`; a failing caption with no entry is left as is. The function is pure and tested with a stub measure; there is no Settings fallback (dropped, D26). "Hooks" is shorter than "Projects", so only "Projects" is expected to be replaced.

--------------------------------------------------------------------------------

### Data and state shape changes

All additive; 3.0.0 ignores unknown keys because `state.json` is untyped JSON and 3.0.0 writes the whole object back.

| Key / field | Where | Added by | Default / reader rule |
| --- | --- | --- | --- |
| `sources.codex.files[path].v` | Codex per-file entry | PR 6 (v 2), PR 7 (v 3) | Missing reads as 1; re-read when below `fileVersion` |
| `sources.codex.files[path].account` | same | PR 6 | 12-hex digest or null |
| `daily[day].efforts` | Codex and Claude Code buckets only | PR 7 | Missing reads as none |
| `efforts_backfilled` | root | PR 7 | false; set true after backfill |
| `account_scope` | root | PR 6 | null (all); cleared if invalid or fewer than two identities |
| `chart_days` | root | PR 8 | 14; invalid reads as 14 |
| `pace_alerts` | root | PR 9 | false |
| `pace_alerted` | root | PR 9 | `[]` |

All root keys get a line in `applyLaunchDefaults`; every reader accepts the key missing or wrong-typed. `alerts_above` keeps its format. Saved labels, `Level.id`, `claude_usage` and `file_offsets` do not change. Not saved at all: open rows, selected day, hooks reveal, signed-in email, `alertsSeeded`, the digest cache.

**Migration.** First 3.1.0 launch: copy `state.json` to `state.json.pre-3.1.bak` (once, not on a fresh install, before defaults); `backfillEfforts` runs once; Codex files are re-read once (straight to `v` 3 when PR 6 and PR 7 ship together; stepwise if tested between) and replace their own contribution so nothing is counted twice; defaults fill the new keys. If a backup or backfill fails the error is logged and the app continues (all changes are additive); the failure is recorded in Risks.

**Rollback to 3.0.0.** Safe for the app: unknown keys survive. In 3.0.0, a Codex file that changes is re-read and its entry rewritten without `v`, `account` and efforts; going forward to 3.1.0 again re-reads such entries because `v` is missing, so data returns wherever the log still exists. Claude `efforts` survive a rollback but do not grow during it; the gap shows as plain model rows. Entries for deleted Codex logs keep their data. The backup file is the last resort. Release notes say this. `efforts` adds roughly one small map per model per day (a few hundred bytes a day).

### Privacy review

The README privacy section (headed "By default it never connects ...", and its list of what the app touches) promises: only token counts, model, time and project folder are read; prompts and code are skipped; opencode's account or credential tables are never touched; three exceptions (Anthropic percentages, API keys, Leaderboard) plus update checks. It already discloses `~/.claude/settings.json`, an open project's `.claude/settings.json` / `settings.local.json`, `installed_plugins.json` and each enabled plugin's folder. What 3.1.0 newly reads or shows, and the README edit in the PR that introduces it:

| New | Read from | Kept | README edited in |
| --- | --- | --- | --- |
| Full folder paths | already in `state.json`; now shown | unchanged | PR 5 |
| Codex account digest | `session_meta.creator_account_id` | Digest only, per file | PR 6 |
| Codex signed-in account | `~/.codex/auth.json`: the whole file is read into memory, only `tokens.account_id` and `auth_mode` are kept, cached by mtime and size | Digest in memory | PR 6 |
| Claude signed-in account | `~/.claude.json`, `oauthAccount` email and display name | Memory only, shown on screen | PR 6 |
| Effort | `turn_context` (Codex), assistant `effort` (Claude) | Counts per model and effort in `state.json` | PR 7 |
| Hook configuration (new reads only) | `~/.claude/settings.local.json`, managed settings, `~/.codex/hooks.json` (the user settings, plugin and project files are already disclosed) | Nothing stored | PR 10 |

The README sentence "never touches ... credential tables" is reworded **in PR 6**, the PR that first reads a credential file, to say exactly which fields of which files are read; the final privacy rewrite in PR 11 is a consistency check. Guarantees and where each is tested:

1.  The serialised `state.json` after a scan of fixtures with sentinel values contains none of: `id_token`, `access_token`, `refresh_token` values, the raw account id, the email. Tested in **PR 6** (where the digest first lands), re-asserted in PR 7.
2.  The Gist payload built from that state has exactly the four keys `name`, `total_tokens`, `yesterday_tokens`, `updated_at` (`AppState.leaderboardPayload`) and no sentinel. Tested in PR 6.
3.  No hook text is in state (PR 10).
4.  Parse errors never echo file content; no `log(...)` call interpolates tokens, ids, emails or hook commands (code-review item in every PR that reads those files).

### Error and empty states

| Situation | Shown |
| --- | --- |
| Level at 0% with no reset time | No second line |
| Label fits | No chevron |
| Open row disappears on refresh | Id pruned; row gone |
| Folder missing at click | Button not shown; handler re-checks and closes row |
| Row with no real path | No chevron unless the name is cut off |
| No Codex ids in logs | "No account ids in Codex logs yet." |
| One identity | No "Show only" popup; persisted scope cleared |
| `auth.json` missing / unreadable / API key mode | "Not signed in" / "Couldn't read the Codex sign-in" / "Signed in with an API key" |
| `~/.claude.json` missing, no `oauthAccount`, or over 20 MB | "Not signed in" / "Not available" |
| Scoped account vanished | Reads as All; cleared |
| Scope active in All AIs | Header "Account 2 only"; note listing excluded tools |
| Graph day without data | Zero point; breakdown says "No detail for this day" |
| Day has models but no projects | Only the models list |
| Effort absent | Plain model name |
| FAQ | Static; no empty state |
| Pace: stale sample, no sample time, no reset time, reached, fast reset | No alert |
| Hooks file missing / invalid | Listed as not read / "Couldn't read <path>" |
| Hooks for Gemini, opencode | "Not available" with reason |
| Hooks count over 8 | "Show more" |

### Checks that need a real build (record result in each PR)

| # | Check | Pass | Fallback if it fails |
| --- | --- | --- | --- |
| 1 | Longest limit names versus the 192 pt budget with `TextMeasure.live` | A name wider than 192 pt shows a chevron and opens; one at or under 191 pt has none | None needed (the chevron is the mechanism); adjust the 1 pt margin only if a visible clip appears |
| 2 | Hover and click in the chart inside the panel window | Hover label shows and a click toggles the day | Attach an `NSTrackingArea` through an `NSViewRepresentable` for hover |
| 3 | Nine-tab captions fit (Claude Code view, Leaderboard on) | No caption is clipped at 37 pt slots | Already specified: the `compactCaptions` table |
| 4 | Show in Finder from a panel that closes on outside click | Finder opens with the item selected after the panel closes | None; the panel is closed first by design |
| 5 | Days 15 to 30 of the graph with real history | 30-day sum equals the sum of the daily values; **cannot run on this Mac** (12 days of history), so it runs on fixtures and is recorded "not run on real history" | None |

Manual list, each recorded pass or fail: (6) scroll offset kept across a toggle, a day click and the 15 s refresh on a tall tab; (7) open a row, switch tab, switch back: closed; (8) chart hover label resets on redraw (expected); (9) launch with the network off sends no alert.

### Test plans (per PR; named tests are listed in the plan)

Each PR's test names are in the Detailed Implementation Plan. Cross-cutting rules: every new pure function has happy, edge and empty tests; no numeric coverage target; the whole suite stays green after each PR.

--------------------------------------------------------------------------------

## Alternatives Considered

Owner decisions are cited by Decision Log id; the trade-off column states what the alternative would cost.

### Alternative A: Hover tooltip only, no click line (Change 2)
*   **Pros**: No new item or state.
*   **Cons**: Tooltips do not work for keyboard or touch and cannot show a multi-line path; the owner asked for a click behaviour (D4).
*   **Reason for Rejection**: Does not meet the click requirement. The tooltip is kept as an addition.

### Alternative B: Popover or overlay for the full text (Change 2)
*   **Pros**: Full text without moving rows.
*   **Cons**: Card and hosting frames clip it; it attaches to a view that `draw()` destroys; outside-click handling becomes the app's job.
*   **Reason for Rejection**: Inline expansion reuses the height arithmetic and survives redraws.

### Alternative C: `@State` in each row; open rows keyed by index or label text (Changes 2, 3, 5, 10)
*   **Pros**: No state in `AppController`.
*   **Cons**: The panel rebuilds every view on each render, so `@State` is lost; positions shift and labels change between renders.
*   **Reason for Rejection**: State lives in `AppController` with stable ids (D5).

### Alternative D: `GeometryReader`, hidden twin text or `ViewThatFits` to detect truncation; a character budget in the model (Change 2)
*   **Pros**: Simple; no measuring code.
*   **Cons**: The view-based options are flaky and cannot report a height to `PanelLayout` before drawing. A character budget disagrees with the real font (wide glyphs overflow).
*   **Reason for Rejection**: An injected `measure` function gives the model a real answer while `TrackerCore` stays pure (D6). The same measure wraps detail text.

### Alternative E: Two-line label plus tooltip instead of a chevron (Change 2)
*   **Pros**: Shows more text with no click.
*   **Cons**: Row heights are fixed per kind (bar 36, row 22); two-line labels change every height and the 15 s redraw would reflow the card as text changes.
*   **Reason for Rejection**: The owner wants the chevron and click (D4).

### Alternative F: Change the stored label constants only (Change 1)
*   **Pros**: Smallest diff.
*   **Cons**: Saved labels linger in `state.json`; after a rollback an old build shows new text; it cannot add the model suffix.
*   **Reason for Rejection**: A pure `displayName` needs no migration (D1). Dropping the tool name in single views and keeping "resets ..." in the label were rejected with layout B (owner decision, D2).

### Alternative G: Names and chevron in one PR (Changes 1, 2)
*   **Pros**: One review.
*   **Cons**: String work and a new interaction carry different risk; a bug in one blocks the other.
*   **Reason for Rejection**: One PR per change is an owner rule (D29).

### Alternative H: Check folder existence in the model or cache it (Change 3)
*   **Pros**: Button state is known at render.
*   **Cons**: File access in a pure model makes tests touch disk and goes stale on redraw.
*   **Reason for Rejection**: The Bool is decided at click time through an injected closure (D5).

### Alternative H2: Fold home projects but label them (Change 3)
*   **Pros**: No logic change.
*   **Cons**: Hides real project rows (the reported bug).
*   **Reason for Rejection**: The fold-parent guard fixes the cause (D30).

### Alternative I: Infer the Claude account from `~/.claude.json` at scan time and apply it to history (Change 4)
*   **Pros**: Gives Claude Code accounts.
*   **Cons**: Mislabels every earlier session after any account switch.
*   **Reason for Rejection**: Claude logs carry no account; Claude is shown as not split (D9).

### Alternative J: Add an account level to every per-day bucket (Change 4)
*   **Pros**: Works for every tool in principle.
*   **Cons**: Re-keys all data, grows `state.json`, touches every query; Claude logs carry no account.
*   **Reason for Rejection**: A per-file account for Codex gives the same result for data that can be split.

### Alternative K: Name the filter "Switch" (Change 4)
*   **Pros**: Short.
*   **Cons**: Reads as changing Codex's sign-in, which the app never does.
*   **Reason for Rejection**: "Show only" with the help text (owner decision, D11).

### Alternative K2: Show raw account ids; decode the id_token email by default (Change 4)
*   **Pros**: No digest code; real emails.
*   **Cons**: Raw ids are unreadable; decoding the JWT is a new credential read and puts an email in memory for every file.
*   **Reason for Rejection**: Digest plus "Account n" (D9).

### Alternative L: Store the raw Codex account id in per-file entries (Change 4)
*   **Pros**: Exact matching.
*   **Cons**: Puts a stable account identifier on disk and in backups.
*   **Reason for Rejection**: A 12-hex digest groups and matches the signed-in id equally well (D9).

### Alternative L2: Derive "signed in" from the newest session's `creator_account_id` instead of reading `auth.json` (Change 4)
*   **Pros**: No credential file read.
*   **Cons**: Shows the wrong account after a switch until a new session exists, and cannot show an API-key sign-in; "who is signed in" is one of the four decided capabilities.
*   **Reason for Rejection**: Kept the `auth.json` read with mitigations (D40).

### Alternative M: Swift Charts with `chartOverlay` for hover (Change 5)
*   **Pros**: Built-in axes and selection.
*   **Cons**: A new framework for a 14-point line; hover inside the status panel needs checking anyway; the existing `Canvas` chart would be rewritten.
*   **Reason for Rejection**: `Canvas` plus `onContinuousHover` and `SpatialTapGesture` is enough (D17).

### Alternative N: Fold effort into the model key (Change 6)
*   **Pros**: One field, no new map.
*   **Cons**: `Pricing.priceFor` matches `model == key` or `hasPrefix(key + "-")`; a key such as `gpt-5.6-luna (MEDIUM)` breaks pricing, grouping, the leaderboard and merging.
*   **Reason for Rejection**: A separate additive `efforts` map keeps the key (D15).

### Alternative O: Lowercase grey effort tag, the brief's default (Change 6)
*   **Pros**: Quieter row.
*   **Cons**: Differs from what the owner wrote.
*   **Reason for Rejection**: Owner decision: `model (HIGH)` (D16).

### Alternative P: Pace from tokens per hour, or a trailing-hour rate with stored samples (Change 8)
*   **Pros**: Reacts to a sudden burst.
*   **Cons**: Limits are percentages; no hourly history exists; samples need a new store and are noisy.
*   **Reason for Rejection**: Elapsed-fraction projection needs no history (D21).

### Alternative Q1: Reuse `alerts_above` for pace keys (Change 8)
*   **Pros**: One key list.
*   **Cons**: One alert type could suppress the other.
*   **Reason for Rejection**: Own key space `pace_alerted` (D22).

### Alternative Q2: Make milestone-only a setting (Change 9)
*   **Pros**: Lets users keep repeats.
*   **Cons**: No one wants repeat alerts; a setting adds a switch and a test matrix.
*   **Reason for Rejection**: Owner decision: milestone-only (D23).

### Alternative Q3: Hysteresis only (Change 9)
*   **Pros**: No new state.
*   **Cons**: Does not fix the cause, which is keys lost when a level is missing for one pass.
*   **Reason for Rejection**: Carry-over keys fix it (D23).

### Alternative Q4: Keep the previous limits on a fetch error (Change 9)
*   **Pros**: Levels never go missing.
*   **Cons**: `fetchUsage` drops old percentages on purpose because they could be wrong; bars would show stale percentages as current.
*   **Reason for Rejection**: The fix is in alert state only (D23).

### Alternative R1: Show hook commands in full (Change 10)
*   **Pros**: Complete information.
*   **Cons**: Commands often hold secrets; pattern-only redaction can miss one.
*   **Reason for Rejection**: Default shows the program name; redaction only on click (D24).

### Alternative R2: Hooks inside Settings instead of a tab (Change 10)
*   **Pros**: No ninth tab, no caption problem.
*   **Cons**: Settings has no per-tool context; hooks are things to inspect, not set.
*   **Reason for Rejection**: Owner decision: a tab; the caption rule handles width (D26).

### Alternative R3: Read `~/.codex/config.toml` for Codex hooks (Change 10)
*   **Pros**: Could show Codex hooks set there.
*   **Cons**: Needs a TOML parser for one key and no evidence that Codex stores hooks there (no hook text in this Mac's file).
*   **Reason for Rejection**: Not read; the tab says so (D25).

### Alternative S1: Defer Changes 4, 8, 10 and the graph click to 3.2 (zoom-out lens)
*   **Pros**: Smaller release, less review risk.
*   **Cons**: A second release and a split migration (Codex re-reads and `state.json` keys land in two versions); the owner's changes are interdependent (graph uses effort and folder names).
*   **Reason for Rejection**: Owner decision: all ten changes stay in 3.1.0 (D28).

### Alternative S2: One global schema version instead of a per-file `v` (Change 4, 6)
*   **Pros**: One place to check.
*   **Cons**: Forces a full re-read of every source when only Codex entries changed.
*   **Reason for Rejection**: A per-file `v` fits the Codex per-file cache.

### Alternative T: FAQ placement: its own tab, or only in the README (Change 7)
*   **Pros**: A tab is easy to find; the README is free.
*   **Cons**: A tab takes a slot in an already tight tab bar (nine tabs, see Change 10); the README is not visible in the app where the confusion happens.
*   **Reason for Rejection**: A card in Settings (owner decision, D19).

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Security and privacy:** see the privacy review. No tokens, raw ids, emails or hook text are stored, synced or logged.
*   **Performance:** `renderPanel` runs about every 15 seconds while shown. New work per render: text measuring of at most a few dozen labels; hook files (about 10 small files) only when the tab exists; `~/.claude.json` and `~/.codex/auth.json` are cached by modification time and size. Codex files are re-read once per `fileVersion` step; PR 6 and PR 7 ship together in 3.1.0, so a user upgrading from 3.0.0 gets one re-read to version 3 (D10). `backfillEfforts` runs once and reads files up to saved offsets.
*   **Rollout and rollback:** one PR per change merged in order; PR 11 bumps `Version.version`. Rollback notes are in the data section.
*   **Platform:** Swift 5.9, macOS 13 minimum. `SpatialTapGesture`, `onContinuousHover` and CryptoKit are available.
*   **Accessibility:** chevron rows are buttons with full-name labels and expanded state; grey parent text is also in the accessibility label; the chart has an adjustable action.

## Risks

| Risk | Mitigation |
| --- | --- |
| Whole-app filter touches every view builder | Scope at file level before merging; combined-view test; if it slips, cut the filter from PR 6 and ship the Accounts card alone (D28) |
| Reading `~/.codex/auth.json` is the largest new privacy surface | Keep one field and `auth_mode`; cache by mtime and size; errors never echo content; README states it; sentinel tests in PR 6 |
| One-time Codex re-reads (PR 6, PR 7) change totals if a log was rotated | Re-read replaces a file's own entry; deleted files keep their data; backup file |
| Backup or backfill fails | Logged; app continues (all changes are additive); backfill retries next launch because the flag is unset |
| `efforts` growth | A few hundred bytes per day; no cap needed |
| Hooks re-read every 15 s while the panel is open | About 10 small files, only when the tab exists |
| Hook redaction is best effort; a screenshot of a revealed row can leak | Default view hides arguments; reveal is capped and masked |
| A threshold crossed while the app was closed, or during a failed-fetch gap, is seeded silently | Accepted; a long-failing fetch also keeps a carried key until the next successful fetch |
| Ninth tab may not fit | `compactCaptions` rule, tested |
| Codex hooks location inferred from plugin files | Tab says exactly what was read |
| Pace estimate can be wrong; Codex only updates during use | Off by default; worded as an estimate; stale-sample guard |

--------------------------------------------------------------------------------

## Decision Log

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| D1 | `Limits.displayName`, built from kind and window | One place; no migration | Changing stored labels |
| D2 | Layout B: second line "Resets 4:00 PM" / "Resets Nov 20", reusing `formatReset` | Owner decision; one reset formatter | New formatter |
| D3 | Fallback Opus/Sonnet levels get kinds `weekly_opus`/`weekly_sonnet` | Same id as fetched; distinct names | Leaving two "Weekly" bars |
| D4 | Chevron plus inline line (owner decision); `LabelExtras` with defaults; `Item.detail` added in PR 4 | Existing call sites compile; one new case per PR | One field per feature |
| D5 | Open rows `[id: canReveal]` in `AppController`, cleared on tab change and on `onWillShow`; several rows may be open; reveal path travels with the tabs (`buildPanelResult`) | Panel redraws lose view state; Finder check at click time through an injected closure | `@State`, cached existence, path parsed from ids |
| D6 | Cut-off: `measure > budget - 1`; budget is chevron-aware (192/178 bar, 202/188 row); `labelBudget` is the single source | A chevron exists for other reasons (paths) | Subtracting nothing; separate literals in the view |
| D7 | Display `~/...` as stored; expand `~` only for Finder | Short and matches the data | Showing `/Users/...` |
| D8 | Chevron only when the row has a real path or a cut-off name | "Unknown" has nothing to show | Chevron everywhere |
| D9 | Account digest (12 hex of SHA-256) stored, never the raw id; Claude is "not split" | Raw id off disk; Claude logs have no account | Raw id |
| D10 | `account` captured in PR 6 with `v = 2`; effort in PR 7 with `v = 3`. Both ship in 3.1.0, so users re-read once (to v3) | Each PR owns its own change; no account work hides in the effort PR | Capturing account inside the effort PR to share one version step |
| D11 | Accounts card on Limits tab; "Show only" popup under "Tracking" when 2+ identities (owner decision) | No new tab | New Accounts tab |
| D12 | `account_scope` persisted; header shows "Account n only"; cleared when fewer than two identities | Preference, visible when active, never stranded | Per launch only |
| D13 | Filter does not affect alerts (signed-in account, ids stable) or the leaderboard push; panels show the chosen account | Alerts follow who is signed in | Scoped alerts |
| D14 | Claude email shown on screen, memory only | Needed to know which account | Not showing it |
| D15 | Claude effort from `effort`, fallback `perTurnEffort`; one-time backfill | Real field found; history on disk used | New data only |
| D16 | Effort display as owner wrote it; split rows per effort; clamp; remainder plain | Owner decision; totals stay exact | Lowercase tag |
| D17 | Graph on `Canvas`; range persisted default 14 | No new framework | Swift Charts |
| D18 | Breakdown top 5 plus "N more", models and projects as separate lists; `model_projects` not used | Bounded height; some buckets lack `model_projects` | Cross-table |
| D19 | FAQ card in Settings; text built from shared label constants | Owner decision; cannot drift | Test-only guard; own tab |
| D20 | `Item.heading` added in PR 3 | Needed by FAQ, graph, hooks | Bold notes |
| D21 | Pace: percent over elapsed share; guards in the table; sample age 20/15 min; nil `sampledAt` means no alert | No history needed | Tokens per hour |
| D22 | Pace key `pace:<id>@<resetsAt / 600>`; pace sentence appended to a same-pass threshold message; no seeding; recorded only when delivered | Jitter-proof; one warning is never lost | Shared key set; exact `resetsAt` |
| D23 | Milestone fix: seed only on the process's first pass; carry keys only when absence means unknown; `seeding` and `unknownIDPrefixes` parameters; 2-tuple return | Fixes root cause without silencing fallback alerts or stranding keys | Per-level seeding; carry everything; hysteresis |
| D24 | Hooks: program name (plus script for interpreters); redaction only on reveal; length and line caps | Secrets | Full command |
| D25 | Hooks sources: user and local settings, managed, enabled plugins, open sessions' project settings, `~/.codex/hooks.json` if it exists; Gemini and opencode "not available"; not-read list shown | Only evidenced sources; never imply "no hooks" | TOML parser |
| D26 | Nine tabs: pure `captions` rule with `compactCaptions`; no Settings fallback | A decided rule, testable | "Shrink if it does not fit"; moving Hooks to Settings |
| D27 | Backup `state.json.pre-3.1.bak`, existence as marker, before `applyLaunchDefaults`, skipped on fresh install | Cheap rollback | A state key |
| D28 | The filter is the cut line inside PR 6 if it slips; deferring to 3.2 is rejected | Owner decision | Deferring Change 4 |
| D29 | PR plan: PR 0 foundation, PR 1 to 10 one per owner change, PR 11 release | Owner rule: one PR per change | Sub-PRs (the former 3a/3b/c, 4a/4b) |
| D30 | Fold-parent guard for `~`, `/`, home, `Unknown`, empty; part of Change 3's PR | Fixes the cause of the hidden rows | Labelling folded rows |
| D31 | Several rows may be open at once; no cap (the concepts brief suggested 6; every card is already bounded in height) | Simple | Single open row; a cap of 6 |
| D32 | `~/.claude.json` read skipped above 20 MB | Guard against a runaway file | No cap |
| D33 | Hooks cap 8 per tool, then "Show more" | Matches Projects (top 5, Show more) | No cap |
| D34 | "Monthly" is a rolling 30 days (observed `window_minutes` 43200) | Matches the data | Calendar month |
| D35 | No alert hysteresis; `fetchUsage` unchanged | No evidence of flapping | Hysteresis |
| D36 | Scope semantics: with an account chosen, All AIs, company views and the menu bar include only scoped Codex data and list excluded tools; single non-Codex tools stay unfiltered with a note | Numbers must match the header | Header "Account 2 only" over mixed data |
| D37 | Scroll offset kept across `draw()` | Toggles and 15 s refresh must not jump | Real-build check only |
| D38 | Tab change redraws only when open state was cleared; clearing also on `onWillShow` | `selectTab` swaps cached views | New close callback |
| D39 | Detail text wrapped by measured width, 11 pt secondary | Wide glyphs must not clip | 46-character budget |
| D40 | Keep the `auth.json` read for "signed in", with mtime and size cache, no content echo, API-key state | Decided capability; log guess is wrong after a switch | Log-derived account |
| D41 | No nicknames or rename | Not among the four decided capabilities | `identity_rename`, `Dialogs.ask` |
| D42 | Pace launch and switch behaviour: alerts once if the sample is fresh | Keys persist; intended | Seeding |

### Reconciliation with the brief

Where the draft decides differently from the brief:

1.  Brief (Change 6 default): "lowercase grey tag". Draft: capitals in parentheses. Owner decision overrides.
2.  Brief (Change 9): "on a fetch error, keep the previous limits ... or treat an error as unknown". Draft: neither at the limits level; the alert state carries keys only where absence means unknown. Reason: `fetchUsage` deliberately drops old percentages.
3.  Brief (Change 9): "fallback levels have a different id". Draft: only Opus and Sonnet do.
4.  Brief (Change 6): "Claude field not read; shows nothing when absent". Draft: the field is `effort`; Claude shows effort.
5.  Brief (Change 3): "Gemini rows have no real path". Draft: rows with a real project root do.
6.  Brief (Change 10): Codex "needs a TOML reader ... or show not supported". Draft: reads `~/.codex/hooks.json` only if it exists; no TOML.
7.  Brief (step 0): open-id set and measure in the foundation. Draft: same; the `detail` item case moves to Change 2's PR.
8.  Brief (Change 4): per-file account in the PR for Change 4. Draft: same (PR 6); account ids are stored as digests (an addition).
9.  Addition: persisted `account_scope`, the header text and the second popup under "Tracking". Changes an external interface (the header), so listed here.

--------------------------------------------------------------------------------

## Additional Resources

*   `concepts_brief.md` (input); the README sections "By default it never connects" (privacy), "Usage limits and alerts" and "OpenAI, DeepSeek, Kimi and other AI companies".
*   Code read: `PanelItems.swift`, `PanelLayout.swift`, `PanelModel.swift`, `PanelModel+Tabs.swift`, `PanelModel+Settings.swift`, `Limits.swift`, `UsageStats.swift`, `CodexSource.swift`, `Providers.swift`, `Accounts.swift`, `ActiveSessions.swift`, `Plugins.swift`, `ClaudeUsage.swift`, `AppAction.swift`, `AppState+Launch.swift`, `AppState+Changes.swift`, `AppController*.swift`, `Panel/*.swift`.

## Future Improvements

*   Per-day account axis if Claude Code ever records the account in its logs.
*   Hook adapters for Gemini CLI and opencode when real files can be verified.
*   A trailing-rate pace estimate with stored samples.
*   Expiring carried alert keys for levels that never return.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Each PR merges to master before the next starts. Work in a worktree, never in the owner's clone. Only PR 11 changes `Version.version`. Paths are under `Sources/TrackerCore` (core), `Sources/ClaudeTracker` (app), `Tests/TrackerCoreTests` (tests), repo root. Each PR that adds a source file also adds its row to the README "Project layout" table in the same PR. `BuildScriptsTests` copies whole directories and checks no file list, so it needs no change (verified).

### Change / PR / branch table

| PR | Change | Branch | `Item` case or action added | README edit |
| --- | --- | --- | --- | --- |
| 0 | foundation (no owner change) | `3.1/00-foundation` | `toggle_row` action; `LabelExtras`, `sub` | none |
| 1 | Change 9: milestone alerts | `3.1/01-milestone-alerts` | none | alerts paragraph (no repeat at launch) |
| 2 | Change 1: names | `3.1/02-names` | none | limits wording |
| 3 | Change 7: FAQ | `3.1/03-faq` | `Item.heading` | Settings description |
| 4 | Change 2: cut-off names | `3.1/04-cutoff-names` | `Item.detail` | Limits tab text |
| 5 | Change 3: project rows, Finder, fold fix | `3.1/05-project-rows` | `reveal:<id>` | Projects/Live text, Gemini sentence, paths on screen |
| 6 | Change 4: accounts and Show only | `3.1/06-accounts` | `select_account` | privacy list (auth.json, .claude.json, digest), Limits tab |
| 7 | Change 6: effort | `3.1/07-effort` | none | privacy (effort), Models tab |
| 8 | Change 5: graph | `3.1/08-graph` | `chart_range`, `chart_day`, new `chart` shape | "last 14 days" line |
| 9 | Change 8: pace alert | `3.1/09-pace-alert` | `pace_alerts` | usage limits section |
| 10 | Change 10: hooks tab | `3.1/10-hooks-tab` | `hooks_expand` | privacy (new reads), tab list |
| 11 | release (no owner change) | `3.1/11-release` | none | privacy consistency check, version line, release notes |

### PR 0: shared foundation (`3.1/00-foundation`)

*   **Delivers:** the arithmetic that Changes 1, 2, 3, 5, 10 rely on. No owner change or CUJ by itself.
*   **Depends on:** nothing.
*   Files:
    *   `Sources/TrackerCore/PanelItems.swift` (Modify): `LabelExtras`; `sub` and `extras` on `bar`; `extras` on `row`.
    *   `Sources/TrackerCore/PanelLayout.swift` (Modify): `height(of:)` reads `sub`; `barSubHeight`; `labelBudget(kind:hasChevron:)`.
    *   `Sources/TrackerCore/PanelModel.swift` (Modify): `TextMeasure`, `LabelWeight`, `PanelContext`, `buildPanelResult`, `RowInfo`; `buildPanel` becomes a wrapper.
    *   `Sources/TrackerCore/PanelModel+TextWrap.swift` (Modify): `wrapMeasured`.
    *   `Sources/TrackerCore/OpenRows.swift` (Create): `toggle`, `prune`.
    *   `Sources/TrackerCore/AppAction.swift` (Modify): `toggleRow(id:)`, parse `toggle_row:<id>`.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): `openRows`, toggle handling, pruning, pass context; clear in `onWillShow`; pass `onTabChange`.
    *   `Sources/ClaudeTracker/Panel/PanelController.swift` (Modify): redraw after tab-change clear (next run-loop turn); keep scroll offset across `draw()`.
    *   `Sources/ClaudeTracker/Panel/ItemViews.swift`, `CardView.swift` (Modify): draw `sub`; `labelBudget` instead of literals; new `bar`/`row` arity.
    *   `Sources/ClaudeTracker/TextMeasure.swift` (Create): `TextMeasure.live`.
    *   `README.md` (Modify): add `OpenRows.swift` and `TextMeasure.swift` to the layout table.
*   Tests (Modify `PanelLayoutTests.swift`, `AppActionTests.swift`, `PanelModelTests.swift`; Create `OpenRowsTests.swift`): `barHeightWithAndWithoutSub`, `labelBudgetPlainAndWithChevron`, `parsesToggleRow`, `toggleRowIdWithColons`, `openRowsToggleUsesInjectedFileExists`, `pruneDropsUnknownIds`, `buildPanelWrapperMatchesResultTabs`, `wrapMeasuredBreaksWideWordsByCharacter`, `stubMeasureBoundaryAtBudgetMinusOne` (191 not cut, 192 cut, 177/178 with chevron).

### PR 1: milestone alerts (`3.1/01-milestone-alerts`)

*   **Delivers:** Change 9, CUJ 8.
*   **Depends on:** nothing (independent of PR 0; ordered after it only to keep the list simple).
*   Files:
    *   `Sources/TrackerCore/Limits.swift` (Modify): `alertsToSend(... seeding:unknownIDPrefixes:)`, `unknownIDPrefixes(_:now:)`, `claudeLimitKinds`, `reachedClaudeLimits` kinds.
    *   `Sources/TrackerCore/AppState+Changes.swift` (Modify): `checkAlerts(_:now:seeding:)`.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): `alertsSeeded`.
    *   `Sources/ClaudeTracker/AppController+Alerts.swift` (Modify): pass `seeding`.
    *   `README.md` (Modify): alerts paragraph.
*   Tests (Modify `LimitsTests.swift`, `AppStateChangesTests.swift`): update the `reachedClaudeLimits` equality and fallback-id tests (kinds added; fallback Opus now has id `claude_code:weekly_opus`); new: `keySurvivesPassWhereLevelIsMissingAndUnknown`, `launchWithLevelOverThresholdSendsNothing`, `crossingAfterSeedingSends`, `fallbackLevelFirstSeenAfterLaunchAlerts`, `fallbackHitResetHitAgainAlerts`, `fetchErrorCarriesKeys`, `emptyFetchWithPercentagesOffDropsKeys`, `fetchedLevelVanishingDropsKeys`, `dropBelowThenCrossSendsAgain`, `resetToZeroClearsKeys`, `toolDisabledKeepsKeys`, `switchOffThenOnSendsNothingWhenKeyPresent`, `severalThresholdsGiveOneMessage`, `seedingWritesKeysButSendsNothing`, `unknownPrefixesFromState` (tool disabled, Percentages on with an empty fetch, Percentages off, no Codex record).

### PR 2: names (`3.1/02-names`)

*   **Delivers:** Change 1, CUJ 1.
*   **Depends on:** PR 1 (same function, `alertsToSend`).
*   Files:
    *   `Sources/TrackerCore/Limits.swift` (Modify): `displayName`; message text.
    *   `Sources/TrackerCore/PanelModel+Tabs.swift` (Modify): `limitsTab` labels and `sub`.
    *   `README.md` (Modify): limits wording.
*   Tests (Modify `PanelModelLimitsTests.swift`, `LimitsTests.swift`, `AppStateChangesTests.swift`): rewrite the about 15 `"Codex: 5-hour usage is at"` and `"Claude Code: ..."` assertions; new: `displayNameAllTools` (claude five_hour, weekly, weekly_opus, weekly_sonnet, unknown kind; codex five_hour, weekly, monthly; nil kind; empty tool name), `limitsTabUsesDisplayNameInAllViews`, `subTextAndNilCases`, `notificationTextMonthly`, `savedLabelAndLevelIdUnchanged`.

### PR 3: FAQ (`3.1/03-faq`)

*   **Delivers:** Change 7, CUJ 10.
*   **Depends on:** PR 0 (heights table).
*   Files:
    *   `Sources/TrackerCore/PanelItems.swift` (Modify): `Item.heading`, `kind`.
    *   `Sources/TrackerCore/PanelLayout.swift` (Modify): heading height; `trackingLabel` used by `toolPicker`.
    *   `Sources/TrackerCore/PanelModel.swift` (Modify): `aiToolsTitle`, `claudeUsageSwitchLabel`.
    *   `Sources/TrackerCore/PanelModel+Settings.swift` (Modify): `faqEntries`, FAQ card, constants used by `toolsCard` and the inline General card in `settingsTab`.
    *   `Sources/ClaudeTracker/Panel/ItemViews.swift`, `CardView.swift` (Modify): `HeadingItem`.
    *   `README.md` (Modify): Settings description.
*   Tests (Modify `PanelModelTests.swift`, `PanelLayoutTests.swift`): `faqCardIsLastInSettings`, `faqLinesWithinNoteWidth`, `faqUsesUiConstants`, `faqAnthropicAnswerMatchesProviderView` (asserts the text names `claude-` and every tool, and that `Providers.providerOf("claude-opus")` is `anthropic`), `headingHeight`.

### PR 4: cut-off names (`3.1/04-cutoff-names`)

*   **Delivers:** Change 2, CUJ 2.
*   **Depends on:** PR 0 (budget, open rows, `toggle_row`), PR 2 (the names being measured).
*   Files:
    *   `Sources/TrackerCore/PanelItems.swift` (Modify): `Item.detail`.
    *   `Sources/TrackerCore/PanelLayout.swift` (Modify): detail height rule `4 + 14 * lines + (button ? 30 : 0)`.
    *   `Sources/TrackerCore/PanelModel+Tabs.swift` (Modify): cut-off check and detail insertion for limit bars.
    *   `Sources/ClaudeTracker/Panel/Style.swift` (Modify): `ChevronLabel`.
    *   `Sources/ClaudeTracker/Panel/ItemViews.swift`, `CardView.swift` (Modify): use it; draw `detail`.
    *   `README.md` (Modify): Limits tab text.
*   Tests (Modify `PanelModelLimitsTests.swift`, `PanelLayoutTests.swift`, `AppActionTests.swift`): `detailHeightOneLine`, `detailHeightTwoLinesAndButton`, `cutOffAtBudgetBoundary`, `chevronBudgetBoundary`, `openRowInsertsDetail`, `closedRowHasNoDetail`, `openIdPrunedWhenRowGone`, `toggleRowUsesPr0Action`.

### PR 5: project rows, Finder, fold fix (`3.1/05-project-rows`)

*   **Delivers:** Change 3, CUJ 3, CUJ 11.
*   **Depends on:** PR 4 (detail, chevron), PR 0.
*   Files:
    *   `Sources/TrackerCore/ProjectNames.swift` (Create).
    *   `Sources/TrackerCore/UsageStats.swift` (Modify): fold-parent guard.
    *   `Sources/TrackerCore/PanelModel+Tabs.swift` (Modify): Projects and Live rows.
    *   `Sources/TrackerCore/ActiveSessions.swift` (Modify): `cwd` for Codex and opencode sessions.
    *   `Sources/TrackerCore/AppAction.swift` (Modify): `reveal:<id>`.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): reveal handler (close panel, then `NSWorkspace.activateFileViewerSelecting`), existence re-check.
    *   `Sources/ClaudeTracker/Panel/ItemViews.swift` (Modify): grey tail.
    *   `README.md` (Modify): paths on screen, Gemini sentence, layout table row for `ProjectNames.swift`.
*   Tests (Create `ProjectNamesTests.swift`; Modify `UsageStatsTests.swift`, `PanelModelTests.swift`, `ActiveSessionsTests.swift`, `AppActionTests.swift`): `foldSkipsHomeAndRoot`, `foldStillFoldsRealSubfolders` (`~`, `~/a`, `~/a/b`, `/Users/x`, `/`, trailing slash on home, `Unknown`), `homeRowIsSeparate`, `uniqueNamesNoTail`, `sameNameParentsGetGreyTail`, `threeLevelsDeep`, `identicalPathsNotACollision`, `homeAndUnknownAndSlug`, `geminiRealPathHasPath`, `revealBoolFromOpenRows`, `unknownRowHasNoButton`, `liveRowsUseCwdForClaudeCodexOpencode`, `parsesReveal`.

### PR 6: accounts and Show only (`3.1/06-accounts`)

*   **Delivers:** Change 4, CUJ 4 (and the privacy edits for new credential reads).
*   **Depends on:** PR 0 (`PanelContext`), PR 3 (FAQ card), PR 4 (detail rows for accounts).
*   Files:
    *   `Sources/TrackerCore/Identities.swift` (Create): digest, `codexSignedIn`, `claudeSignedIn`, account list, `AccountScope`, `Snapshot`.
    *   `Sources/TrackerCore/CodexSource.swift` (Modify): `account` and `v = 2` per file; `fileVersion`; `codexLatest(_:account:)`; scope parameters on `codexDaily`/`codexTotal`.
    *   `Sources/TrackerCore/Tools.swift` (Modify): scope on `toolView`, `combinedView`, excluded-tool list.
    *   `Sources/TrackerCore/Providers.swift` (Modify): scope on `providerView`.
    *   `Sources/TrackerCore/AppState+Changes.swift` (Modify): `currentView` takes scope from state.
    *   `Sources/TrackerCore/AppState+Launch.swift` (Modify): `account_scope` default and validation.
    *   `Sources/TrackerCore/Limits.swift` (Modify): `planLevels` keeps the signed-in path (reads `codexLatest(account: signed-in digest)`).
    *   `Sources/TrackerCore/PanelLayout.swift` (Modify): `contentTop(hasToolPicker:hasScopePicker:)`, scope popup.
    *   `Sources/TrackerCore/PanelModel.swift`, `PanelModel+Tabs.swift`, `PanelModel+Settings.swift` (Modify): Accounts card, `PanelContext.identities`, notes, FAQ entry "What does \"Show only\" do?" (A filter on this panel only: it does not change which account Codex uses. It scopes Codex data; tools that cannot be split by account are left out of All AIs while it is on. A session is counted under the account that created it.).
    *   `Sources/TrackerCore/AppAction.swift` (Modify): `select_account`.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): scope in `updateTitle`/`renderPanel`, digest caches.
    *   `Sources/ClaudeTracker/AppController+Identities.swift` (Create): sign-in caches, scope selection.
    *   `Sources/ClaudeTracker/Panel/PanelChromeView.swift`, `PanelController.swift` (Modify): second popup, header text, `contentTop`.
    *   `README.md` (Modify): privacy list and sentence about credential tables, Limits tab text, layout row for `Identities.swift`.
*   Tests (Create `IdentitiesTests.swift`; Modify `CodexSourceTests.swift`, `ToolsTests.swift`, `ProvidersTests.swift`, `PanelLayoutTests.swift`, `AppActionTests.swift`, `AppStateLaunchTests.swift`, `GistSyncTests.swift` or `LeaderboardTests.swift`, `AppStateTests.swift`): `digestIs12HexAndRawIdAbsentFromState`, `twoIdsAcrossFiles`, `nullIdIsUnattributed`, `orderingAndNaming`, `lastSeenLimitsForOtherAccount`, `signedInLimitsUseThatAccountsNewestFile`, `authApiKeyMode`, `authMissingAndMalformed`, `authFixtureSentinelsNeverReachState`, `claudeJsonFixtureAndSkipOver20Mb`, `sentinelEmailAbsentFromStateAndGist`, `gistPayloadHasExactlyFourKeys`, `leaderboardTotalUnchangedByScope`, `scopeFiltersCodex`, `unattributedOnlyInAll`, `combinedViewUnderScopeExcludesOtherTools`, `providerViewUnderScope`, `nonCodexToolViewUnfilteredWithNote`, `vanishedDigestResetsToAll`, `scopeClearedWithFewerThanTwoIdentities`, `menuBarCountScoped`, `alertsUnchangedByScope`, `contentTopWithScopePicker`, `tabCountAndPickerPresence`, `parsesSelectAccount`, `v1FileReadOnceAndReplacedNoDoubleCount`.

### PR 7: effort (`3.1/07-effort`)

*   **Delivers:** Change 6, CUJ 6, CUJ 12.
*   **Depends on:** PR 6 (shares `readCodex` and `fileVersion`).
*   Files:
    *   `Sources/TrackerCore/CodexSource.swift` (Modify): effort tracking, `fileVersion = 3`.
    *   `Sources/TrackerCore/UsageStats.swift` (Modify): `addUsage` effort, `recordEntry`, `combineBuckets`, `filterDaily` carry `efforts`; `effortsInRange`, `effortsAllTime`.
    *   `Sources/TrackerCore/TokenMath.swift` (Modify): `backfillEfforts`.
    *   `Sources/TrackerCore/AppState+Launch.swift` (Modify): `efforts_backfilled` default.
    *   `Sources/TrackerCore/PanelModel.swift` (Modify): `PanelData.todayEfforts`, `lifetimeEfforts`.
    *   `Sources/TrackerCore/PanelModel+Tabs.swift` (Modify): `modelsCard` signature and rows.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): backup (after `loadState`, before `applyLaunchDefaults`, not on fresh install); `backfillEfforts` after `backfillLimits`, before `scan`.
    *   `.gitignore` (Modify): `state.json.pre-3.1.bak`.
    *   `README.md` (Modify): privacy (effort), Models tab text.
*   Tests (Modify `CodexSourceTests.swift`, `UsageStatsTests.swift`, `TokenMathTests.swift`, `AppStateLaunchTests.swift`, `PanelModelTests.swift`, `ProvidersTests.swift`): `codexEffortSplitsPerTurn`, `codexAbsentEffort`, `codexFallsBackToCollaborationEffort`, `claudeEffortField`, `claudePerTurnEffortFallback`, `claudeBothPresentAndDifferent`, `normalisesEffort`, `backfillEffortsOnce`, `backfillRunsAfterBackfillDailyBeforeScan`, `modelKeyAndPricingUnchanged`, `effortRowsSumToModelTotal`, `effortSumClampedToModelTotal`, `remainderRowOnlyWhenPositive`, `combineBucketsKeepsEffortsSumAndMax`, `filterDailyKeepsEfforts`, `effortsInRangeMatchesModelsInRange`, `v2FileReadOnceMoreForV3`, `backupCreatedOnceBeforeDefaults`, `backupSkippedOnFreshInstall`.

### PR 8: graph (`3.1/08-graph`)

*   **Delivers:** Change 5, CUJ 5.
*   **Depends on:** PR 3 (`heading`), PR 5 (folder names), PR 6 (scoped `daily`), PR 7 (effort rows in the breakdown), PR 0 (`selectedDay`).
*   Files:
    *   `Sources/TrackerCore/PanelItems.swift` (Modify): new `chart` shape, `ChartPoint`.
    *   `Sources/TrackerCore/UsageStats.swift` (Modify): `dayBreakdown`, `DayModelRow`.
    *   `Sources/TrackerCore/PanelModel.swift`, `PanelModel+Tabs.swift` (Modify): `chartDays(from:)`, range control, breakdown card, `PanelContext.selectedDay`.
    *   `Sources/TrackerCore/AppAction.swift` (Modify): `chart_range`, `chart_day`.
    *   `Sources/TrackerCore/AppState+Launch.swift` (Modify): `chart_days`.
    *   `Sources/ClaudeTracker/Panel/ItemViews.swift` (Modify): hover, click, accessibility.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): `selectedChartDay`, clearing.
    *   `README.md` (Modify): the "chart of the last 14 days" line.
*   Tests (Modify `UsageStatsTests.swift`, `PanelModelTests.swift`, `AppActionTests.swift`, `AppStateLaunchTests.swift`): `chartRangeClamp`, `chartRangeIndexMapping`, `missingDayIsZero`, `partialForToday`, `ordinalLabels` (1st, 2nd, 3rd, 11th, 12th, 13th, 21st), `dayBreakdownModelsOnly`, `dayBreakdownProjectsOnly`, `dayBreakdownEmpty`, `dayBreakdownTop5PlusRest`, `dayBreakdownEffortRows`, `selectedDayClearedOnRangeChange`, `selectedDayClearedWhenLeavingRange`, `chartDayActionParse`, `chartAccessibilityStepsDays`, `applyLaunchDefaultsChartDays`.

### PR 9: pace alert (`3.1/09-pace-alert`)

*   **Delivers:** Change 8, CUJ 7.
*   **Depends on:** PR 1 (alerts loop), PR 2 (`displayName` in the message), PR 6 (`codexLatest`), PR 3 (FAQ).
*   Files:
    *   `Sources/TrackerCore/Limits.swift` (Modify): `windowSeconds`, `sampledAt`, `codexLimits(... sampledAt:)`, `parseISO`, `paceProjection`, guards, message.
    *   `Sources/TrackerCore/AppState+Changes.swift` (Modify): pace pass in `checkAlerts`.
    *   `Sources/TrackerCore/AppState+Launch.swift` (Modify): `pace_alerts`, `pace_alerted` defaults.
    *   `Sources/TrackerCore/AppAction.swift` (Modify): `pace_alerts`.
    *   `Sources/TrackerCore/PanelModel+Tabs.swift` (Modify): the switch.
    *   `Sources/TrackerCore/PanelModel+Settings.swift` (Modify): FAQ entry.
    *   `README.md` (Modify): usage limits section.
*   Tests (Modify `LimitsTests.swift`, `AppStateChangesTests.swift`, `AppActionTests.swift`, `PanelModelLimitsTests.swift`, `AppStateLaunchTests.swift`): `paceSteadyRateAlerts`, `paceFlatRateDoesNot`, `paceGuardFractionBelow20`, `paceGuardPercentBelow5`, `paceGuardProjectedBelow110`, `paceGuardUnder10MinutesLeft`, `paceReachedLevelNoAlert`, `paceKeyIgnoresJitter` (1 s and 20 s), `paceNewResetGivesNewKey`, `paceOneAlertPerWindow`, `paceAppendedToThresholdMessage`, `paceKeyRecordedOnlyWhenDelivered`, `paceNotifyOffOrSwitchOffNone`, `paceStaleSampleNone`, `paceNilSampledAtNone`, `paceOffByDefault`, `paceAlertsAtLaunchWhenFresh`, `paceMessageSameDayAndLaterDay` (15-minute rounding), `parseISOWithMilliseconds`, `parsesPaceAlertsAction`, `codexLimitsEqualityAfterNewFields`.

### PR 10: hooks tab (`3.1/10-hooks-tab`)

*   **Delivers:** Change 10, CUJ 9.
*   **Depends on:** PR 3 (`heading`), PR 4 (detail), PR 5 (reveal handler), PR 0 (ids, `PanelContext`).
*   Files:
    *   `Sources/TrackerCore/Hooks.swift` (Create): `Entry`, `Result`, `parse`, program name, redaction, adapters.
    *   `Sources/TrackerCore/PanelModel.swift` (Modify): Hooks tab in `buildPanel` (after Live, before Leaderboard; not for provider views); `PanelContext.hooks`, `hooksExpanded`.
    *   `Sources/TrackerCore/PanelModel+Tabs.swift` (Modify): `hooksTab`.
    *   `Sources/TrackerCore/PanelLayout.swift` (Modify): `captions`, `compactCaptions`.
    *   `Sources/TrackerCore/AppAction.swift` (Modify): `hooks_expand:<tool>`.
    *   `Sources/ClaudeTracker/AppController.swift` (Modify): read hooks at render, `hooksExpanded`.
    *   `Sources/ClaudeTracker/Panel/PanelChromeView.swift` (Modify): draw `captions` output.
    *   `Sources/TrackerCore/Plugins.swift`: not modified (`hookDetails` stays as is).
    *   `README.md` (Modify): new reads only, tab list, layout row for `Hooks.swift`.
*   Tests (Create `HooksTests.swift`; Modify `PanelModelTests.swift`, `PanelLayoutTests.swift`, `AppActionTests.swift`; `PluginsTests.swift` runs unchanged): `parsesUserSettings`, `eventsSortedAndFileOrderKept`, `matcherMissing`, `programNameEnvPrefixQuotedAndPath`, `interpreterAddsScriptName`, `redactsSecretsOnReveal` (assignment, bearer, basic auth header, `-u`, `--pass`, URL userinfo, 40-char token, quoted values), `revealCappedAt8LinesAnd400Chars`, `nonCommandTypeRow`, `disableAllHooksLine`, `malformedFileProblem`, `missingFileListedAsNotRead`, `pluginHooksWithShellAsyncAndPathManifest`, `projectSettingsOfSessionFolder`, `homeOrRootFolderSkippedAndDeduped`, `codexFilePresentAndAbsent`, `notAvailableForGeminiAndOpencode`, `capAt8ThenShowMore`, `hooksExpandedPerTool`, `noHookTextInState`, `hooksTabPositionAndNoProviderView`, `nineTabCaptionsCompactWhenTheyFail`, `eightTabsNeverCompact`, `tabCountAllAisCodexClaude` (7/8, 8/9 with Leaderboard).

### PR 11: release (`3.1/11-release`)

*   **Delivers:** 3.1.0. No owner change.
*   **Depends on:** PR 0 to PR 10.
*   Files: `Sources/TrackerCore/Version.swift` (Modify): `3.1.0`; `README.md` (Modify): privacy section consistency check against the table above, "Current version" line, release notes.
*   Run the app against a copy of the real 3.0.0 `state.json` (in a scratch folder, never the owner's clone): first launch, backup file, no duplicate totals, no alert at launch, a fixture `state.json` with two Codex ids for CUJ 4, and a rollback run (3.0.0 reads the file).
*   Tests (Modify `AppStateTests.swift` or the version test that exists): `versionIs310`; full suite.
*   Release notes: notification text changes; alerts no longer repeat at launch; rollback can drop 3.1.0 per-file data until the next 3.1.0 launch re-reads logs; old Codex history is "Unattributed"; new reads listed (Codex sign-in file, Claude sign-in file, hook files, effort, full paths on screen).

### Verification Plan

*   **Build:** `swift build` (macOS 13 target, Swift 5.9, no Swift 6 features).
*   **Unit tests:** `./test.sh` (wraps `swift test` with the Swift Testing framework paths). Every PR adds its listed tests and keeps the whole suite green.
*   **Static analysis:** compiler warnings as errors for new code; no `log(...)` call with tokens, ids, emails or hook text (review item).
*   **Coverage:** every new pure function has happy, edge and empty tests; no numeric target.
*   **Manual, real build (per PR as listed):** checks 1 to 5 and manual list 6 to 9.
*   **Release:** test with a real 3.0.0 `state.json` copy, a two-account fixture, and a rollback run.

--------------------------------------------------------------------------------

## Appendix: Review disposition

Every finding was checked against the code at commit `4c49a4b` and, for facts, against real logs on this Mac. Result: all 5 Blockers and 17 Majors were valid (several with corrections below) and are fixed. Disputes and deviations first.

**Disputed or partly disputed**

*   **M12(a), prefer a log-derived signed-in account:** not adopted (D40, Alternative L2). The evidence is right that `auth.json` is a credential file, but the log-derived account is wrong after a switch and cannot show API-key mode; "who is signed in" is an owner capability. Mitigated with a cache, one kept field, no content in errors.
*   **M17, `BuildScriptsTests` "if the file list is checked":** checked; it copies whole directories (`Package.swift`, `Sources`, `Tests`, `Resources`, `build.sh`) and has no file list. No change needed. The README file table is updated per PR instead of in the release PR.
*   **M5, "about 10 destructures break":** true of the reviewer's proposed 3-tuple. The design keeps the 2-tuple return and defaults the new parameters, so no destructure changes; only `reachedClaudeLimits` equality and text assertions change (PR 1, PR 2).
*   **M7, "`Level` is Equatable so new fields change existing tests":** not for tests that never set them; nil defaults keep equality. Tests comparing `codexLimits` output are updated in PR 9 where fields are populated.
*   **M13:** confirmed in full (captions already 9 pt; `showLeaderboard` is `view.key == "claude_code"` so nine tabs occur only there). The fix is a decided pure rule, not a fallback.
*   **m10, nicknames:** dropped (D41) rather than confirmed.

**Evidence confirmed for findings**

*   B1/B2: `reachedClaudeLimits` returns a level only when reached and `resetsAt > now`; `alertsToSend` rebuilds `above` from present levels only. B5: `Accounts.keyHelp` lists openai, deepseek, kimi only; `Providers.modelPatterns` maps `^claude(-|$)` to anthropic and `providerView` filters every tool. M3: `selectTab` calls `showTab` without `draw()` when the chrome exists. M10: `filterDaily` builds `out` without `efforts`; `addUsage` writes `model_projects`. M12(d): `leaderboardPayload` has four keys. M12(e): README already discloses settings and project settings. M14(a): `hookDetails` returns sets. M17: `LabelWeight` was undefined; the General card is inline; "Tracking" is a literal in `toolPicker`.

**Facts changed after re-checking logs (names and counts only)**

Claude usage entries 21229 (effort on 21165, `perTurnEffort` on 21224, differ on 245); hooks events 7; buckets mixed (10 with `models`/`projects` only, 2 with `model_projects`); alert keys now five; Codex hooks evidence is plugin-shipped `.codex/hooks.json` files only; `window_minutes` 43200 confirms rolling 30 days; Codex effort values seen: `medium` only. Codex counts from draft 1 (190/189, 53 files, 23 with an id) were confirmed.

**Minors**

*   Fixed: m1, m2 (the "check first" paragraph deleted), m3, m4 (D29 to D42 added), m5, m6 (Terms block, renames), m7, m8 (citations by symbol and commit), m9, m11 (long passages split into lists and tables; pixel constants stay because the plan needs them), m12, m13, m14, m15, m16, m17, m18 (except hover reset, listed in manual checks).
*   Accepted without a code change: expiring carried alert keys for levels that never return (needs a timestamp per key; moved to Future Improvements; risk recorded); which of `effort` and `perTurnEffort` Claude Code's own UI shows (unknowable from logs; both tested).
*   Deferred: none beyond the above.
