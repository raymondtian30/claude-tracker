# Plan: "Show more" in the Tracking dropdown, and effort rows sorted by tokens

Date: 2026-11-12. Branch: `feature/ai-catalog-picker` (same branch as the 25 new providers). Status: draft for review.

## Requests

1. **Show more.** "When you want to change which AI is selected, after 7 there should be a show more, which then it will open a new window with every AI on it."
2. **Effort sort bug.** "In settings, if you switch to sort by token, it sorts the model by token, but not the effort. The effort is still bound to its parent model."

## Background (how it works today)

* The panel's "Tracking" dropdown is `Item.popup(label: "Tracking", options:, selected:, action: "select_tool")`, built by `PanelLayout.toolPicker(_:selected:)` (`Sources/TrackerCore/PanelLayout.swift`) from `PanelModel.viewChoices(state, detected:)` (`PanelModel+Settings.swift`): "All AIs" (when 2+ tools are on), then each enabled tool with data, then each enabled provider. With 35 providers that list can reach 40 rows.
* It is drawn by `PopUpControl` (`Sources/ClaudeTracker/Panel/AppKitControls.swift`), an `NSPopUpButton`; a pick sends `("select_tool", .index(i))`. `AppAction.parse` makes `.selectTool(index:)`; `AppController.handle` maps the index back through `viewChoices` and writes `state["selected_tool"]`.
* `SettingsWindow` (`Sources/ClaudeTracker/Panel/SettingsWindow.swift`) is a window that draws a `Tab` of cards with the panel's own views and sends clicks to the same action handler. Its title is fixed.
* The Models tab: `PanelModel.modelsCard` (`PanelModel+Tabs.swift`) sorts models with `ModelTiers.sorted` (tokens or tier), then for each model appends its effort rows (largest first) and a leftover plain row. In token order the effort rows stay under their model, so "Opus (High) 10M, Opus (Low) 1M, Sonnet 5M" shows Opus (Low) above Sonnet.

## Design

### Part A: effort rows in token order

* In `modelsCard`, build the rows of every model first (label, tokens, model position) exactly as today (clamping kept, so rows still add up to each model's total).
* When `order == .tokens`, sort all rows by tokens, most first; ties keep their current order (model order, then effort order) by using the row's position as the tie-break, so the result is deterministic.
* When `order == .tier`, keep today's grouping: tier is a property of the model, so its effort rows stay together under it.
* No change to the setting, its key (`model_sort`) or its labels.

### Part B: Show more

**Dropdown entries (TrackerCore, testable).** New in `PanelLayout`:

* `trackingVisibleCount = 7`, `trackingShowMoreTitle = "Show more…"`.
* `trackingEntries(_ choices:, selected:) -> [String?]`: the keys of the dropdown, in order. 7 or fewer choices: every key, no Show more (unchanged behaviour). More than 7: the first 7 keys; then the selected key if it is not among the first 7 (so the dropdown can still show what is being tracked); then `nil`, meaning "Show more…".
* `toolPicker` builds its options from `trackingEntries` (names, and the Show more title for `nil`) and the selected index from the position of the selected key (the first choice when the selected key is unknown, as today).

**Handling a pick.** `AppController.handle(.selectTool(index))` recomputes `trackingEntries(viewChoices, selected: currentView.key)` (the same inputs the render used). A key: select it as today. `nil`: close the panel and open the Tracking window.

**The Tracking window.**

* Generalise `SettingsWindow` with an `init(title:onAction:)` (Settings passes its current title), so the new window reuses the same card drawing, scrolling and height capping. No new view code.
* New `PanelModel.trackingWindowTab(_ choices:, selected:) -> Tab`: one card titled "Every AI you track" with one full-width button per choice (`Item.buttons([Button(name, icon, "pick_tool:<key>")])`), the selected one marked with the SF Symbol `checkmark`, and a note at the bottom: "Turn more AIs on in Settings, AI tools."
* New action `pick_tool:<key>` parsed into `AppAction.pickTool(String)` (empty key rejected). The handler ignores keys not in `viewChoices`; otherwise it sets `selected_tool`, saves, updates the title, starts a live search (as `.selectTool` does), closes the window and reopens the panel so the new view is visible.
* `AppController.renderPanel` re-renders the window's tab (like the Settings window) so it stays current while open; the window's `render` already skips work when the tab is unchanged.

**Popup reset.** After any pick, `PopUpControl.Coordinator` re-selects `parent.selected` on the button. Every handled action re-renders, so a real change still shows; but picking "Show more…" (which changes no state) no longer leaves "Show more…" showing as the selection. This also makes a rejected pick snap back.

## Files

| File | Change |
|---|---|
| `Sources/TrackerCore/PanelModel+Tabs.swift` | `modelsCard`: flatten and sort rows in token order. |
| `Sources/TrackerCore/PanelLayout.swift` | `trackingVisibleCount`, `trackingShowMoreTitle`, `trackingEntries`; `toolPicker` uses them. |
| `Sources/TrackerCore/PanelModel+Settings.swift` | `trackingWindowTab`. |
| `Sources/TrackerCore/AppAction.swift` | `case pickTool(String)`; parse `pick_tool:<key>`. |
| `Sources/ClaudeTracker/Panel/SettingsWindow.swift` | `init(title:onAction:)`. |
| `Sources/ClaudeTracker/Panel/AppKitControls.swift` | `PopUpControl` re-selects `parent.selected` after a pick. |
| `Sources/ClaudeTracker/AppController.swift` | `trackingWindow` property; `.selectTool` handles Show more; `.pickTool`; render the window. |
| `Tests/TrackerCoreTests/…` | New tests below; update the existing `toolPicker` test if needed. |
| `README.md` | Mention Show more and that token order mixes effort rows. |

## Callers and impact

* `toolPicker` has one caller (`PanelController.render`) and one test (`PanelLayoutTests`). `viewChoices` is used by render and the `.selectTool` handler; both move to `trackingEntries` together.
* `modelsCard` is called by `modelsTab` (Today and Lifetime) and tests in `PanelModelTests`. Tier order output is unchanged; token order output changes only when a model has effort rows.
* `SettingsWindow` has one construction site (`AppController.settingsWindow`).
* `PopUpControl` serves every dropdown (Tracking, and Settings popups such as Currency, Sort, Menu bar size). The reset is visual only and is followed by a re-render.

## Tests

* Token order: model A 100 (High 60, Low 40) and model B 50 gives A (High) 60, B 50, A (Low) 40. Tier order keeps A's rows together. Rows still sum to each model's total.
* `trackingEntries`: 5 choices gives 5 keys; 8 gives 7 keys and `nil`; selected 10th of 12 gives 7 keys, that key, `nil`; unknown selected gives the first.
* `toolPicker`: options end in "Show more…" when more than 7; selected index points at the selected key.
* `AppAction.parse("pick_tool:openai")` is `.pickTool("openai")`; `"pick_tool:"` is nil.
* `trackingWindowTab`: one button per choice in order, `checkmark` only on the selected one, actions `pick_tool:<key>`.

## Risks

* Race: choices could change between render and click (a tool detected in between). Same as today's `.selectTool`; worst case the wrong neighbour is picked or Show more opens; no crash (index is bounds-checked).
* Reopening the panel from the window: `panel.show()` needs the status item button; if it fails the selection is still saved.
* UI cannot be checked on screen by tests; a scratch build (`--scratch-path` outside the repo, own data folder) is the only visual check. The installed app is not touched.

## Out of scope

* Search or filter in the window, enabling providers from the window, changing the order of choices.

## Revisions after the two plan critics (2026-11-12)

Both critics (one with the drafting context, one cold) checked the plan against the code. Changes:

1. **"Every AI" means every AI, not only the turned-on ones.** The window has two cards: "Tracking" (every entry of `viewChoices`, the selected one marked) and "Not turned on" (providers that are off, and tools found on this Mac that are off). Picking one that is off turns it on, then switches to it. Same action, `pick_tool:<key>`.
2. **The 7 include "All AIs".** The dropdown shows at most 7 entries, then "Show more…". When the selected AI is not among the first 7, it takes the 7th slot (so the dropdown never grows past 7 plus Show more).
3. **Pure, tested pick logic.** `PanelLayout.trackingPick(index:choices:selected:)` returns `.select(key)`, `.showMore` or nil (out of range); `AppController` only acts on it.
4. **The window follows scans.** `trackingWindow.isShown` joins `panel.isShown || settingsWindow.isShown` in the two scan-redraw checks in `AppController`.
5. **Reopening.** After a pick: save, close the window, `renderPanel()`, then `panel.show()`. The panel opens on Home, as every opening does (`PanelController.show` calls `goHome`).
6. **Why the popup reset is needed.** Picks are handled one run loop later (`handleLater`), and after "Show more…" nothing changes, so `PanelController.render` returns early and `updateNSView` never re-selects; "Show more…" would stay showing. The same early return exists in `SettingsWindow.render`. A real pick briefly shows the old value until the redraw.
7. **Window title** "Choose an AI". `SettingsWindow` keeps its name (one construction site) and gains `init(title:onAction:)`; Settings keeps its title constant.
8. **Leftover effort row.** Once rows are sorted on their own, a plain "Opus 5.5" row could be read as the model's total. When a model has effort rows, its leftover row is labelled "Opus 5.5 (No effort recorded)". With Show effort off nothing changes.
9. **Part A was built first** (it is small and independent); its tests are in `PanelModelTests`.
10. **Extra tests:** exactly 7 choices (no Show more); 8 choices; "All AIs" selected; selected past 7 takes slot 7; `pick_tool` with no colon; unknown key ignored; names unique and never "Show more…".

Still out of scope: ordering efforts low to high in tier mode, search in the window.
