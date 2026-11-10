# Claude Tracker

A tiny macOS menu bar app (no Dock icon) that shows how many Claude Code tokens you've used, in total, forever. It just sits in your menu bar and the number keeps going up.

![menu bar](https://img.shields.io/badge/platform-macOS-lightgrey)

## Is this safe to run?

Yes. Nothing prebuilt is downloaded and nothing is hidden -- it's a set of short Swift files and a few shell scripts, all listed below, all readable. `./install.sh` compiles that source on your own Mac with Apple's Swift compiler (from Xcode's Command Line Tools), so the app you run is built from exactly the code you can read here.

By default it never connects to the internet or sends your data anywhere. The only things it touches are:

- Usage data your AI coding tools already keep on your own Mac, only for the tools you turn on:
  - **Claude Code:** its logs in `~/.claude/projects/`; for the Active Sessions tab's Plugins list, also your plugin settings (`~/.claude/settings.json` and an open project's `.claude/settings.json` / `settings.local.json`), `~/.claude/plugins/installed_plugins.json`, and each enabled plugin's own folder (to see which skills, agents, hooks and MCP servers it has)
  - **Codex:** its session logs in `~/.codex/sessions/`
  - **opencode:** its database at `~/.local/share/opencode/opencode.db`, opened read-only
  - **Gemini CLI:** its saved chat sessions in `~/.gemini/tmp/<project>/chats/` (and each project's `.project_root` file, for the folder name)

  From these it reads only token counts, which model was used, when, and which project folder, plus, for open Claude Code sessions, which plugin skills, agents, hooks and MCP tools ran and when. It skips your prompts, code and replies, and never touches opencode's account or credential tables.
- `launchctl`, macOS's own built-in tool, only to turn its "start at login" setting on or off
- `/usr/bin/security`, macOS's own Keychain tool, only for the Claude Code sign-in, API keys and Leaderboard token described below -- as before, the app reaches your Keychain only through this tool

**There are three exceptions.** One is on by default: if you track Claude Code, the app asks Anthropic for your plan's limit percentages (see [Usage limits and alerts](#usage-limits-and-alerts)); turn off **Percentages from Anthropic** in Settings to stop it. Two are opt-in: an API key you add for an AI provider (see [OpenAI, DeepSeek, Kimi and other AI companies](#openai-deepseek-kimi-and-other-ai-companies)), and the Leaderboard (Beta) feature. Clicking **Check for Updates** also contacts GitHub, only when you click it (see [Updating](#quick-start)).

**The Leaderboard (Beta) is entirely opt-in** -- its tab is hidden until you turn on **Show Leaderboard (Beta)** in Settings, and nothing below happens unless you then click "Set Up Leaderboard" yourself. See the [Leaderboard (Beta)](#leaderboard-beta) section for exactly what that does.

## Quick start

1. Open Terminal and paste this in, one line at a time:
   ```bash
   git clone https://github.com/raymondtian30/claude-tracker.git
   cd claude-tracker
   ./install.sh
   ```
2. Look at your menu bar (top right of your screen). You'll see a 🪙 icon with a number next to it.

That's it. It now also starts automatically every time you log in, and **Claude Tracker** is in your Applications folder (Finder, Launchpad and Spotlight) if you ever quit it and want it back. Opening it while it's already running just opens its panel.

The app in Applications is compiled from the code in this folder and keeps your totals in `state.json` here. If you move this folder, run `./install.sh` again.

**Updating:** click **Check for Updates** under About in Settings. If GitHub has newer releases, it lists each one with what's new and asks whether to update. Click **Update** and the app downloads the newest into this folder (a `git` fast-forward to the release's tag), recompiles itself and restarts; **Not Now** changes nothing. Your settings and totals live in `state.json` and `friends.json`, which updates never touch. It won't update a copy whose code you've changed or that's on a branch other than `master`, so your own work is never overwritten, and it checks that Swift 5.9 or newer is installed before changing anything. This is the only time the app contacts GitHub besides the opt-in Leaderboard.

**Coming from 2.5.0 (the Python version):** Check for Updates works as usual and rebuilds the app in Swift. If this Mac can't compile it (no Command Line Tools, or macOS older than 13), the update puts this folder back on 2.5.0 and your app keeps working; install the Command Line Tools and click Check for Updates again.

If step 1 says Swift isn't found, install Xcode's Command Line Tools (free from Apple, no full Xcode needed) and run `./install.sh` again:

```bash
xcode-select --install
```

## What you'll see when you click the icon

The first time you open it, it asks which AI tools you use (Claude Code, Codex, opencode, Gemini CLI -- only the ones found on your Mac are listed) and tracks only those. If you track more than one, a dropdown at the top picks which tool you're looking at, and the menu bar and the top of the panel show that tool's icon (taken from its app or editor extension already on your Mac; the coin if none is found, and in the combined view); pick **All AIs** in that dropdown to see every tool you track added up, grouped by model.

A panel opens with a row of tabs along the top. It always opens on **Overview**; click an icon to switch tabs:

- **Overview** -- today's and lifetime totals, a chart of the last 14 days, and yesterday / last 7 days / this month / your biggest day
- **Token Types** -- today's and lifetime tokens split into input, output, cache write and cache read, each with a bar showing its share
- **Models** -- today's and lifetime tokens per model (Opus, Sonnet, Haiku...)
- **Projects** -- every folder you used tokens in over the last 7 days, most first: the top 5, and the rest behind **Show more** (usage in the home folder itself shows as its own "~" row)
- **Estimated API Cost** -- what your usage would cost at Anthropic's pay-as-you-go API prices. Just for fun: a Pro or Max subscription is flat-rate, so you aren't billed this. Prices live in `Sources/TrackerCore/Pricing.swift` and will drift over time.
- **Usage Limits** -- how much of your plan's limits you've used, and when to be notified (see [Usage limits and alerts](#usage-limits-and-alerts))
- **Active Sessions** -- two sections:
  - **Sessions:** every Claude Code terminal you currently have open, how many tokens each one has used, and tags for the plugins running in it (crossed out if that project turns a plugin off)
  - **Plugins:** every Claude Code plugin you have enabled, how many open sessions run it, the last thing it did (ran a skill, started an agent, used an MCP tool, ran a hook, added context to your prompt) and how often today. Two installs of a plugin with the same name can't be told apart in the logs, so their activity is shown on the first one in your settings
- **Leaderboard (Beta)** -- hidden unless you turn it on in Settings; see below, this one's still a work in progress

At the bottom: the date you started tracking, a **Settings** button that opens a separate Settings window (which AIs you use -- coding tools and providers; **Appearance** -- Auto, Light or Dark, where Auto follows macOS; what the menu bar shows -- lifetime total, today's total, or just the icon -- and its text size; the panel's unfold/fold **Animation** -- Off, Fast, Normal or Slow; how often to scan; start at login; show the Leaderboard; and **About**, with a small About | Credits switch: About has the version and Check for Updates, Credits lists everyone who made the app) and **Quit**. Click anywhere outside the panel to close it.

### OpenAI, DeepSeek, Kimi and other AI companies

Turn on OpenAI, DeepSeek, Kimi, Google, Anthropic, xAI, Mistral, Qwen, Z.ai (GLM) or MiniMax under **AI tools** in Settings (listed after your coding tools) (all off by default) and each appears in the **Tracking** dropdown. A provider view counts that company's models wherever they ran -- Claude Code, Codex or opencode -- using the tools' own exact token counts, so **no sign-in or key is needed**. The model name decides the company (`gpt-*`, `o3`, `codex-*` → OpenAI; `deepseek-*` → DeepSeek; `kimi-*`, `moonshot-*` → Kimi; `gemini-*`, `gemma-*` → Google; `claude-*` → Anthropic; `grok-*` → xAI; `mistral-*`, `codestral-*`, `devstral-*` → Mistral; `qwen*` → Qwen; `glm-*` → Z.ai; `minimax-*` → MiniMax). API keys are supported for OpenAI, DeepSeek and Kimi only, so e.g. Kimi via OpenRouter still counts as Kimi. While any provider is on, every tool found on your Mac is read (read-only), so Codex counts toward OpenAI even if the Codex view is off. **All AIs** adds up tools only, not provider views on top, so nothing is counted twice. Live Sessions isn't shown for providers, since a running session can't be tied to one company.

**Optional API key, for usage from outside this Mac.** Turning a provider on never asks for a key. If you want usage from other computers or the website too, use **Add API Key** in the "Whole account (optional)" card at the bottom of that provider's Home tab; it then shows what the provider's own API reports (and Replace/Remove Key live in that card):

| Provider | Key | Shows |
|---|---|---|
| OpenAI | admin key (`sk-admin-…`, from Settings → Admin keys) | daily tokens per model and billed cost, last 30 days |
| Kimi | admin key (`sk-admin-…`, `billing:read`) | daily tokens per model, balance, total spent |
| Kimi | ordinary API key | balance |
| DeepSeek | API key | balance (DeepSeek has no usage-history API) |

If an AI's usage can't be seen -- none of your tools have used its models yet, a key only gives a balance, a key is rejected, or its data can't be read or reached -- an orange warning saying why sits at the top of every tab when you pick it from the dropdown. These account numbers are shown in their own card and never added to the local totals, since the two overlap. Numbers refresh every 15 minutes; if a refresh fails, the last good numbers stay with the error shown under them.

**How keys are kept private:** a key is stored only in your **macOS Keychain**, written through `security -i` on standard input so it never appears in a process list. It's never written to `state.json`, any log or this repo. It's sent only over HTTPS, only to that provider's own API (`api.openai.com`, `api.deepseek.com`, or `api.moonshot.ai` / `api.moonshot.cn`), and redirects aren't followed. **Remove Key** deletes it from the Keychain. Only usage numbers and balances are requested.

### Usage limits and alerts

The **Limits** tab shows how much of each plan limit you've used, and the app can notify you when you get near one. Only the limits your plan has are shown. Each limit is named after its tool and window, for example "Codex (Monthly)" or "Claude Code (Weekly, Opus)", on its bar and in its notification; when it resets is a small line under the bar.

- **Claude Code:** the 5-hour and weekly limits (and the weekly Opus or Sonnet limit, or a model-specific weekly limit such as Fable, if your plan has one). Any other limit Anthropic adds later shows up on the next refresh, named as Anthropic names it, without an app update, as percentages, refreshed every 5 minutes. Claude Code doesn't save these on your Mac, so the app asks Anthropic for them the same way Claude Code's own `/usage` does: it reads Claude Code's saved sign-in from your **macOS Keychain** and sends it over HTTPS only to `api.anthropic.com`, without following redirects. The sign-in is never copied into `state.json` or any log, and the app never renews it (renewing could sign Claude Code out) -- if it has expired, open Claude Code and it renews itself. Without a connection the bars say "Couldn't reach server. Percentage unavailable." and fill in again on the next refresh once you're back online. Turn off **Percentages from Anthropic** in Settings (under General) to stop asking; the tab then shows only limits Claude Code has logged as reached. This uses an endpoint Anthropic hasn't documented, so if it changes, the bars say the percentage is unavailable.
- **Codex:** saves its plan's limits in its own logs -- percent used, the window and when it resets -- so those are shown as Codex recorded them. Which windows you see depends on your plan: the free plan has one 30-day window (shown as Monthly), paid plans a 5-hour and a weekly one.
- **Notifications:** the **Notifications** card in the Limits tab -- on by default at **75%**. Under **When usage reaches**, turn on as many percentages as you like (for example 75% and 90%), and there's a switch for each limit window your tool has. Each limit notifies once when it reaches each of those percentages, and again only after it has dropped back below (for example when its window resets). If usage jumps past several at once, you get one notification, not one for each. Nothing repeats at launch: a limit that was already over a percentage when Claude Tracker started, or whose numbers couldn't be fetched for a moment (no network yet), doesn't notify again. **Send Test Alert** shows what one looks like. The first time, macOS asks whether Claude Tracker may send notifications; if you said no, the test alert offers to open System Settings so you can turn them on. If Claude Tracker's alert style is set to **None**, alerts go only to Notification Center without popping up; the test alert then says so and offers to open Claude Tracker's page in System Settings, where you can pick **Temporary** or **Persistent**.

### Leaderboard (Beta)

This is a genuine work in progress, not a finished feature -- treat it as rougher and less battle-tested than everything else in this app. It's also completely opt-in: its tab only appears after you turn on **Show Leaderboard (Beta)** in Settings, and until you click "Set Up Leaderboard," none of what follows happens, and the rest of the app (token counting, Active Sessions, etc.) works exactly the same with or without it.

Here is exactly what it does, in order, when you click "Set Up Leaderboard":

1. **It opens your browser** to a GitHub page that creates a Personal Access Token scoped *only* to the `gist` permission (nothing else on your GitHub account -- it cannot read your repos, emails, or anything beyond gists). You generate the token yourself on GitHub's own site.
2. **You paste that token into a prompt in the app.** The token is stored in your **macOS Keychain** (the same secure system macOS itself uses for saved passwords) -- never written to any file in this project, never logged, never leaves your Mac except as an authorization header sent directly to `api.github.com` over HTTPS.
3. **It creates one secret Gist on your own GitHub account** -- a single small JSON file containing only: the display name you typed in, your total token count, your token count from yesterday, and today's date. That's the entire payload. No logs, no message content, no file paths, no code ever leaves your machine.
4. **Once a day** (checked whenever the app does its normal scan, gated by date so it only actually runs once), it pushes your updated numbers to that same Gist, and separately fetches the Gist of every friend you've added, updating your local `friends.json`. You can also trigger both manually any time with "Push Update Now" / "Pull Latest Now."

**Adding a friend** ("Add Friend by Code") just means pasting in the ID of their Gist -- that ID is their "friend code." Reading a friend's Gist is a plain, unauthenticated read of a known URL; no token or permission exchange happens between you and them.

**Where things live locally:** your GitHub token is Keychain-only. Your Gist ID and display name are in `state.json`. Your friends' cached scores are in `friends.json`. All three are gitignored -- none of this is ever part of the git history of this project, and none of it is sent to any server other than `api.github.com`, which GitHub itself runs.

**Honest caveat:** since every person's own client reports its own numbers, there's no way for anyone to verify a score is real. This is an honor-system leaderboard for fun among friends, not a tamper-proof one -- which is exactly what the disclaimer inside the menu itself says.

## Uninstalling

```bash
./uninstall.sh
```

This removes it from starting at login and deletes **Claude Tracker** from your Applications folder. Your accumulated total (`state.json`) is left on disk in case you reinstall later -- delete that file yourself if you want to reset to zero.

## How it works

- Claude Code already writes a log of every message you send and receive to `~/.claude/projects/**/*.jsonl` on your own machine.
- Codex and opencode count tokens a bit differently (for example, Codex includes cached tokens in its input number). The app converts each into the same four types -- new input, output, cache write, cache read -- so the tools add up and compare consistently. Each tool's Overview also shows **new input + output**, which compares tools fairly since cache reads can dominate a total.
- This app reads those logs and adds up the tokens (input + output + cache) used in every message.
- It also files each message into a per-day bucket (by model, token type and project), which powers the breakdown, history and cost menus. The first time you run a version with these menus, it fills the buckets from the logs still on disk; anything Claude Code already pruned shows up as "older, no detail".
- It remembers exactly how far into each log file it has already counted, so re-checking every 15 seconds only adds *new* tokens, never double-counts, and the total keeps climbing correctly even after Claude Code deletes old logs (it prunes anything older than ~30 days).

**A note on "Sessions" tab accuracy:** Claude Code doesn't expose which exact log file belongs to which open terminal, so this is a best-effort match based on which directory each terminal is running in and which log file in that directory was written to most recently. If you have two terminals open in the exact same folder at once, they may get matched to the wrong one of each other -- everything else is unaffected.

## Version and credits

Current version: **3.0.0**, following [Semantic Versioning](https://semver.org) (MAJOR.MINOR.PATCH). The version lives in `Sources/TrackerCore/Version.swift` and is shown in Settings.

- Original app by Brody Kretz ([BrodyKretz](https://github.com/BrodyKretz/claude-token-counter))
- Redesign, new features and the Swift rewrite by Raymond Tian ([raymondtian30](https://github.com/raymondtian30/claude-tracker))

**Settings → About → Credits** shows the original creator in a section of their own, then everyone else who has commits on GitHub, with their GitHub usernames. The list is built into the app, so it works offline and the app never asks GitHub for it. To refresh it before a release, run `scripts/update-credits.sh` (needs the GitHub CLI, `gh`). It rewrites `Sources/TrackerCore/Credits.swift`.

## Project layout

```
Sources/TrackerCore/         the app's logic, plain Swift with no AppKit, so it can be tested
  TokenMath.swift            reads Claude Code's jsonl logs and does the token accounting
  UsageStats.swift           per-day buckets and the breakdown / model / project / history views
  Day.swift                  calendar days, the keys of those buckets
  CodexSource.swift          reads Codex usage from its session logs
  OpencodeSource.swift       reads opencode usage from its database (read-only)
  GeminiSource.swift         reads Gemini CLI usage from its saved chat sessions
  Tools.swift                the supported tools, detection, scanning, per-tool and combined views
  Providers.swift            OpenAI / DeepSeek / Kimi: which models are theirs, provider views
  Accounts.swift             optional provider API keys (Keychain) and account usage/balance fetching
  ToolIconSource.swift       where each tool's or provider's icon is found on this Mac
  PanelModel*.swift          what each panel tab shows, as plain data
  PanelItems.swift           the kinds of thing a panel tab can hold (tiles, bars, rows, buttons...)
  PanelLayout.swift          the panel's sizes and the arithmetic behind them
  PanelSpeeds.swift          the panel's unfold/fold animation speeds
  AppState*.swift            settings added to state.json on launch, changes to it, and the menu bar's text
  AppAction.swift            turns a click in the panel or Settings into what the app should do
  OpenRows.swift             which expandable panel rows are open
  Subprocess+Detached.swift  starts the restart command after an update, detached from the app
  Pricing.swift              API price table and the estimated-cost math
  Limits.swift               plan limits and when to send a usage alert
  ClaudeUsage.swift          Claude Code's limit percentages, from Anthropic
  Notifications.swift        when and what to notify, and what to do if macOS won't show it
  Version.swift              app name, version number and credits
  Credits.swift              who made the app, for Settings > About > Credits (generated by scripts/update-credits.sh)
  Updater.swift              Check for Updates: lists newer GitHub releases, installs the newest if you say so
  ActiveSessions.swift       matches running `claude` processes to their sessions
  Plugins.swift              enabled Claude Code plugins and what each did in open sessions
  Leaderboard.swift          Leaderboard (Beta) -- local friends-list storage and sorting
  GistSync.swift             Leaderboard (Beta) -- Keychain token storage + GitHub Gist API calls
  LoginItem.swift            start at login, through the LaunchAgent
  InstanceLock.swift         the lock file that keeps one copy running
  JSON.swift                 reading and writing state.json's JSON, keeping keys it doesn't know
Sources/ClaudeTracker/       the menu bar app itself (AppKit and SwiftUI)
  main.swift                 starts the app
  Panel/                     draws the panel and the Settings window (tabs, cards, bars, chart, controls, dialogs)
  TextMeasure.swift          real text widths, for knowing when a label is cut off
  Notifier.swift             macOS notifications (UNUserNotificationCenter)
  ToolIcons.swift            turns each tool's icon into a menu bar image (or draws a monogram)
  SingleInstance.swift       keeps one copy running; opening it again shows the running copy's panel
  AppController*.swift       ties it together: scanning, the menu bar, the panel, Settings, dialogs, updates, alerts
Tests/TrackerCoreTests/      tests for the logic in the files above
Resources/AppIcon.icns       the app's icon
build.sh                     compiles the app and builds "Claude Tracker.app" (Info.plist, icon, signature) for Applications
build_app.py                 runs build.sh for updates from 2.5.0 (the Python version); removed in a later release
install.sh / uninstall.sh    build the app and set up start-at-login / remove both
test.sh                      runs the tests
scripts/update-credits.sh    refreshes the Credits list from GitHub (run before a release)
```

## Requirements

- macOS 13 or newer
- Xcode's Command Line Tools, for Swift 5.9 or newer (`xcode-select --install`)

## Running the tests

```bash
./test.sh
```

The tests need Swift 6 (current Command Line Tools). One test compiles the whole app into a temporary folder, so it only runs when asked:

```bash
CT_SLOW_TESTS=1 ./test.sh
```

## License

MIT -- see [LICENSE](LICENSE). Copyright (c) 2026 Brody Kretz, the original creator, and (c) 2026 Raymond Tian for the work since the fork. If you copy or build on this code, keep the LICENSE file (with both copyright lines) with it; that's the MIT license's one condition.
