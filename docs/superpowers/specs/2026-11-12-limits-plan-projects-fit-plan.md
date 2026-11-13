# Plan: one Limits box for every tracked AI, no card in Plans, the "Downloads" project, and text that fits

Date: 2026-11-12. Branch: `feature/limits-projects-fit` (from `master` at 7a6f7a7, release 3.9.0). Status: reviewed by two reviewers; "Changes after review" at the end overrides anything above it.

## Requests (the owner's words)

1. "Under limits, dont use BYOK limits; it should just be in the limits box."
2. "For limits, every ai choosen should be there (choosen means selected to track), even if there is no active session, it should still show. If there is zero data, say no data. If there is no new data, use the previous data with a small note that explains it might not be accurate, its going off stale data."
3. "From plan, remove card."
4. "In projects, why is there a project called downloads? Fix this (local)."
5. "For anywhere, if something doesnt fit, make it fit within reason (dont push stuff out of the way), if it cant fit, have a small 'read more' under it, when if you click it the entire thing expands."

Workflow: plan, two reviewers on the plan (one with the background, one cold), build, four reviewers on the code (two with the background, two cold), PR, push. No release unless the owner asks.

## Findings (how it works today, with evidence)

### Limits tab (`PanelModel.limitsTab`, `Sources/TrackerCore/PanelModel+Tabs.swift`)

* Builds `toolKeys`: in All AIs every enabled tool, in a tool view that tool, in a provider view nothing. Providers are never covered in All AIs.
* Only `claude_code` and `codex` produce anything (`Limits.planLevels`). Gemini CLI and opencode produce nothing: in All AIs they are simply missing; in their own view the card says "<name> doesn't record plan limits on this Mac."
* BYOK rows (`byokLimitItems`: "<Provider> API key · Active (opencode)", fetched balance rows, model "ctx · out" token limits) go into a second card titled **"BYOK limits"**, unless the plan card is empty, in which case they replace it. This is request 1.
* **Codex limits disappear (bug).** `CodexSource.codexRateLimits` takes the newest `rate_limits` record of all session files. Codex now also writes records with `"limit_id": "premium"` whose `primary` and `secondary` are both null. On this Mac the newest record (2026-11-13T05:30:02Z) is such a record, so `codexLimits` returns nothing and the tab says "Codex hasn't recorded its plan limits yet." even though a record 5 minutes older has the 5-hour (78%) and weekly (32%) windows. This is very likely what the owner saw as "not showing without an active session".
* **Claude Code percentages disappear on any failed fetch.** `ClaudeUsage.fetchUsage` returns `"limits": []` with an error ("On an error there are no limits: old percentages could be wrong"), and `AppController+Accounts.swift:150` stores that over the previous answer. The tab then shows only the error text.
* Codex records carry their time (`"at"`); Claude's answer carries `fetched_at`. Nothing in the tab says how old a number is.

### Plans tab (`PanelModel.subscriptionsTab`)

* Each Claude Code / Codex card has rows Plan, Email, **Card** ("•••• 1234" or "Unavailable") and buttons Set/Edit Email and **Set/Edit Card**.
* Card code: `AppAction.subscriptionCard` (`subscription_card:<tool>`), `AppController.editSubscriptionCard` (`AppController+Accounts.swift`), `Subscriptions.setDetail` accepts field `last_four`, state keys `subscription_details.<tool>.last_four` and `.card_email`, README "Set Card" paragraph, tests in `SubscriptionsTests.swift`.

### "Downloads" project (local data, `UsageStats.foldSubfolders`)

* On 2026-11-10 two Claude Code sessions ran with their working folder set to `~/Downloads` itself (logs `~/.claude/projects/-Users-raymond-Downloads/*.jsonl`, 339,071 tokens; the prompts were `cat .claude/settings.json` and `/plugin`). So `daily[2026-11-10].projects` has a real `~/Downloads` entry.
* `topProjects` folds a subfolder into its parent when the parent is also a project ("~/game/tools" into "~/game"). It never folds into `~` or `/`, but it does fold into `~/Downloads`. So in the last 7 days the FPS game (`~/Downloads/FPS Game 10.23.45 AM`, hundreds of millions of tokens) is added to the small `~/Downloads` row, and the top project shows as **"Downloads"**. The same would happen to everything in `~/Desktop` (this repo included) the day a session runs in `~/Desktop` itself.

### Text that does not fit (`Sources/ClaudeTracker/Panel/*`)

* Every label is one `LabelText` line: `.lineLimit(1)` and truncation (tail, or middle for row and bar labels). Nothing shrinks and nothing tells the user that text was cut.
* Control labels (`ControlLabel` in switch, popup, segmented rows) span the full card width in a `ZStack`, so a long label runs under the switch or dropdown.
* Notes and warnings are wrapped by character count (`noteWidth` 46, `alertWidth` 40), not by measured width.
* Plumbing that already exists and is unused today: `PanelContext.measure` (real font widths, `TextMeasures.live`), `PanelLayout.isCutOff`, `PanelLayout.labelBudget`, `wrapMeasured`, the `toggle_row:<id>` action, `AppController.openRows` and `OpenRows.toggle/prune`. `buildPanelResult` returns `rows: [:]`, so `OpenRows.prune` currently empties `openRows` on every draw.

## Design

### Part 1 and 2: one Limits box covering every tracked AI

**Which AIs.** New `Limits.trackedKeys(view, state)`: All AIs gives `enabled_tools` in `Tools.tools` order, then `enabled_providers` in `Providers.providers` order; a tool or provider view gives just its key.

**One card.** The tab has one card titled **"Limits"** (was "Plan limits" plus "BYOK limits"). The free-resets card and the Notifications card stay as they are, below it.

**One section per AI**, in `trackedKeys` order. In All AIs each section starts with `.heading(<AI name>)`; in a single AI's view there is no heading (the panel's subtitle names the AI already). A section is one of:

* **Data**: its rows (below), then a stale note if the data is stale.
* **No data**: one row, `<AI name>` · `No data` in All AIs, or `Limits` · `No data` in a single view, followed by the existing reason note where there is one (Claude Code's "Turn on Percentages from Anthropic…" or the fetch error; Codex's "Codex hasn't recorded its plan limits yet."; other tools "<name> doesn't record plan limits on this Mac.").

What each AI's data is:

* **Claude Code**: bars from Anthropic's percentages (fresh), else from the last good answer (stale, see below), else the reached limits from its logs (as today). Notes as today (`claudeLimitNotes`) when there are no bars.
* **Codex**: bars from the newest `rate_limits` record **that has a window** (fix below).
* **opencode**: the rows `byokLimitItems` makes today (API key rows, fetched rows, model token limits), with the "BYOK" word dropped from any title. No heading text changes inside the rows.
* **A provider** (DeepSeek, OpenRouter, …): the BYOK rows for that provider (as `byokLimitItems` gives in that provider's view today), plus the rows its own account fetch saved (`accounts.<key>.rows`, e.g. balance), when present. The provider's own view keeps its account card on Home too; the Limits tab only repeats the rows.
* **Gemini CLI and any other tool**: no data source, so "No data".

**Codex fix.** `CodexSource.codexRateLimits` returns the newest record whose `rate_limits` has a non-empty `primary` or `secondary` (records with both null, such as `limit_id: "premium"`, are skipped). New sibling `codexRateLimitsAt(_:) -> Double?` gives that record's `at` as a Unix time. Alerts (`planLevels`) get the same fix, which is correct: the premium record says nothing about the plan windows.

**Claude Code: keep the last good answer.** New pure function `ClaudeUsage.merged(previous: JSONObject?, fetched: JSONObject) -> JSONObject`: when `fetched` has limits, it is stored as today and also copied to `last_good: {"limits", "fetched_at"}`; when `fetched` has none (an error), `last_good` is carried over from `previous`. `AppController+Accounts.swift` stores `merged(...)` instead of the raw result. `Limits.claudeLimits` (used by alerts and the Live tab's "held by limit") is **unchanged**: it reads only the fresh `limits`, so a stale number never sends an alert or marks a session as held. Only the Limits tab falls back to `last_good`. Turning Percentages off still deletes `claude_usage` (and with it `last_good`).

**Stale rule.** One constant `Limits.staleAfterSeconds = 15 * 60` (three Claude refreshes). Data is stale when:

* Claude Code: the bars come from `last_good` (the latest fetch failed), or the fresh answer's `fetched_at` is older than 15 minutes (fetches stopped, e.g. the Mac slept).
* Codex: the record's `at` is older than 15 minutes (no Codex turn since; usage from other devices or the web is not seen).

A window whose reset time has passed still reads 0% (today's rule), and that section is stale by the rule above anyway.

The note, one line under that AI's bars: **"Last updated 2h ago, so this may be out of date."** (`formatAgo`, already in `PanelModel+Tabs.swift`). Claude Code with an error adds the error as today.

**Alerts card.** Unchanged: `Limits.limitWindows` still drives it.

### Part 3: remove the card from Plans

* Remove the Card row and the Set/Edit Card button from `subscriptionsTab`.
* Remove `AppAction.subscriptionCard` and its parse case, `AppController.editSubscriptionCard` and its `handle` case, and `last_four` from the fields `Subscriptions.setDetail` accepts.
* Launch migration (in `AppState+Launch.swift`, next to the other one-time fixes): delete `last_four` and `card_email` from each `subscription_details.<tool>`, and drop a tool's entry if it is then empty. The stored digits are personal data the app no longer shows; keeping them would be a silent leftover.
* README: drop the "Set Card" paragraph; keep the Email part.
* Tests: drop the card tests; add a migration test and a test that the card row and button are gone.

### Part 4: "Downloads" stops swallowing projects

* `UsageStats.foldSubfolders`: besides `~` and `/`, never fold into a **container folder**: `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Library`, `~/Movies`, `~/Music`, `~/Pictures`, `~/Public`, `~/Applications`, and the iCloud Drive root `~/Library/Mobile Documents/com~apple~CloudDocs`. A container folder with usage of its own still gets its own row (as `~` does today), so the 339K tokens from the 2026-11-10 sessions stay visible as a small "Downloads" row and the FPS game becomes its own top row.
* Display only: no stored data changes, so the fix also corrects past weeks.
* README Projects line: say that folders like Downloads or Desktop only show their own usage, never the projects inside them.
* Answer to "why": a Claude Code session really ran in `~/Downloads` on Nov 10; the fold rule then counted the FPS game under it.

### Part 5: text that fits, and "Read more"

**Fit first (views).** `LabelText` gets `.minimumScaleFactor(PanelLayout.minTextScale)` with `minTextScale = 0.85`, so text that is a little too wide shrinks up to 15% instead of being cut. Control labels get a width so they stop running under their control: switch label `card − 34 − 8`, popup label `card − 140 − 8`, segmented label `90 − 4`. Nothing moves: every slot keeps its size.

**Then Read more (model).** New pure pass in TrackerCore, `PanelModel.fitted(_ tab: Tab, measure: TextMeasure, open: [String: Bool]) -> (tab: Tab, ids: Set<String>)`. For each card it checks the card title and each item's text against its slot with `measure` at the shrunk size (`isCutOff` with the width × `minTextScale`):

| Item | Text checked | Slot width (card inner width is 312) |
|---|---|---|
| card title | title, 13 semibold | 312 |
| `.row` | label 13 regular; value 13 semibold | `labelBudget(row, dot)`; 110 |
| `.bar` | label 13; value 13; sub 11 | `labelBudget(bar)`; 120; 312 |
| `.heading` | text 12 semibold | 312 |
| `.switch` / `.popup` / `.segmented` | label 13 | 270 / 164 / 86 |
| `.choices` | label 13 | 312 |

When any text of an item is still cut, the pass inserts after it a new item **`.readMore(id:isOpen:)`**: a small accent-coloured "Read more" link (11 pt, 16 pt tall) that sends `toggle_row:<id>`. When open, the pass also inserts the full texts that were cut, wrapped by measured width into `.note` lines (11 pt, 312 wide; label and value as "label: value"), and the link reads "Show less". The item itself is left as it is (shrunk and cut with "…"), so nothing beside it moves.

**Notes and warnings.** They already wrap, so they always fit. The pass re-wraps any `.note` or `.alert` line that measures wider than its slot (312, or 290 for alerts) into more lines with `wrapMeasured`. No Read more for them.

**Not covered** (and why): tiles, buttons, tags and segment titles keep their current behaviour plus the 0.85 shrink in `LabelText` where they use it; they are short fixed strings. The chart caption is hover text.

**Ids.** `fit:<tab key>:<card index>:<cut text>`: stable while the text is the same; a changed text (a new percentage) is a new id, which closes it. That is acceptable.

**Where it runs.** In `buildPanelResult` for every panel tab (its `rows` result now lists the fit ids so `OpenRows.prune` keeps them), and in `AppController.renderPanel` for the Settings window tab and the Tracking window tab. `openRows` is pruned against all ids together. The model stays pure; tests pass a stub `measure` (the default stub returns 0, so existing tests see no change).

**Heights.** `PanelLayout.heights["readmore"] = 16`. `PanelLayout.height(of:)`, `ItemView`, `Item.kind` get the new case.

## Files

| File | Change |
|---|---|
| `Sources/TrackerCore/PanelModel+Tabs.swift` | `limitsTab` rebuilt (one card, sections, no data, stale note); `byokLimitItems` takes a provider list; `subscriptionsTab` without card. |
| `Sources/TrackerCore/Limits.swift` | `trackedKeys`, `staleAfterSeconds`; doc comments. |
| `Sources/TrackerCore/CodexSource.swift` | `codexRateLimits` skips records without a window; `codexRateLimitsAt`. |
| `Sources/TrackerCore/ClaudeUsage.swift` | `merged(previous:fetched:)`; doc on `fetchUsage`. |
| `Sources/ClaudeTracker/AppController+Accounts.swift` | store `ClaudeUsage.merged`; remove `editSubscriptionCard`. |
| `Sources/TrackerCore/AppAction.swift`, `Sources/ClaudeTracker/AppController.swift` | remove `subscriptionCard`; fit pass for Settings and Tracking windows; prune against all ids. |
| `Sources/TrackerCore/Subscriptions.swift` | `setDetail` only `email`; `removeCardDetails` migration. |
| `Sources/TrackerCore/AppState+Launch.swift` | call the migration. |
| `Sources/TrackerCore/UsageStats.swift` | container folders never fold. |
| `Sources/TrackerCore/PanelItems.swift` | `Item.readMore(id:isOpen:)`, kind "readmore". |
| `Sources/TrackerCore/PanelLayout.swift` | `minTextScale`, height of readmore, control label budgets. |
| `Sources/TrackerCore/PanelModel+Fit.swift` (new) | `fitted(_:measure:open:)`. |
| `Sources/TrackerCore/PanelModel.swift` | `buildPanelResult` runs the fit pass and returns its ids. |
| `Sources/ClaudeTracker/Panel/Style.swift` | `LabelText` minimum scale. |
| `Sources/ClaudeTracker/Panel/CardView.swift`, `ItemViews.swift` | draw `.readMore`. |
| `Sources/ClaudeTracker/Panel/ControlItems.swift` | control label widths. |
| `Tests/TrackerCoreTests/*` | below. |
| `README.md` | Limits, Plans, Projects paragraphs. |

## Callers and impact

* `planItems` in `PanelModelLimitsTests.swift` looks up the card titled "Plan limits": those tests move to "Limits".
* `codexRateLimits` is used by `Limits.planLevels`, `Limits.unknownIDPrefixes` and possibly the Live tab; skipping window-less records only changes results when the newest record has no window.
* `foldSubfolders` is used only by `topProjects`.
* `Item` is matched exhaustively in `ItemView`, `Item.kind`, and any test helper `switch`; the compiler finds them.
* Removing `AppAction.subscriptionCard` also touches `opensDialog`.

## Tests

* Limits: All AIs lists every enabled tool and provider in order, with headings; Gemini CLI shows "No data"; opencode BYOK rows sit in the one card and no "BYOK limits" card exists; a provider view with no data shows "No data"; a Codex record 2 h old shows the stale note; a fresh one does not; the newest record being window-less still shows the older windows; Claude with `last_good` and an error shows bars plus the stale note; `claudeLimits` ignores `last_good` (alerts unaffected).
* `ClaudeUsage.merged`: good answer sets `last_good`; error keeps the previous `last_good`; no previous gives none.
* Plans: no Card row, no card button; migration removes `last_four`/`card_email` and empty entries; `subscription_card:` no longer parses.
* Projects: `~/Downloads` with `~/Downloads/FPS Game` gives two rows; `~/game` with `~/game/tools` still folds; `~/Desktop/x` stays apart from `~/Desktop`.
* Fit: with a stub measure (7 pt per character), a long row label gets a Read more item with the right id; opening it adds the full text as notes and "Show less"; a short label gets nothing; a too-wide note is re-wrapped; ids are returned; the default stub measure changes nothing.
* Full `./test.sh`; a scratch build to look at the Limits, Plans and Projects tabs and a long label (the installed app is not touched).

## Risks

* The 0.85 shrink makes some cut labels slightly smaller than their neighbours. It only applies to text that would otherwise be cut.
* The model's measure (AppKit `NSString.size`) and SwiftUI's drawing can differ by a point or two; a 1 pt margin is already in `isCutOff`.
* A Read more line adds 16 pt below the item, which moves later items down. That is what was asked ("a small read more under it").
* The container folder list is fixed; a folder like `~/Developer` used as a session's working folder would still swallow its projects. It can be added later; the common macOS folders are covered.

## Changes after review

Two reviewers read this plan: one knew the investigation, one read it cold. Their findings and what changed (R1 = informed, R2 = cold):

**Codex**
* The filter moves into `CodexSource.latestRateLimits` (R2 blocker): that function keeps one record per session file and the result is cached per file, so a window-less record that is newest *in its file* would hide the good one. Within a file it now prefers the newest record that has a window and whose `limit_id` is missing or `"codex"`; failing that, the newest record with any window; failing that, nil. `fileVersion` goes to 4 so cached files are read again. `codexRateLimits` applies the same preference across files (R1 3, R2 10). Test: both records in one file.
* Codex staleness is not 15 minutes (R2 8): Codex writes a record only on a turn, so that note would show nearly always. Codex is stale when its record is older than **1 hour**, or when a window's reset time has passed since the record (the 0% is then a guess).

**Claude Code**
* `last_good` is dropped when the error is "signed out" or "sign-in expired" (R1 1), so another account's numbers never linger.
* The stale note uses `last_good.fetched_at` when the bars come from it (R1 2); a missing or zero time says "Last updated at an unknown time, so this may be out of date."
* The reached limits from the logs win over `last_good` window by window (R2 6): a fresh "Reached" beats a stale percentage.
* While the first fetch runs (no answer yet, no error), the value is "Loading…", not "No data" (R2 13).
* Stale threshold for Claude: 15 minutes (3 refreshes of 5 minutes), or a reset time passed since the fetch.

**Providers**
* Stale rule also covers provider account rows and BYOK fetches (R2 7), per source (R2 19): stale when the saved `error` is set (the last refresh failed) or the data is older than 45 minutes (3 refreshes of 15 minutes). Time from `fetched_at` (accounts) or the BYOK fetch time.
* Only limit-like rows: "Models available" and "Total spent" are left out of the Limits tab (R1 6). Balances stay.
* In All AIs the opencode section lists only BYOK providers that are not also enabled as providers; those get their rows in their own section (R1 5, R2 4).

**Layout of the Limits card**
* In All AIs each AI has a heading and its bars drop the AI's name ("5-hour", "Weekly, Opus") because the heading names it (R2 12). A single AI's view keeps today's full names. An AI without data shows `Limits` · `No data` under its heading.
* Note wording uses `formatAgo`'s real output: "Last updated 2 hr ago, so this may be out of date." (R1 12, R2 11).

**Fit and Read more**
* The cut check was backwards (R2 2): text is cut when `measure(text) × 0.85 > slot − 1`.
* Rows and bars fit before falling back (R1 10, R2 5): the label and value share the line. The value takes the width it needs up to a cap (200 pt), the label gets the rest (view: value at higher layout priority with a max width; model mirrors it with `measure`). So "1.0M ctx · 32.8K out" fits and no wall of links appears. Nothing beside the row moves.
* Ids no longer contain text (R1 8, 9, R2 16): `fit:<tab key>:<card title, or card index>:<item index before insertion>`. The pass runs after the warning card is inserted.
* Settings, Tracking and welcome windows keep their own `windowOpenRows`, pruned only against their ids, so closing or switching the panel does not collapse them (R1 7, R2 16, 17). The panel's prune moves after all fit passes for the panel itself.
* Control label widths come from `PanelLayout` constants shared by the model table and `ControlItems` (R1 13).
* Covered: panel tabs, Settings window, Tracking window, welcome screen. Not covered: the range popup (a calendar with fixed short labels).
* Kept as planned, by choice: the cut item stays on its line and the expansion adds its full text under it (R2 15 suggested replacing the line; keeping it keeps the bar and value in place, which is the "don't push stuff out of the way" part). A note line wider than its slot is re-wrapped on its own (R2 14; rare with the 46-character wrap).

**Projects**
* A container folder's own row is labelled "Downloads (folder itself)" (R1 11, R2 9), so it is clear it is not a project; the owner is told why the row exists.

**Plans (card)**
* Also remove `Subscriptions.validLastFour`, the `card_email` logic, the `opensDialog` entry, the card tests, and the card words in README line 63 and the Subscriptions section (R1 14, R2 18). The Plans tab keeps its `creditcard` icon (it stands for the plan, not the card row); changing it was not asked.

**Tests that change** (R1 4, R2 3): `PanelModelLimitsTests` fixtures get times relative to `limitsNow` (`fetched_at` and Codex `at` fresh), `planItems` looks up "Limits", the cards-title test and `limitsTabUsesDisplayNameInAllViews` follow the new layout; the comment in `OpencodeSourceTests` (lines 248-251) is updated; `SubscriptionsTests` card cases removed.
