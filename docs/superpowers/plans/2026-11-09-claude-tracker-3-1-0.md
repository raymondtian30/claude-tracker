# Claude Tracker 3.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Claude Tracker 3.1.0: ten owner changes as twelve PRs (foundation, ten changes, release).

**Architecture:** Pure logic and item data live in `TrackerCore` (`PanelModel`, `Limits`, new `OpenRows`, `ProjectNames`, `Identities`, `Hooks`); the AppKit/SwiftUI shell (`ClaudeTracker`) only draws and wires actions. UI state that must survive the 15 s full redraw (open rows, selected day) lives in `AppController` and reaches the model through `PanelContext`. All `state.json` changes are additive.

**Tech Stack:** Swift 5.9, SwiftPM (`TrackerCore`, `ClaudeTracker`, `TrackerCoreTests`), SwiftUI/AppKit, CryptoKit, Swift Testing (`@Test` free functions, `#expect`).

**Spec:** `docs/superpowers/specs/2026-11-09-claude-tracker-3-1-0-design.md`

## Global Constraints

- Swift 5.9-compatible `Sources` (no Swift-6-only syntax); tests may use Swift Testing (the suite already does). macOS 13 floor (`.macOS(.v13)`).
- Run tests with `./test.sh` (never bare `swift test`); single test: `./test.sh --filter <testName>`. Tests live in `Tests/TrackerCoreTests/` (capital T), as `@Test func name()` with `import Testing` and `@testable import TrackerCore`.
- README privacy promises stay true. Every PR that reads or sends anything new edits the README privacy text in the same PR (see the spec's Privacy review table). Every PR that adds a source file adds its row to the README "Project layout" block.
- No real network or Keychain in tests (inject closures/fixtures). Never print or log tokens, keys, emails, raw account ids or hook commands; parse errors never echo file content.
- `state.json` changes are additive (3.0.0 must still read it); every new key gets a line in `applyLaunchDefaults` and every reader accepts the key missing or wrong-typed.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` (use a second `-m`). PR descriptions end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Branch plus PR to `raymondtian30/claude-tracker` for every change; never push to master. Work in a worktree, never in the owner's clone; never pull, install or restart the owner's copy.
- Only PR 11 changes `Version.version`. The whole suite stays green after every task.
- Exact UI values: bar 36 pt, row 22, note 16, chart 84; `barSubHeight` 14; detail height `4 + 14 * lines + (button ? 30 : 0)`; label budget bar 192 / row 202, minus 14 with a chevron; cut off when `measure > budget - 1`; card width 312; detail text 11 pt secondary, line width 304.
- Tests that must change are owned by the PR that changes the behaviour (spec lists them per PR).

## PR order, bases and conflict map

Every PR branches from `master` and is rebased onto master after the previous PR merges. The orchestrator merges in numeric order, only after that PR's `./test.sh` passes. Files several PRs touch (so rebase conflicts are expected there): `PanelModel+Tabs.swift` (1 none; 2, 4, 5, 6, 7, 8, 9, 10), `PanelItems.swift` (0, 3, 4, 8), `AppController.swift` (0, 1, 5, 6, 7, 8, 10), `Limits.swift` (1, 2, 6, 9), `AppState+Changes.swift` (1, 6, 9), `AppAction.swift` (0, 5, 6, 8, 9, 10), `CodexSource.swift` (6, 7), `UsageStats.swift` (5, 7, 8), `README.md` (all). Dependencies are real (see each section), so no PR is opened before its dependencies are merged.

## Review Focus

Failure modes the spec implies but its listed tests do not cover, most likely first. Each has a test in the owning task (marked **RF**).

1. A `state.json` key of the wrong type (`account_scope` a number, `chart_days` a string, `pace_alerted` a dict, `efforts` not a map) must read as the default and never crash (PR 6, 7, 8, 9).
2. A hook entry that is malformed (`hooks` not an object, `command` missing or not a string, empty command, `matcher` a number) must not crash the tab or hide the other entries (PR 10).
3. Odd folder labels (trailing slash, spaces, non-ASCII, `~` alone, two names differing only in case) must give stable, non-empty row names (PR 5).
4. All-zero or single-point chart series and a day with zero tokens must not divide by zero or hide the card (PR 8).
5. Pace on an unusable window (`windowSeconds` 0, `resetsAt` in the past, `percent` exactly 5 or 99.9) must not divide by zero or alert wrongly (PR 9).

---

## PR 0: foundation

Branch `3.1/00-foundation`, base `master`. Depends on nothing. Delivers the arithmetic Changes 1, 2, 3, 5, 10 use. No visible change.

### Task 0.1: Item data, heights, label budget

**Files:**
- Modify: `Sources/TrackerCore/PanelItems.swift` (the `bar`/`row` cases, `kind`), `Sources/TrackerCore/PanelLayout.swift` (`heights`, `height(of:)`), `Sources/ClaudeTracker/Panel/CardView.swift`, `Sources/ClaudeTracker/Panel/ItemViews.swift` (`BarItem`, `RowItem`)
- Test: `Tests/TrackerCoreTests/PanelLayoutTests.swift`

**Interfaces:**
- Produces: `public struct LabelExtras: Equatable { var greyTail: String?; var expandID: String?; var isOpen: Bool; var tip: String?; static let none }`; `Item.bar(label:value:fraction:sub: String? = nil, extras: LabelExtras = .none)`; `Item.row(label:value:extras: LabelExtras = .none)`; `PanelLayout.barSubHeight = 14`; `PanelLayout.labelBudget(kind: String, hasChevron: Bool) -> CGFloat` (kind `"bar"` or `"row"`).

- [ ] **Step 1: Failing tests** in `PanelLayoutTests.swift`: `barHeightWithAndWithoutSub` (`height(of: .bar(label:"a",value:"1%",fraction:0.1)) == 36`; with `sub: "Resets Nov 20"` == 50); `labelBudgetPlainAndWithChevron` (bar 192/178, row 202/188). Existing `.bar(label:value:fraction:)`/`.row(label:value:)` call sites must still compile.
- [ ] **Step 2: Run** `./test.sh --filter barHeightWithAndWithoutSub`. Expected: FAIL (compile error, `sub` unknown).
- [ ] **Step 3: Implement** the signatures above; update pattern matches that destructure the old three-value `bar` (`CardView.swift`, tests) to the new arity; `height(of:)` adds `barSubHeight` when `sub != nil`; `BarItem`/`RowItem` call `labelBudget` instead of the literals `width - 120` / `width - 110` and draw `sub` as 11 pt grey text under the bar. Chevron drawing is PR 4.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "foundation: label extras, bar sub line, label budget" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"`.

### Task 0.2: Measuring, wrapping, context, result entry point

**Files:**
- Modify: `Sources/TrackerCore/PanelModel.swift` (`buildPanel`), `Sources/TrackerCore/PanelModel+TextWrap.swift`
- Create: `Sources/ClaudeTracker/TextMeasure.swift`
- Test: `Tests/TrackerCoreTests/PanelModelTests.swift`

**Interfaces:**
- Produces: `public enum LabelWeight { case regular, semibold }`; `public typealias TextMeasure = (_ text: String, _ size: CGFloat, _ weight: LabelWeight) -> CGFloat`; `public struct PanelContext` with `open: [String: Bool] = [:]`, `measure: TextMeasure = { _,_,_ in 0 }` (later PRs add `identities`, `selectedDay`, `hooks`, `hooksExpanded`); `public struct RowInfo { var path: String? }`; `PanelModel.buildPanelResult(..., context: PanelContext = PanelContext()) -> (tabs: [Tab], rows: [String: RowInfo])`; `buildPanel` becomes a wrapper returning `.tabs`; `PanelModel.wrapMeasured(_ text: String, width: CGFloat, size: CGFloat, measure: TextMeasure) -> [String]`; `TextMeasure.live` (app target, `NSString.size(withAttributes:)`).

- [ ] **Step 1: Failing tests**: `buildPanelWrapperMatchesResultTabs` (same tabs from both); `wrapMeasuredBreaksWideWordsByCharacter` (stub 7 pt/char, width 28: `"abcdefghij kl"` gives `["abcd","efgh","ij","kl"]`; empty text gives `[]`); `stubMeasureBoundaryAtBudgetMinusOne` (helper `isCutOff(width, budget)` per D6: 191 not cut and 192 cut at budget 192; 177/178 at chevron budget 178; row 187/188 at 188).
- [ ] **Step 2: Run** `./test.sh --filter buildPanelWrapperMatchesResultTabs`. Expected: FAIL (undefined).
- [ ] **Step 3: Implement** the signatures. `wrapMeasured` breaks at spaces, and by character for a word wider than the line. Cut-off helper `PanelLayout.isCutOff(text:, size:, weight:, budget:, measure:) -> Bool` (`measure > budget - 1`). `TextMeasure.live` uses the same font size/weight as `LabelText`.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** as in 0.1 (`foundation: text measure, wrapMeasured, PanelContext`).

### Task 0.3: Open rows, `toggle_row`, scroll keeping

**Files:**
- Create: `Sources/TrackerCore/OpenRows.swift`
- Modify: `Sources/TrackerCore/AppAction.swift`, `Sources/ClaudeTracker/AppController.swift` (`openRows`, toggle handling, pass `context`, clear in `onWillShow`, set `onTabChange`), `Sources/ClaudeTracker/Panel/PanelController.swift` (`draw()` keeps scroll offset), `README.md`
- Test: `Tests/TrackerCoreTests/OpenRowsTests.swift` (create), `Tests/TrackerCoreTests/AppActionTests.swift`

**Interfaces:**
- Produces: `OpenRows.toggle(_ open: inout [String: Bool], id: String, path: String?, fileExists: (String) -> Bool)`; `OpenRows.prune(_ open: inout [String: Bool], present: Set<String>)`; `AppAction.toggleRow(id: String)` parsed from `toggle_row:<id>` (split on the first colon only).

- [ ] **Step 1: Failing tests**: `parsesToggleRow` (`toggle_row:limit:claude_code:weekly` gives `.toggleRow(id: "limit:claude_code:weekly")`); `toggleRowIdWithColons`; `openRowsToggleUsesInjectedFileExists` (open stores `true` when closure says yes, `false` when path nil; second toggle removes); `pruneDropsUnknownIds`.
- [ ] **Step 2: Run** `./test.sh --filter parsesToggleRow`. Expected: FAIL.
- [ ] **Step 3: Implement** the signatures; `AppController` passes `FileManager.default.fileExists` with `~` expanded via `UsageStats.homeDirectory`, prunes against `rows.keys` in `renderPanel`, clears `openRows` in `onWillShow` and in `onTabChange` (redraw scheduled on the next run-loop turn only when something was cleared; must not re-enter `selectTab`). `PanelController.draw()` records the selected tab's scroll offset and restores it when the tab key is unchanged. README layout rows for `OpenRows.swift`, `TextMeasure.swift`.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`foundation: open rows and toggle_row`).

### Task 0.4: Open PR 0

- [ ] **Step 1:** `./test.sh`; expected all pass.
- [ ] **Step 2:** `git push -u origin 3.1/00-foundation`
- [ ] **Step 3:** `gh pr create --repo raymondtian30/claude-tracker --base master --title "3.1 foundation: item data, label budget, open rows" --body "<what and why, tests run, no visible change>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`. The orchestrator merges it after the tests pass.

---

## PR 1: milestone alerts (Change 9)

Branch `3.1/01-milestone-alerts`, base `master` (independent of PR 0). Touches `Limits.swift`, `AppState+Changes.swift` (also PRs 2, 6, 9). Delivers CUJ 8.

### Task 1.1: Fallback Opus/Sonnet kinds

**Files:** Modify `Sources/TrackerCore/Limits.swift` (`reachedClaudeLimits`); Test `Tests/TrackerCoreTests/LimitsTests.swift` (`claudeLimitReachedUntilItResets`, `planLevelsGiveEachClaudeLimitItsOwnId`).

**Interfaces:** Produces `Limits.claudeLimitKinds: [String: String]` mapping the hit key to kind (`weekly_opus`, `weekly_sonnet`); fallback levels carry `kind`.

- [ ] **Step 1: Failing tests:** update the expected `Level`s in `claudeLimitReachedUntilItResets` (kinds added) and add `fallbackOpusAndSonnetIdsMatchFetched` (ids `claude_code:weekly_opus`, `claude_code:weekly_sonnet`, plain weekly stays `claude_code:weekly`).
- [ ] **Step 2: Run** `./test.sh --filter fallbackOpusAndSonnetIdsMatchFetched`. Expected: FAIL.
- [ ] **Step 3: Implement** `claudeLimitKinds` and set `Level.kind` in `reachedClaudeLimits`.
- [ ] **Step 4: Run** `./test.sh --filter LimitsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`alerts: fallback Opus/Sonnet levels carry their kind`).

### Task 1.2: Carry keys and seed on first pass

**Files:** Modify `Sources/TrackerCore/Limits.swift`; Test `Tests/TrackerCoreTests/LimitsTests.swift`.

**Interfaces:**
- Produces: `Limits.alertsToSend(_ levels: [Level], thresholds: [Int], windowsOn: [String], above: [String], seeding: Bool = false, unknownIDPrefixes: Set<String> = [], now: Double? = nil) -> (messages: [String], above: [String])`; `static func unknownIDPrefixes(_ state: JSONObject, now: Double) -> Set<String>`.

- [ ] **Step 1: Failing tests** (spec PR 1 list): `keySurvivesPassWhereLevelIsMissingAndUnknown` (key `claude_code:weekly@75` kept when prefix `claude_code:` is unknown and the level is absent); `launchWithLevelOverThresholdSendsNothing` (`seeding: true`, 80% level, `above: []`: `messages == []`, `above` contains `@50`,`@75`); `seedingWritesKeysButSendsNothing`; `crossingAfterSeedingSends`; `fallbackLevelFirstSeenAfterLaunchAlerts`; `fallbackHitResetHitAgainAlerts`; `emptyFetchWithPercentagesOffDropsKeys`; `fetchedLevelVanishingDropsKeys`; `dropBelowThenCrossSendsAgain`; `resetToZeroClearsKeys`; `toolDisabledKeepsKeys`; `switchOffThenOnSendsNothingWhenKeyPresent`; `severalThresholdsGiveOneMessage`; `unknownPrefixesFromState` (four cases: tool disabled, Percentages on with empty fetch, Percentages off gives none, no Codex record).
- [ ] **Step 2: Run** `./test.sh --filter launchWithLevelOverThresholdSendsNothing`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec Change 9 rules 1-4: present and switched on, keys become `newAbove` and message unless `seeding` or all keys already in `above`; an old key whose level is not present-and-on is kept when its id is present with the switch off or its prefix is in `unknownIDPrefixes`, otherwise dropped. `unknownIDPrefixes` implements rules 2(a), 2(c), 2(d).
- [ ] **Step 4: Run** `./test.sh --filter LimitsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`alerts: carry keys while a level is unknown, seed on the first pass`).

### Task 1.3: Wiring, fetch-error test, README

**Files:** Modify `Sources/TrackerCore/AppState+Changes.swift` (`checkAlerts(_ state: inout JSONObject, now: Double, seeding: Bool = false) -> (messages: [String], changed: Bool)`), `Sources/ClaudeTracker/AppController.swift` (`alertsSeeded`), `Sources/ClaudeTracker/AppController+Alerts.swift`, `README.md` (alerts paragraph: no repeat at launch); Test `Tests/TrackerCoreTests/AppStateChangesTests.swift`.

- [ ] **Step 1: Failing tests:** `fetchErrorCarriesKeys` (state with `claude_usage` limits empty, Percentages on, `alerts_above` holds keys: after `checkAlerts` the keys remain and no message); `checkAlertsSeedingSendsNothingAndSavesKeys`; `reachedLimitAlertsOnceAndIsRemembered` stays valid unchanged.
- [ ] **Step 2: Run** `./test.sh --filter fetchErrorCarriesKeys`. Expected: FAIL.
- [ ] **Step 3: Implement** passing `seeding` and `unknownIDPrefixes` through; `AppController+Alerts.checkAlerts` computes `let seeding = !alertsSeeded; alertsSeeded = true` (set whether or not "Notify me" is on).
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`alerts: no repeat alerts at launch`).

### Task 1.4: Open PR 1

- [ ] **Step 1:** `./test.sh` passes. **Step 2:** `git push -u origin 3.1/01-milestone-alerts`. **Step 3:** `gh pr create --repo raymondtian30/claude-tracker --base master --title "Alerts: no repeats after launch (Change 9)" --body "<root cause: keys lost when a level is missing for a pass; fix; risks kept>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`. Orchestrator merges after tests pass; manual check 9 (launch with network off sends no alert) recorded in the PR.

---

## PR 2: names (Change 1)

Branch `3.1/02-names`, base `master`, after PR 1 merges (same `alertsToSend`). Delivers CUJ 1.

### Task 2.1: `displayName`

**Files:** Modify `Sources/TrackerCore/Limits.swift`; Test `Tests/TrackerCoreTests/LimitsTests.swift`.
**Interfaces:** Produces `Limits.displayName(_ level: Level) -> String`.

- [ ] **Step 1: Failing test** `displayNameAllTools` with exact results: claude five_hour `"Claude Code (5-hour)"`, weekly `"Claude Code (Weekly)"`, kind `weekly_opus` `"Claude Code (Weekly, Opus)"`, `weekly_sonnet` `"... Sonnet)"`, unknown kind `"foo"` ignored, codex monthly `"Codex (Monthly)"`, codex weekly `"Codex (Weekly)"`, nil kind, empty `name` falls back to tool name from id prefix then the prefix. Also `savedLabelAndLevelIdUnchanged` (`Level.id`, saved `label` unchanged).
- [ ] **Step 2: Run** `./test.sh --filter displayNameAllTools`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec: window text from `windowLabels[window]` else `label`; suffix from `kind` starting with `window + "_"`, words capitalised.
- [ ] **Step 4: Run** same filter. Expected: PASS.
- [ ] **Step 5: Commit** (`names: Limits.displayName`).

### Task 2.2: Use it in the panel and notifications

**Files:** Modify `Sources/TrackerCore/Limits.swift` (message), `Sources/TrackerCore/PanelModel+Tabs.swift` (`limitsTab`), `README.md`; Test `PanelModelLimitsTests.swift`, `LimitsTests.swift`, `AppStateChangesTests.swift`.

- [ ] **Step 1: Failing tests:** `limitsTabUsesDisplayNameInAllViews` (bar label `"Codex (Monthly)"` in All AIs and Codex view, value `"80%"`, `sub == "Resets Nov 20"`); `subTextAndNilCases` (`resetsAt` nil or 0 gives `sub == nil`; reached gives value `"Reached"`); `notificationTextMonthly` (`"Codex (Monthly) usage is at 80%. Resets on Nov 20."`). Rewrite the about 15 `"Codex: 5-hour usage is at"`/`"Claude Code: ..."` assertions in `LimitsTests` and `reachedLimitAlertsOnceAndIsRemembered` (`hasPrefix("Claude Code (5-hour) usage...")`).
- [ ] **Step 2: Run** `./test.sh --filter notificationTextMonthly`. Expected: FAIL.
- [ ] **Step 3: Implement:** every limit bar label is `displayName(level)`; `sub = "Resets \(formatReset)"`; row id `limit:<level id>` recorded for PR 4. Message `"\(displayName(level)) usage is at N%."` plus existing reset suffix. Switch labels, note prefixes, test alert text untouched.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`names: one name in panel and notifications`).

### Task 2.3: Open PR 2

- [ ] `./test.sh`; `git push -u origin 3.1/02-names`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Limits: one consistent name (Change 1)" --body "<summary, text changes, no migration>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 3: FAQ (Change 7)

Branch `3.1/03-faq`, base `master`, after PR 0. Delivers CUJ 10.

### Task 3.1: `Item.heading` and shared label constants

**Files:** Modify `PanelItems.swift` (`Item.heading(String)`, `kind` `"heading"`), `PanelLayout.swift` (heading 18 pt; `trackingLabel = "Tracking"` used by `toolPicker`), `PanelModel.swift` (`aiToolsTitle = "AI tools"`, `claudeUsageSwitchLabel = "Percentages from Anthropic"`), `PanelModel+Settings.swift` (`toolsCard` and the inline General card use them), `Panel/ItemViews.swift`, `Panel/CardView.swift` (`HeadingItem`, semibold 12 pt); Test `PanelLayoutTests.swift`.

- [ ] **Step 1: Failing test** `headingHeight` (== 18; kind `"heading"`).
- [ ] **Step 2: Run** `./test.sh --filter headingHeight`. Expected: FAIL.
- [ ] **Step 3: Implement** as listed.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`faq: heading item and shared label constants`).

### Task 3.2: FAQ card

**Files:** Modify `PanelModel+Settings.swift` (`faqEntries: [(question: String, answer: String)]`, card "FAQ" appended last in `settingsTab`), `README.md` (Settings description); Test `PanelModelTests.swift`.

- [ ] **Step 1: Failing tests:** `faqCardIsLastInSettings`; `faqLinesWithinNoteWidth` (answers wrapped with `PanelModel.wrap(_, width: noteWidth)` as `.note`, each question a `.heading`); `faqUsesUiConstants` (questions contain `PanelLayout.trackingLabel`, `aiToolsTitle`, `claudeUsageSwitchLabel`, `Providers.providerNames["anthropic"]`, `Tools.toolNames["claude_code"]`); `faqAnthropicAnswerMatchesProviderView` (answer 2 contains `claude-` and every tool name; `Providers.providerOf("claude-opus") == "anthropic"`).
- [ ] **Step 2: Run** `./test.sh --filter faqUsesUiConstants`. Expected: FAIL.
- [ ] **Step 3: Implement** the five entries from spec Change 7, text built from the constants.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`faq: FAQ card in Settings`).

### Task 3.3: Open PR 3

- [ ] `./test.sh`; `git push -u origin 3.1/03-faq`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Settings: FAQ card (Change 7)" --body "<summary>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 4: cut-off names (Change 2)

Branch `3.1/04-cutoff-names`, base `master`, after PRs 0 and 2. Delivers CUJ 2.

### Task 4.1: `Item.detail` and its height

**Files:** Modify `PanelItems.swift`, `PanelLayout.swift`; Test `PanelLayoutTests.swift`.
**Interfaces:** Produces `Item.detail(id: String, lines: [String], button: Item.Button?)` with `struct Button { var title: String; var action: String }`; height `4 + 14 * lines.count + (button != nil ? 30 : 0)`.

- [ ] **Step 1: Failing tests:** `detailHeightOneLine` (18); `detailHeightTwoLinesAndButton` (62).
- [ ] **Step 2: Run** `./test.sh --filter detailHeightOneLine`. Expected: FAIL.
- [ ] **Step 3: Implement** the case, `kind` `"detail"`, height rule.
- [ ] **Step 4: Run** `./test.sh --filter PanelLayoutTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`cutoff: detail item`).

### Task 4.2: Cut-off detection and insertion in the Limits tab

**Files:** Modify `PanelModel+Tabs.swift` (`limitsTab`), `README.md`; Test `PanelModelLimitsTests.swift`.

- [ ] **Step 1: Failing tests** with the 7 pt/char stub measure (full label `"Claude Code (Weekly, Sonnet)"` = 28 chars = 196 pt): `cutOffAtBudgetBoundary` (a 27-char label = 189 not cut, a 28-char label cut; boundary 191/192 pt); `chevronBudgetBoundary` (rows with a chevron for another reason: 177 not cut, 178 cut); `openRowInsertsDetail` (id in `context.open`: item after the bar is `.detail(id: "limit:<id>", lines: wrapMeasured(full label), button: nil)` and the bar has `isOpen: true`, `expandID`, `tip`); `closedRowHasNoDetail`; `openIdPrunedWhenRowGone` (id absent from `rows` keys after `buildPanelResult`); `toggleRowUsesPr0Action` (no new action added).
- [ ] **Step 2: Run** `./test.sh --filter cutOffAtBudgetBoundary`. Expected: FAIL.
- [ ] **Step 3: Implement:** for each limit bar compute the cut-off with `PanelLayout.isCutOff` (plain budget, since only a cut-off bar gets a chevron); if cut off set `extras.expandID/tip`; if open set `isOpen` and insert the detail. Report row ids in `rows` from `buildPanelResult`.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`cutoff: chevron and detail for cut-off limit names`).

### Task 4.3: `ChevronLabel` view

**Files:** Modify `Sources/ClaudeTracker/Panel/Style.swift` (`ChevronLabel`), `ItemViews.swift`, `CardView.swift` (draw `detail`, use `ChevronLabel` when `expandID != nil`).

- [ ] **Step 1:** no unit test (AppKit/SwiftUI drawing, checked by eye); describe the checks in Step 4.
- [ ] **Step 2:** `./test.sh` (expected PASS, nothing regresses).
- [ ] **Step 3: Implement** `ChevronLabel`: whole row is a button calling `onAction("toggle_row:<id>", .none)`; `chevron.down` 11 pt secondary rotating 180 degrees when open; `.help(tip)`; `.accessibilityLabel(tip)` with expanded/collapsed value; width `labelBudget(kind:hasChevron: true)`.
- [ ] **Step 4: Verify** by eye in a scratch build (see Whole-branch verification for the run recipe): checks 1, 6, 7 from the spec recorded pass/fail in the PR body.
- [ ] **Step 5: Commit** (`cutoff: ChevronLabel view`).

### Task 4.4: Open PR 4

- [ ] `./test.sh`; `git push -u origin 3.1/04-cutoff-names`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Limits: click a cut-off name to read it (Change 2)" --body "<summary, manual checks 1, 6, 7>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 5: project rows, Finder, fold fix (Change 3)

Branch `3.1/05-project-rows`, base `master`, after PR 4. Delivers CUJ 3, CUJ 11.

### Task 5.1: Fold-parent guard

**Files:** Modify `Sources/TrackerCore/UsageStats.swift` (`foldSubfolders`); Test `UsageStatsTests.swift`.

- [ ] **Step 1: Failing tests:** `foldSkipsHomeAndRoot` (labels `~`, `~/a`, `~/b`: three separate rows); `homeRowIsSeparate`; `foldStillFoldsRealSubfolders` (`~/a` + `~/a/b` fold into `~/a`; `/Users/x` home with trailing slash, `/`, `Unknown`, empty never become parents).
- [ ] **Step 2: Run** `./test.sh --filter foldSkipsHomeAndRoot`. Expected: FAIL.
- [ ] **Step 3: Implement** the guard: not a parent when trimmed text is empty or equals `~`, `/`, `UsageStats.homeDirectory`, `Unknown`.
- [ ] **Step 4: Run** `./test.sh --filter UsageStatsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`projects: home and root are never fold parents`).

**Shipped separately** as `fix/projects-fold-home` (guard: `~`, `/` and empty after trimming slashes). Not repeated in PR 5. The home-directory and `Unknown` checks listed above were dropped because `projectLabel` never produces them.

### Task 5.2: `ProjectNames`

**Files:** Create `Sources/TrackerCore/ProjectNames.swift`, `Tests/TrackerCoreTests/ProjectNamesTests.swift`.
**Interfaces:** Produces `ProjectNames.labels(for paths: [String]) -> [Entry]`; `struct Entry { var name: String; var greyTail: String?; var fullName: String; var path: String? }`.

- [ ] **Step 1: Failing tests:** `uniqueNamesNoTail`; `sameNameParentsGetGreyTail` (`~/Games/FPS Game/assets`, `~/Games/Robot/assets` give name `assets`, tails `FPS Game`, `Robot`, display `assets · FPS Game`); `threeLevelsDeep` (parents added one at a time until unique); `identicalPathsNotACollision`; `homeAndUnknownAndSlug` (`~` gives `Home (~)` path `~`; `Unknown` and `my-slug` have `path == nil`); `geminiRealPathHasPath`; **RF** `oddFolderLabels` (trailing slash `~/a/`, spaces, non-ASCII `~/café`, names differing only in case: non-empty names, stable output, `path` set).
- [ ] **Step 2: Run** `./test.sh --filter sameNameParentsGetGreyTail`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec Change 3 Names (last path component, group by name, add parents nearest first).
- [ ] **Step 4: Run** `./test.sh --filter ProjectNamesTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`projects: ProjectNames`).

### Task 5.3: Rows in Projects and Live tabs

**Files:** Modify `PanelModel+Tabs.swift`, `ActiveSessions.swift` (`runningToolSessions` sets `cwd` for Codex/opencode), `PanelModel.swift`; Test `PanelModelTests.swift`, `ActiveSessionsTests.swift`.

- [ ] **Step 1: Failing tests:** `liveRowsUseCwdForClaudeCodexOpencode`; `revealBoolFromOpenRows` (row with a path and `context.open[id] == true` gets a `Show in Finder` button with action `reveal:<id>`; `false` gives no button; the folder path is in `rows[id].path`); `unknownRowHasNoButton` (and no chevron unless cut off); path rows always have a chevron and use the chevron budget; Leaderboard tab never offers the button. Ids: `project:<full label>`, `session:<log path>` / `session:<tool>:<label>#<n>`.
- [ ] **Step 2: Run** `./test.sh --filter revealBoolFromOpenRows`. Expected: FAIL.
- [ ] **Step 3: Implement** with `ProjectNames` feeding label, `greyTail`, `tip`; detail lines = full name if cut off, full path wrapped by measure, button only when allowed.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`projects: folder-name rows with full path`).

### Task 5.4: `reveal` action, handler, grey tail view, README

**Files:** Modify `AppAction.swift`, `AppController.swift`, `Panel/ItemViews.swift` (grey tail in `LabelText`/`ChevronLabel`), `README.md` (paths on screen only, Gemini sentence, layout row `ProjectNames.swift`); Test `AppActionTests.swift`.

- [ ] **Step 1: Failing test** `parsesReveal` (`reveal:project:~/a` gives `.reveal(id: "project:~/a")`, split on the first colon).
- [ ] **Step 2: Run** `./test.sh --filter parsesReveal`. Expected: FAIL.
- [ ] **Step 3: Implement** `AppAction.reveal(id:)`; handler re-checks existence (gone: close the row), otherwise closes the panel first, then calls `NSWorkspace.activateFileViewerSelecting` with the path from the last `rows` result (`~` expanded via `UsageStats.homeDirectory`).
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS. Record manual check 4 in the PR.
- [ ] **Step 5: Commit** (`projects: Show in Finder`).

### Task 5.5: Open PR 5

- [ ] `./test.sh`; `git push -u origin 3.1/05-project-rows`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Projects: folder names, full path, Show in Finder (Change 3)" --body "<summary incl. home-folding fix, check 4>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 6: accounts and Show only (Change 4)

Branch `3.1/06-accounts`, base `master`, after PRs 0, 3, 4. Delivers CUJ 4. Largest PR; the filter (Task 6.5) is the cut line (D28) if it slips. Touches `CodexSource.swift` (also PR 7) and `Limits.swift`.

### Task 6.1: Digest and per-file Codex account

**Files:** Create `Sources/TrackerCore/Identities.swift`, `Tests/TrackerCoreTests/IdentitiesTests.swift`; Modify `CodexSource.swift`; Test `CodexSourceTests.swift`.
**Interfaces:** Produces `Identities.digest(_ id: String) -> String` (first 12 hex of SHA-256, CryptoKit); `CodexSource.fileVersion = 2`; per-file entry gains `"v": 2` and `"account": <digest or null>`; a file is re-read unless `(saved["v"] as Int ?? 1) >= fileVersion`; `Identities.accounts(_ codexState: JSONObject) -> [Identities.Account]` (`digest`, `name` "Account n", `tokens`, `firstDay`, `lastDay`) plus the Unattributed bucket.

- [ ] **Step 1: Failing tests:** `digestIs12HexAndRawIdAbsentFromState` (sentinel id `sentinel-acct-123` never in the serialised state); `twoIdsAcrossFiles`; `nullIdIsUnattributed`; `orderingAndNaming` (earliest day first, ties by digest); `v1FileReadOnceAndReplacedNoDoubleCount` (a file with no `v` is re-read, totals equal a fresh read).
- [ ] **Step 2: Run** `./test.sh --filter twoIdsAcrossFiles`. Expected: FAIL.
- [ ] **Step 3: Implement** reading `session_meta.payload.creator_account_id` in `readCodex`; the re-read rule; `accounts(_:)`.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`accounts: per-file Codex account digest`).

### Task 6.2: `codexLatest` and scope on views

**Files:** Modify `CodexSource.swift`, `Tools.swift`, `Providers.swift`, `AppState+Changes.swift` (`currentView`), `AppState+Launch.swift`; Test `CodexSourceTests.swift`, `ToolsTests.swift`, `ProvidersTests.swift`, `AppStateLaunchTests.swift`, `AppStateTests.swift`.
**Interfaces:** Produces `CodexSource.codexLatest(_ sourceState: JSONObject, account: String? = nil) -> (at: String, rateLimits: JSONObject)?` (`codexRateLimits` wraps it); `enum AccountScope { case all; case only(String) }`; scope parameter on `CodexSource.codexDaily/codexTotal`, `Tools.toolView(state, key, scope)`, `Tools.combinedView(state, enabled:, scope:)`, `Providers.providerView(state, key, scope:)`; `state["account_scope"]` default `nil`.

- [ ] **Step 1: Failing tests:** `scopeFiltersCodex`; `unattributedOnlyInAll`; `combinedViewUnderScopeExcludesOtherTools` (excluded tool names listed); `providerViewUnderScope`; `nonCodexToolViewUnfilteredWithNote`; `menuBarCountScoped`; `vanishedDigestResetsToAll`; `scopeClearedWithFewerThanTwoIdentities`; **RF** `wrongTypedAccountScopeReadsAsAll` (`account_scope` = `7` or `["x"]`); `lastSeenLimitsForOtherAccount`; `signedInLimitsUseThatAccountsNewestFile` (falls back to global newest only when the signed-in digest is unknown); `alertsUnchangedByScope` (`Limits.planLevels` ignores scope).
- [ ] **Step 2: Run** `./test.sh --filter scopeFiltersCodex`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec scope semantics (D36); `currentView` reads scope from state.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`accounts: scope on tool, combined and provider views`).

### Task 6.3: Signed-in readers and privacy tests

**Files:** Modify `Identities.swift`, `README.md`; Create `Sources/ClaudeTracker/AppController+Identities.swift` (mtime+size caches); Test `IdentitiesTests.swift`, `LeaderboardTests.swift` (or `GistSyncTests.swift`).
**Interfaces:** Produces `enum CodexSignIn { case account(String), apiKey, none, unreadable }`; `Identities.codexSignedIn(authFile: String) -> CodexSignIn`; `Identities.claudeSignedIn(file: String) -> (email: String, displayName: String)?` (skip over 20 MB).

- [ ] **Step 1: Failing tests:** `authApiKeyMode`; `authMissingAndMalformed` (`.none`, `.unreadable`, no content echoed); `authFixtureSentinelsNeverReachState` (sentinel `id_token`, `access_token`, `refresh_token` values, raw account id absent from serialised state); `claudeJsonFixtureAndSkipOver20Mb`; `sentinelEmailAbsentFromStateAndGist`; `gistPayloadHasExactlyFourKeys` (`name`, `total_tokens`, `yesterday_tokens`, `updated_at`); `leaderboardTotalUnchangedByScope`.
- [ ] **Step 2: Run** `./test.sh --filter authApiKeyMode`. Expected: FAIL.
- [ ] **Step 3: Implement** both readers (read into memory, keep only `tokens.account_id` digest and `auth_mode`; `oauthAccount.emailAddress` and `displayName`); no `log(...)` of contents; README: reword the "never touches credential tables" sentence to name the exact fields and files; privacy list entries.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`accounts: signed-in readers, privacy tests`).

### Task 6.4: Accounts card and FAQ entry

**Files:** Modify `PanelModel.swift` (`PanelContext.identities: Identities.Snapshot?`), `PanelModel+Tabs.swift` (Accounts card below Plan limits), `PanelModel+Settings.swift` (FAQ "What does \"Show only\" do?"), `Limits.swift` (`planLevels` uses `codexLatest(account: signed-in digest)`), `README.md` (Limits tab text, layout row `Identities.swift`); Test `PanelModelTests.swift`, `LimitsTests.swift`.

- [ ] **Step 1: Failing tests:** `accountsCardRowsPerTool` (Codex rows "Account 1 ····ab12 (signed in)", "Account 2", "Unattributed" with note "Older sessions don't record the account."; Claude Code shows email; Gemini CLI "Not available for Gemini CLI."; opencode "Not available for opencode."); `noCodexIdsMessage` ("No account ids in Codex logs yet."); `lastSeenSubOnOtherAccountLimits` (`"Last seen Nov 4, 3:10 PM"`); `faqShowOnlyEntry`.
- [ ] **Step 2: Run** `./test.sh --filter accountsCardRowsPerTool`. Expected: FAIL.
- [ ] **Step 3: Implement** the card from the spec table; account row ids `account:<digest>`.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`accounts: Accounts card on the Limits tab`).

### Task 6.5: "Show only" picker and action

**Files:** Modify `AppAction.swift` (`select_account` index), `PanelLayout.swift` (`contentTop(hasToolPicker:hasScopePicker: Bool = false)`), `Panel/PanelChromeView.swift`, `Panel/PanelController.swift` (second popup, header " · Account 2 only"), `AppController.swift` / `AppController+Identities.swift` (scope selection, persist `account_scope`); Test `PanelLayoutTests.swift`, `AppActionTests.swift`.

- [ ] **Step 1: Failing tests:** `parsesSelectAccount`; `contentTopWithScopePicker` (adds `toolPickerHeight`); `tabCountAndPickerPresence` (popup only with two or more identities).
- [ ] **Step 2: Run** `./test.sh --filter contentTopWithScopePicker`. Expected: FAIL.
- [ ] **Step 3: Implement** the popup ("All accounts" then each identity) with help "Does not change which account Codex uses."; header text only when the shown view is scoped Codex data.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`accounts: Show only filter`).

### Task 6.6: Open PR 6

- [ ] `./test.sh`; `git push -u origin 3.1/06-accounts`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Accounts card and Show only filter (Change 4)" --body "<summary, new reads (auth.json, .claude.json), digest only on disk, README edited>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 7: effort (Change 6)

Branch `3.1/07-effort`, base `master`, after PR 6 (shares `readCodex` and `fileVersion`). Delivers CUJ 6, CUJ 12.

### Task 7.1: Codex effort

**Files:** Modify `CodexSource.swift` (`fileVersion = 3`), `UsageStats.swift` (`addUsage(... effort: String? = nil)`); Test `CodexSourceTests.swift`.

- [ ] **Step 1: Failing tests:** `codexEffortSplitsPerTurn` (effort `medium` then `high` mid-file: `efforts["gpt-5.6-luna"] == ["medium": a, "high": b]`, sums equal the model total); `codexAbsentEffort` (no `efforts` key); `codexFallsBackToCollaborationEffort`; `normalisesEffort` (`" HIGH "` gives `high`; `"x y"` and 13 chars give absent); `modelKeyAndPricingUnchanged`; `v2FileReadOnceMoreForV3`.
- [ ] **Step 2: Run** `./test.sh --filter codexEffortSplitsPerTurn`. Expected: FAIL.
- [ ] **Step 3: Implement** normalising `[a-z0-9_-]{1,12}`; running effort on each `turn_context` (`payload.effort`, then `collaboration_mode.settings.reasoning_effort`, else previous).
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`effort: Codex effort per turn`).

### Task 7.2: Claude effort and backfill

**Files:** Modify `UsageStats.swift` (`recordEntry`), `TokenMath.swift` (`backfillEfforts`), `AppState+Launch.swift` (`efforts_backfilled` false); Test `UsageStatsTests.swift`, `TokenMathTests.swift`, `AppStateLaunchTests.swift`.
**Interfaces:** Produces `TokenMath.backfillEfforts(_ state: inout JSONObject, ...)` guarded by `state["efforts_backfilled"]`, copying only `efforts` into buckets that have none.

- [ ] **Step 1: Failing tests:** `claudeEffortField`; `claudePerTurnEffortFallback`; `claudeBothPresentAndDifferent` (`effort` wins); `backfillEffortsOnce` (second run no-op, flag set; files gone leave plain rows); **RF** `wrongTypedEffortsReadAsNone` (`efforts` a string or array in a bucket).
- [ ] **Step 2: Run** `./test.sh --filter claudeEffortField`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec (read 0 to saved offset with the same entry parser into a scratch daily).
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`effort: Claude effort and one-time backfill`).

### Task 7.3: Merge, filter and read efforts

**Files:** Modify `UsageStats.swift` (`combineBuckets`, `filterDaily`, `effortsInRange(_:_:_:) -> [String: [String: Int]]`, `effortsAllTime(_:)`); Test `UsageStatsTests.swift`, `ProvidersTests.swift`.

- [ ] **Step 1: Failing tests:** `combineBucketsKeepsEffortsSumAndMax`; `filterDailyKeepsEfforts`; `effortsInRangeMatchesModelsInRange`.
- [ ] **Step 2: Run** `./test.sh --filter combineBucketsKeepsEffortsSumAndMax`. Expected: FAIL.
- [ ] **Step 3: Implement** nested sum for `.sum`, nested max for `.max`; `filterDaily` keeps efforts for kept models.
- [ ] **Step 4: Run** `./test.sh --filter UsageStatsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`effort: merge and filter effort maps`).

### Task 7.4: Models rows

**Files:** Modify `PanelModel.swift` (`PanelData.todayEfforts`, `lifetimeEfforts`), `PanelModel+Tabs.swift` (`modelsCard(_ title:, _ models:, efforts: [String: [String: Int]] = [:])`), `README.md` (privacy effort, Models tab text); Test `PanelModelTests.swift`.

- [ ] **Step 1: Failing tests:** `effortRowsSumToModelTotal` (labels `"gpt-5.6-luna (HIGH)"`, `"Opus 5.5 (XHIGH)"`, sorted by tokens); `effortSumClampedToModelTotal`; `remainderRowOnlyWhenPositive` (plain row `model total - sum`); no efforts gives the plain row as today; Cost tab totals unchanged.
- [ ] **Step 2: Run** `./test.sh --filter effortRowsSumToModelTotal`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec Display (clamp running sum; never "unknown").
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`effort: effort rows on the Models tab`).

### Task 7.5: Backup and start order

**Files:** Modify `AppController.swift` (`start`: after `loadState`, before `applyLaunchDefaults`, not on fresh install, copy to `state.json.pre-3.1.bak` once; then `backfillDaily`, `backfillLimits`, `backfillEfforts`, `scan`), `.gitignore`, pure helper `AppState.backupBeforeUpgrade(stateFile:fileExists:copy:)` in `AppState+Launch.swift`; Test `AppStateLaunchTests.swift`.

- [ ] **Step 1: Failing tests:** `backupCreatedOnceBeforeDefaults`; `backupSkippedOnFreshInstall`; `backfillRunsAfterBackfillDailyBeforeScan` (order checked through an injected call recorder); backup failure logs and continues.
- [ ] **Step 2: Run** `./test.sh --filter backupCreatedOnceBeforeDefaults`. Expected: FAIL.
- [ ] **Step 3: Implement** the helper with injected closures; wire it.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`effort: one-time state backup, start order`).

### Task 7.6: Open PR 7

- [ ] `./test.sh`; `git push -u origin 3.1/07-effort`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Models: show effort (Change 6)" --body "<summary, migration, rollback notes>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 8: graph (Change 5)

Branch `3.1/08-graph`, base `master`, after PRs 3, 5, 6, 7 (and 0). Delivers CUJ 5.

### Task 8.1: `dayBreakdown`

**Files:** Modify `UsageStats.swift`; Test `UsageStatsTests.swift`.
**Interfaces:** Produces `UsageStats.dayBreakdown(_ daily: JSONObject, day: String) -> (total: Int, models: [DayModelRow], projects: [NamedTotal])`; `struct DayModelRow { model: String; effort: String?; tokens: Int }`.

- [ ] **Step 1: Failing tests:** `dayBreakdownModelsOnly`; `dayBreakdownProjectsOnly`; `dayBreakdownEmpty`; `dayBreakdownEffortRows`; **RF** `zeroTokenDayDoesNotCrash` (day present with all zeros: total 0, empty lists).
- [ ] **Step 2: Run** `./test.sh --filter dayBreakdownModelsOnly`. Expected: FAIL.
- [ ] **Step 3: Implement** (`model_projects` not used).
- [ ] **Step 4: Run** `./test.sh --filter UsageStatsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`graph: dayBreakdown`).

### Task 8.2: Chart item, range, launch default

**Files:** Modify `PanelItems.swift` (`Item.chart(points: [Item.ChartPoint], caption: String, selected: String?, action: String)`; `ChartPoint { day: String; label: String; tokens: Int; partial: Bool }`), `PanelModel.swift` (`chartDays(from:) -> Int`), `PanelModel+Tabs.swift`, `AppAction.swift` (`chart_range:<index>`, `chart_day:<iso>`), `AppState+Launch.swift` (`chart_days` 14); Test `PanelModelTests.swift`, `AppActionTests.swift`, `AppStateLaunchTests.swift`.

- [ ] **Step 1: Failing tests:** `chartRangeClamp` (7, 14, 30 kept; anything else 14); **RF** `wrongTypedChartDaysReadsAs14` (`"30"` string, `nil`); `chartRangeIndexMapping` (0,1,2 to 7,14,30; 9 clamps to 14); `missingDayIsZero`; `partialForToday`; `ordinalLabels` (1st, 2nd, 3rd, 11th, 12th, 13th, 21st, `"Nov 7th"`); `chartDayActionParse`; `applyLaunchDefaultsChartDays`; segmented control options `["7 days","14 days","30 days"]`, card title "Last N days"; **RF** `allZeroAndSinglePointSeries`.
- [ ] **Step 2: Run** `./test.sh --filter chartRangeClamp`. Expected: FAIL.
- [ ] **Step 3: Implement** as above; update every `chart(values:caption:)` call site and test.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`graph: chart points, range control`).

### Task 8.3: Selected day and breakdown card

**Files:** Modify `PanelModel.swift` (`PanelContext.selectedDay: String?`, `breakdownShown = 5`), `PanelModel+Tabs.swift`, `AppController.swift` (`selectedChartDay` toggles; cleared on tab change, `onWillShow`, range change, day leaving range); Test `PanelModelTests.swift`.

- [ ] **Step 1: Failing tests:** `dayBreakdownTop5PlusRest` (7 models: 5 bars plus row `"2 more"`); breakdown card shows total row, "Models" and "Projects" headings, project names via `ProjectNames`, `Close` button action `chart_day:<iso>`, "No detail for this day"; `selectedDayClearedOnRangeChange`; `selectedDayClearedWhenLeavingRange`.
- [ ] **Step 2: Run** `./test.sh --filter dayBreakdownTop5PlusRest`. Expected: FAIL.
- [ ] **Step 3: Implement** the card after the chart card when a day is selected.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`graph: day breakdown card`).

### Task 8.4: Hover, click, accessibility, README

**Files:** Modify `Panel/ItemViews.swift` (`ChartItem`: `.onContinuousHover` with local `@State` index and label "Nov 7th · 1.2M", today "Nov 9th (today, so far)"; `SpatialTapGesture` calls `onAction("chart_day:<iso>")`; accessibility label "Tokens per day", value "Peak 1.2M", adjustable steps), `README.md` ("chart of the last 14 days" line); Test `PanelModelTests.swift`.

- [ ] **Step 1: Failing test** `chartAccessibilityStepsDays` (pure helper `PanelModel.neighbourDay(points:selected:step:) -> String`: starts from the last point when none selected, clamps at ends).
- [ ] **Step 2: Run** `./test.sh --filter chartAccessibilityStepsDays`. Expected: FAIL.
- [ ] **Step 3: Implement** helper and view; if hover does not work in the panel window, fall back to an `NSTrackingArea` through `NSViewRepresentable` (check 2).
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS. Record checks 2, 5 (fixtures; "not run on real history"), 6, 8.
- [ ] **Step 5: Commit** (`graph: hover, click, accessibility`).

### Task 8.5: Open PR 8

- [ ] `./test.sh`; `git push -u origin 3.1/08-graph`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Home graph: hover, click a day, 7/14/30 days (Change 5)" --body "<summary, checks 2, 5, 6, 8>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 9: pace alert (Change 8)

Branch `3.1/09-pace-alert`, base `master`, after PRs 1, 2, 3, 6. Delivers CUJ 7.

### Task 9.1: Level fields, `parseISO`, projection

**Files:** Modify `Limits.swift`; Test `LimitsTests.swift`.
**Interfaces:** Produces `Level.windowSeconds: Double? = nil`, `Level.sampledAt: Double? = nil`; `Limits.parseISO(_ text: String) -> Double?`; `Limits.codexLimits(_ rateLimits: JSONObject?, now: Double, sampledAt: Double? = nil)`; `Limits.paceProjection(_ level: Level, now: Double) -> Projection?` with `Projection { fraction, projected, runOutAt }`; Claude fetched levels set `windowSeconds` 18000 / 604800 and `sampledAt = claude_usage.fetched_at` (the 2592000 constant is dropped); `planLevels` passes `parseISO(latest.at)` from `codexLatest`.

- [ ] **Step 1: Failing tests:** `parseISOWithMilliseconds` (`"2026-11-09T12:00:00.123Z"`); `paceSteadyRateAlerts` (weekly, 40% elapsed, 70% used: `projected == 175`, projection non-nil); `paceFlatRateDoesNot`; `codexLimitsEqualityAfterNewFields` (existing equality tests updated); **RF** `paceUnusableWindow` (`windowSeconds` 0, `resetsAt` in the past, `percent` exactly 5 yields a projection, 4.9 nil, no divide by zero).
- [ ] **Step 2: Run** `./test.sh --filter paceSteadyRateAlerts`. Expected: FAIL.
- [ ] **Step 3: Implement:** `elapsed = windowSeconds - (resetsAt - now)`, `fraction = elapsed / windowSeconds`, `projected = percent / fraction`, `runOutAt = now - elapsed + elapsed * 100 / percent`; nil on any invalid input.
- [ ] **Step 4: Run** `./test.sh --filter LimitsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`pace: projection and level sample fields`).

### Task 9.2: Guards and message

**Files:** Modify `Limits.swift`; Test `LimitsTests.swift`.
**Interfaces:** Produces `Limits.paceMessage(_ level: Level, now: Double, calendar: Calendar) -> String?` (guards as constants in `Limits`).

- [ ] **Step 1: Failing tests:** `paceGuardFractionBelow20`; `paceGuardPercentBelow5`; `paceGuardProjectedBelow110`; `paceGuardUnder10MinutesLeft`; `paceReachedLevelNoAlert`; `paceStaleSampleNone` (Codex 20 min, Claude 15 min); `paceNilSampledAtNone`; `paceMessageSameDayAndLaterDay` (`"At your current pace, Codex (Weekly) may run out around Thu 4:15 PM, before it resets on Fri. This is an estimate."`; same day `"...around 4:15 PM, before it resets at 6:00 PM."`; 15-minute rounding).
- [ ] **Step 2: Run** `./test.sh --filter paceGuardFractionBelow20`. Expected: FAIL.
- [ ] **Step 3: Implement** the guard table from the spec; fixed weekday table with `Calendar(identifier: .gregorian)` in the local zone.
- [ ] **Step 4: Run** `./test.sh --filter LimitsTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`pace: guards and message`).

### Task 9.3: Pace pass, setting, FAQ, README

**Files:** Modify `AppState+Changes.swift` (pace pass after the threshold pass, skipped when `pace_alerts` off), `AppState+Launch.swift` (`pace_alerts` false, `pace_alerted` `[]`), `AppAction.swift` (`pace_alerts`), `PanelModel+Tabs.swift` (switch "Warn me if I'm on pace to run out" after "When usage reaches"), `PanelModel+Settings.swift` (FAQ "What is the pace warning?"), `README.md` (usage limits section); Test `AppStateChangesTests.swift`, `AppActionTests.swift`, `PanelModelLimitsTests.swift`, `AppStateLaunchTests.swift`.

- [ ] **Step 1: Failing tests:** `paceKeyIgnoresJitter` (1 s and 20 s `resetsAt` shifts keep key `pace:<id>@<Int(resetsAt/600)>`); `paceNewResetGivesNewKey`; `paceOneAlertPerWindow`; `paceAppendedToThresholdMessage` (single message, key recorded); `paceKeyRecordedOnlyWhenDelivered`; `paceNotifyOffOrSwitchOffNone`; `paceOffByDefault`; `paceAlertsAtLaunchWhenFresh`; keys with passed reset dropped; `parsesPaceAlertsAction`; `applyLaunchDefaultsPace`; **RF** `wrongTypedPaceAlertedReadsAsEmpty` (`pace_alerted` a dict).
- [ ] **Step 2: Run** `./test.sh --filter paceKeyIgnoresJitter`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec Dedup/Wiring; own key space, `alerts_above` untouched.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`pace: optional pace warning`).

### Task 9.4: Open PR 9

- [ ] `./test.sh`; `git push -u origin 3.1/09-pace-alert`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Optional pace warning, off by default (Change 8)" --body "<summary>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 10: hooks tab (Change 10)

Branch `3.1/10-hooks-tab`, base `master`, after PRs 0, 3, 4, 5. Delivers CUJ 9. `Plugins.swift` is not modified.

### Task 10.1: Parser and program names

**Files:** Create `Sources/TrackerCore/Hooks.swift`, `Tests/TrackerCoreTests/HooksTests.swift`.
**Interfaces:** Produces `Hooks.Entry { event; matcher: String?; type; program; arguments; statusMessage: String?; timeout: Double?; source: Source }`, `Hooks.Source { path; scopeLabel }`, `Hooks.Result { entries; problems; notRead: [String] }`, `Hooks.parse(_ json: Any?, source: Source) -> [Entry]`, `Hooks.programName(_ command: String) -> (program: String, arguments: String)`.

- [ ] **Step 1: Failing tests:** `parsesUserSettings`; `eventsSortedAndFileOrderKept`; `matcherMissing`; `programNameEnvPrefixQuotedAndPath` (`FOO="a b" $CLAUDE_PLUGIN_ROOT/hooks/x.sh --v` gives `x.sh`); `interpreterAddsScriptName` (`bash x.sh -c` gives `bash x.sh`; `node`, `python3`, `uv`, `env` likewise); `nonCommandTypeRow` (program is the type, "Type: prompt. Content not shown."); **RF** `malformedEntriesDoNotCrash` (`hooks` an array, `command` a number or missing, empty command, `matcher` a number: other entries still listed, no crash).
- [ ] **Step 2: Run** `./test.sh --filter parsesUserSettings`. Expected: FAIL.
- [ ] **Step 3: Implement** (quote-aware tokenizer for leading tokens only).
- [ ] **Step 4: Run** `./test.sh --filter HooksTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`hooks: parser and program names`).

### Task 10.2: Redaction and reveal caps

**Files:** Modify `Hooks.swift`; Test `HooksTests.swift`.
**Interfaces:** Produces `Hooks.redact(_ arguments: String) -> String`; `Hooks.revealLines(_ arguments: String, wrap: (String) -> [String]) -> [String]`.

- [ ] **Step 1: Failing tests:** `redactsSecretsOnReveal` with exact cases: `API_KEY="abc" run.sh` gives `API_KEY=••• run.sh`; `curl -H "Authorization: Basic Zm9v"` gives `Authorization: •••`; `tool -u me:hunter2` gives `-u •••`; `--pass hunter2` gives `--pass •••`; `://user:pass@host` gives `://•••@host`; a 40-char token, `sk-...`, `ghp_...` give `•••`; quoted values; `revealCappedAt8LinesAnd400Chars` (ellipsis, then "…" line); `noHookTextInState`.
- [ ] **Step 2: Run** `./test.sh --filter redactsSecretsOnReveal`. Expected: FAIL.
- [ ] **Step 3: Implement** the six steps in the spec's order; settings `env` blocks never read.
- [ ] **Step 4: Run** `./test.sh --filter HooksTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`hooks: redaction`).

### Task 10.3: Adapters

**Files:** Modify `Hooks.swift`; Test `HooksTests.swift`.
**Interfaces:** Produces `Hooks.read(tool: String, home: String, sessionFolders: [String], readFile: (String) -> Data?, fileExists: (String) -> Bool) -> Result`.

- [ ] **Step 1: Failing tests:** `disableAllHooksLine` ("Hooks in <file> are turned off by disableAllHooks"); `malformedFileProblem` ("Couldn't read ~/.claude/settings.json", no content echoed); `missingFileListedAsNotRead`; `pluginHooksWithShellAsyncAndPathManifest`; `projectSettingsOfSessionFolder`; `homeOrRootFolderSkippedAndDeduped`; `codexFilePresentAndAbsent` ("Read: ~/.codex/hooks.json (not found). Not read: hooks in config.toml and in plugins."); `notAvailableForGeminiAndOpencode` (spec texts).
- [ ] **Step 2: Run** `./test.sh --filter codexFilePresentAndAbsent`. Expected: FAIL.
- [ ] **Step 3: Implement** with injected reads; plugin manifest `hooks` path resolved like `Plugins`.
- [ ] **Step 4: Run** `./test.sh --filter HooksTests`. Expected: PASS.
- [ ] **Step 5: Commit** (`hooks: adapters for Claude Code, Codex, Gemini, opencode`).

### Task 10.4: Tab, ids, caps, captions

**Files:** Modify `PanelModel.swift` (Hooks tab after Live, before Leaderboard; `PanelContext.hooks: [String: Hooks.Result]`, `hooksExpanded: Set<String>`; never for provider views), `PanelModel+Tabs.swift` (`hooksTab`), `PanelLayout.swift` (`compactCaptions = ["Projects": "Folders"]`, `captions(_ tabs: [Tab], measure: TextMeasure) -> [String]`), `AppAction.swift` (`hooks_expand:<tool key>`); Test `PanelModelTests.swift`, `PanelLayoutTests.swift`, `AppActionTests.swift`.

- [ ] **Step 1: Failing tests:** `hooksTabPositionAndNoProviderView`; `capAt8ThenShowMore`; `hooksExpandedPerTool`; row id `hook:<tool>:<sha1 prefix 8 hex of source path>:<event>:<n>` stable across rebuilds; `nineTabCaptionsCompactWhenTheyFail` (stub measure; slot `336/9`; fails when `measure(short, 9, .semibold) > slot - 4`; "Projects" becomes "Folders"); `eightTabsNeverCompact`; `tabCountAllAisCodexClaude` (All AIs 8, Codex 8, Claude Code 8, 9 with Leaderboard on); `parsesHooksExpand`; reveal detail has wrapped redacted command, "Defined in: <path>", `Show in Finder` button (reuses `reveal:<id>`, never on provider views).
- [ ] **Step 2: Run** `./test.sh --filter hooksTabPositionAndNoProviderView`. Expected: FAIL.
- [ ] **Step 3: Implement** per spec Layout; top line and note copy exact from the spec.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`hooks: Hooks tab and nine-tab captions`).

### Task 10.5: App wiring and README

**Files:** Modify `AppController.swift` (read hooks live at render, only when the tab exists in the view; `hooksExpanded`; session folders from `Session.cwd`), `Panel/PanelChromeView.swift` (draw `captions` output), `README.md` (new reads only: `settings.local.json`, managed settings, `~/.codex/hooks.json`; tab list; layout row `Hooks.swift`).

- [ ] **Step 1:** no new unit test (wiring and drawing); `./test.sh` stays green.
- [ ] **Step 2: Implement** the wiring; no `state.json` keys; no logging of hook text.
- [ ] **Step 3: Verify** by eye per the verification section (Claude Code view with Leaderboard on: nine captions fit, check 3).
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** (`hooks: wire the tab, README`).

### Task 10.6: Open PR 10

- [ ] `./test.sh`; `git push -u origin 3.1/10-hooks-tab`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Hooks tab, read-only (Change 10)" --body "<summary, new reads, check 3>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`.

---

## PR 11: release

Branch `3.1/11-release`, base `master`, after PRs 0 to 10 are merged.

### Task 11.1: Version, credits, README, release notes

**Files:** Modify `Sources/TrackerCore/Version.swift` (`version = "3.1.0"`), `README.md` ("Current version" line, privacy section checked against the spec's Privacy review table, release notes), credits file via `scripts/update-credits.sh`; Test `Tests/TrackerCoreTests/CreditsTests.swift` (add `versionIs310`).

- [ ] **Step 1: Failing test** `versionIs310` (`Version.version == "3.1.0"`).
- [ ] **Step 2: Run** `./test.sh --filter versionIs310`. Expected: FAIL.
- [ ] **Step 3: Implement** the bump; run `scripts/update-credits.sh`; update README. Release notes list: notification text changes, no repeat alerts at launch, rollback can drop 3.1.0 per-file data until the next 3.1.0 launch re-reads logs, old Codex history is "Unattributed", new reads (Codex sign-in file, Claude sign-in file, hook files, effort, full paths on screen).
- [ ] **Step 4: Run** `./test.sh`. Expected: full suite PASS.
- [ ] **Step 5: Commit** (`release: 3.1.0`).

### Task 11.2: Open PR 11 and release

- [ ] `./test.sh`; `git push -u origin 3.1/11-release`; `gh pr create --repo raymondtian30/claude-tracker --base master --title "Release 3.1.0" --body "<summary, release notes>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"`. The orchestrator merges it after the tests pass and the whole-branch verification below is done, then publishes the GitHub release `v3.1.0`.

---

## Whole-branch verification (after all PRs merge)

Run from a fresh worktree of master, never the owner's clone and never `/Applications`.

- [ ] Build: `./build.sh --dest <scratch dir>` (scratch dir under the session scratchpad). Expected: bundle exists there.
- [ ] Prepare a scratch project folder with a copy of the 3.0.0 `state.json` (a copy, not the owner's file) plus a second fixture `state.json` with two Codex account digests and older files with none; run the built app against each (state file lives in the scratch app folder).
- [ ] First launch on the 3.0.0 copy: `state.json.pre-3.1.bak` exists, totals unchanged (no double counting), no alert at launch (manual check 9, network off), then run 3.0.0 against the migrated file to confirm it still reads it (rollback).
- [ ] Screenshot every changed tab and check against the spec's CUJs: Limits (CUJ 1 names and "Resets" sub line, CUJ 2 chevron open/closed, CUJ 4 Accounts card and "Show only" with "Account 2 only" header), Projects and Live (CUJ 3, CUJ 11, Finder button closes the panel first, check 4), Models (CUJ 6, CUJ 12 effort rows), Home (CUJ 5 hover, click, 30 days, breakdown top 5 plus "N more"), Hooks (CUJ 9: program names only, reveal masks secrets, Gemini/opencode "not available"; nine-tab captions fit, check 3), Settings (CUJ 10 FAQ with real labels; CUJ 7 pace switch).
- [ ] Record manual checks 1 to 9 pass/fail in the release PR; check 5 is "not run on real history" (fixtures only).
- [ ] If every item passes, the orchestrator merges PR 11 and publishes release `v3.1.0`.
