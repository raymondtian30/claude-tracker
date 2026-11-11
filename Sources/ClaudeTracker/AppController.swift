import AppKit
import TrackerCore

/// The running app (app.py's TokenCounterApp): owns state.json, the menu
/// bar item, the panel and the Settings window; scans on a timer and acts
/// on every click.
///
/// Everything here runs on the main thread. Network fetches, the update and
/// leaderboard work run on background queues and hand their results back to
/// the main thread (see `inBackground`), as the Python threads did with
/// AppHelper.callAfter. Scans stay on the main thread, as in the Python app:
/// they read only what's new since the last one.
///
/// The other areas live in extensions: Accounts (provider keys and account
/// numbers, Claude's percentages), Leaderboard, Updates, Alerts.
@MainActor
final class AppController {
    let files: AppState.Files
    var state: JSONObject = [:]
    /// Whether the first alert pass of this run has happened (memory only).
    var alertsSeeded = false

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) lazy var panel = PanelController(
        onAction: { [weak self] in self?.handleLater($0, $1) },
        onTabChange: { [weak self] key in self?.tabChanged(to: key) })
    private(set) lazy var settingsWindow = SettingsWindow(onAction: { [weak self] in self?.handleLater($0, $1) })
    let notifier = Notifier.live(title: Version.appName)

    /// Providers with an account fetch in flight.
    var fetchingAccounts = Set<String>()
    var fetchingClaudeUsage = false
    /// Shown in Settings > About while checking for or installing an update.
    var updateStatus: String?
    /// The Projects tab's "Show more".
    var projectsExpanded = false
    /// Whether the Custom range page is open (a tab of its own, after Home).
    /// Not saved: opening the panel or picking another tab closes it.
    var rangeOpen = false
    /// A tab to show once the next draw has made it (the Custom range page).
    private var tabToShow: String?
    /// The open sessions and plugin activity, as the last background scan
    /// found them (see `SessionRegistry`). Clicks draw its snapshot; they
    /// never scan. A scan covers all four tools, so changing the view only
    /// changes what is drawn.
    lazy var registry = SessionRegistry(
        source: { SessionRegistry.Inputs(processes: try ProcessTable.read(), records: ClaudeRecords.read(),
                                         now: Date().timeIntervalSince1970) },
        enrich: { scan, cache, withPlugins in
            SessionEnrichment.enrich(scan, cache: &cache, withPlugins: withPlugins)
        },
        background: { work in DispatchQueue.global(qos: .utility).async { work() } },
        main: { work in DispatchQueue.main.async { onMain { work() } } },
        onScan: { [weak self] _, changed in self?.liveScanned(changed: changed) },
        report: { FileHandle.standardError.write(Data("\($0)\n".utf8)) })

    /// The session diagnostics window (Settings > Scanning).
    lazy var diagnosticsWindow = DiagnosticsWindow()

    /// What the Live tab showed at the last draw. Stop, Resume and Quit act
    /// on this (the rows and start times the person saw), never on a later
    /// scan: a pid reused in between would then pass the start-time check.
    var liveView = LiveSnapshot()
    private var renderWaiting = false
    /// Rows whose detail is open, by row id. Not saved: opening the panel or
    /// changing tab closes them all.
    var openRows: [String: Bool] = [:]
    /// What the last render knows about each row (its folder).
    var rowInfo: [String: RowInfo] = [:]
    /// Whether Settings > About shows Credits. Not saved: it opens on About.
    var aboutShowsCredits = false
    /// The welcome picker's switches, in the order they were turned on.
    var welcomeChoice: [String] = []
    /// Friend list pushes and pulls run one at a time, off the main thread.
    let leaderboardQueue = DispatchQueue(label: "com.raymondtian.claudetracker.leaderboard")

    private var timer: Timer?
    private var subscriptionTimer: Timer?
    private var showObserver: NSObjectProtocol?

    init(files: AppState.Files) {
        self.files = files
    }

    // MARK: - Start-up

    func start() {
        let freshInstall = !FileManager.default.fileExists(atPath: files.state.path)
        do {
            state = try TokenMath.loadState(files.state)
        } catch {
            // Never start over on top of a file that couldn't be read: saving
            // would replace someone's totals.
            log("Couldn't read \(files.state.path): \(error)")
            exit(1)
        }
        if let problem = AppState.backupBeforeUpgrade(
            stateFile: files.state, freshInstall: freshInstall,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            copy: { try FileManager.default.copyItem(at: $0, to: $1) }) {
            log(problem)
        }
        AppState.applyLaunchDefaults(&state, freshInstall: freshInstall, today: Day.today())
        notifier.requestPermission()
        Appearance.apply(state.string("appearance") ?? PanelSpeeds.defaultAppearance)

        // Backfill must run before the first scan: it re-reads each file only
        // up to the offsets saved by the previous run.
        attempt("backfill daily totals") { try TokenMath.backfillDaily(&state) }
        attempt("backfill limits") { try TokenMath.backfillLimits(&state) }
        attempt("backfill efforts") { try TokenMath.backfillEfforts(&state) }
        scan()
        Subscriptions.refresh(&state)
        save()
        // The first launch after an update re-reads the logs; hand what that
        // used back to the system instead of keeping it as a footprint.
        malloc_zone_pressure_relief(nil, 0)
        fetchAccounts()
        fetchClaudeUsage()
        if state.removeValue(forKey: "updated_to") != nil {
            save()
            notifier.send("Updated to \(Version.version). Your settings are unchanged.")
        }

        panel.animationSeconds = PanelSpeeds.animationSeconds(state.string("panel_animation"))
        panel.attach(statusItem)
        panel.onWillShow = { [weak self] in
            self?.refreshSubscriptions()
            self?.openRows = [:]
            self?.projectsExpanded = false  // Projects opens short each time
            self?.closeRangePage()
            // Usually nothing is left to draw: `prewarmPanel` did it while the
            // panel was closed. No scan here either: the Live tab scans when it
            // is picked, and a scan competes with this draw for the CPU.
            self?.renderPanel()
        }
        panel.onHover = { [weak self] in onMain { self?.prewarmPanelOnHover() } }
        renderPanel()
        updateTitle()
        // Opening the app again (e.g. from Finder) asks this copy to show its panel.
        showObserver = SingleInstance.observeShowRequests { [weak self] in
            onMain { self?.panel.show() }
        }
        if !JSON.truthy(state["onboarding_done"]) {
            // First run: ask which tools to track, once the menu bar item is up.
            DispatchQueue.main.async { [weak self] in
                onMain { self?.panel.show() }
            }
        }
        startTimer(seconds: state.int("scan_interval_seconds") ?? AppState.refreshSeconds)
        startSubscriptionTimer()
    }

    // MARK: - Scanning

    /// Read new usage from every tool being tracked.
    func scan(detected: [String]? = nil) {
        let tools = Providers.toolsToScan(state, detected: detected ?? Tools.detectTools())
        attempt("scan") { try Tools.scanTools(&state, enabled: tools) }
    }

    /// The scan timer's tick.
    func refresh() {
        // Reading new log lines takes a moment, and a frame that waits for it
        // shows as lag: let the panel finish unfolding first.
        if panel.isAnimating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                onMain { self?.refresh() }
            }
            return
        }
        scan()
        Subscriptions.refresh(&state)
        save()
        checkAlerts()
        fetchAccounts()
        fetchClaudeUsage()
        updateTitle()
        runDailyLeaderboardSync()
        // The sessions are searched for in the background and drawn when found.
        if panel.isShown || settingsWindow.isShown {
            renderPanel()
            searchLive()
        } else {
            prewarmPanel(minimumGap: Self.prewarmGap)
        }
    }

    /// How long a closed panel may go without being brought up to date.
    static let prewarmGap = 30.0
    private var lastPrewarm = 0.0

    /// Draws the closed panel's Home tab now, so that opening it has next to
    /// nothing left to do. Building the views is the expensive part of an
    /// opening (a few hundred milliseconds of the main thread), and doing it in
    /// the click's own time makes the opening stutter, worst when the CPU is
    /// busy. The draw changes nothing when the data is the same as last time.
    /// Not while the panel is open or moving, and at most once per `minimumGap`.
    func prewarmPanel(minimumGap: Double = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !panel.isShown, !panel.isAnimating, now - lastPrewarm >= minimumGap else { return }
        lastPrewarm = now
        // What an opening resets anyway.
        openRows = [:]
        projectsExpanded = false
        closeRangePage()
        panel.goHome()
        renderPanel()
    }

    /// The pointer reached the menu bar icon: a click is probably coming.
    private func prewarmPanelOnHover() {
        prewarmPanel(minimumGap: 2)
    }

    private func startTimer(seconds: Int) {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            onMain { self?.refresh() }
        }
        // The default mode only, as rumps' timers: no scan while a dialog is open.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func startSubscriptionTimer() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            onMain { self?.refreshSubscriptions() }
        }
        RunLoop.main.add(timer, forMode: .default)
        subscriptionTimer = timer
    }

    private func refreshSubscriptions() {
        guard Subscriptions.refresh(&state) else { return }
        save()
        if panel.isShown { renderPanel() }
    }

    func setScanInterval(_ seconds: Int) {
        state["scan_interval_seconds"] = seconds
        save()
        // A fresh timer, so the new interval counts from now.
        startTimer(seconds: seconds)
    }

    // MARK: - Saving

    func save() {
        attempt("save \(files.state.path)") { try TokenMath.saveState(state, files.state) }
    }

    /// Runs `body`, logging (to ~/Library/Logs/ClaudeTracker/agent.err.log) instead of stopping on an error.
    func attempt(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            log("Couldn't \(what): \(error)")
        }
    }

    func log(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }

    // MARK: - Drawing

    func updateTitle() {
        let view = AppState.currentView(state, detected: Tools.detectTools())
        let count = AppState.menuBarCount(view, titleMode: state.string("title_mode"), today: Day.today())
        let image = view.key != "all" ? ToolIcons.menuBarImage(view.key) : nil
        let (title, showIcon) = AppState.menuBarLabel(view.key, count, hasIcon: image != nil)
        guard let button = statusItem.button else { return }
        // At the size picked in Settings, with even-width digits so the item
        // doesn't jiggle as the count changes.
        let size = CGFloat(state.int("menu_bar_font_size") ?? PanelModel.defaultMenuBarFontSize)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        button.image = showIcon ? image : nil
        button.imagePosition = .imageLeft
    }

    func renderPanel() {
        // Not while the panel unfolds or folds up: drawing takes a moment, and
        // a frame that has to wait for it shows as lag. It draws right after.
        if panel.isAnimating {
            if !renderWaiting {
                renderWaiting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    onMain {
                        self?.renderWaiting = false
                        self?.renderPanel()
                    }
                }
            }
            return
        }
        let detected = Tools.detectTools()
        let view = AppState.currentView(state, detected: detected)
        let enabled = AppState.strings(state["enabled_tools"])
        let friends = Leaderboard.sortedFriends(loadFriends(), by: state.string("leaderboard_view") ?? "total")
        // The saved search result, never a new search: that takes over half a
        // second, and every click draws. Another tool's? Search again.
        let tools = AppState.sessionTools(view.key, enabled: enabled)
        // The first scan of all; if it failed, the timer and the Live tab retry
        // it (drawing must not, or a failing `ps` would loop).
        if !registry.snapshot.scanned && registry.snapshot.error == nil && !registry.isScanning {
            searchLive()
        }
        let drawnLive = LiveSnapshot(registry.snapshot, tools: tools)
        liveView = drawnLive
        let result = PanelModel.buildPanelResult(
            view, state: state, sessions: [], friends: friends,
            showLeaderboard: AppState.showsLeaderboard(view.key, state: state),
            projectsExpanded: projectsExpanded, plugins: nil, rangeOpen: rangeOpen,
            context: PanelContext(open: openRows, measure: TextMeasures.live),
            live: drawnLive)
        let tabs = result.tabs
        rowInfo = result.rows
        OpenRows.prune(&openRows, present: Set(result.rows.keys))
        let firstSeen = state.string("first_seen_at") ?? Day.today().iso
        panel.render(
            tabs: tabs, footer: "Tracking since \(PanelModel.formatLongDate(firstSeen))",
            toolChoices: PanelModel.viewChoices(state, detected: detected), selectedTool: view.key,
            welcome: JSON.truthy(state["onboarding_done"]) ? nil
                : PanelModel.welcomeTab(detected: detected, chosen: welcomeChoice),
            subtitle: view.key == "all" ? "All AIs" : "for \(view.name)",
            // Same rule as the menu bar: the AI's logo, the coin when combined.
            logo: view.key != "all" ? ToolIcons.iconImage(view.key, size: ToolIcons.headerIconSize) : nil)
        if let key = tabToShow {
            tabToShow = nil
            panel.select(key: key)
        }
        if rangeOpen {
            panel.showRangePopup(PanelModel.rangePopupCard(view, state: state))
        } else {
            panel.closeRangePopup()
        }
        settingsWindow.render(PanelModel.settingsTab(state, intervalChoices: AppState.scanIntervalChoices,
                                                     detected: detected, updateStatus: updateStatus,
                                                     showCredits: aboutShowsCredits))
    }

    /// Picking another tab closes every open row, "Show less" the projects
    /// and the Custom range popup. The redraw waits for the next run-loop
    /// turn: this runs inside `selectTab`, which must not be re-entered.
    private func tabChanged(to key: String) {
        var changed = !openRows.isEmpty || projectsExpanded
        if key == "sessions" {
            // The Live tab is never older than its last look: until the scan
            // lands it says it is looking, not the previous scan's rows.
            registry.markStale()
            changed = true
            searchLive()
        }
        openRows = [:]
        projectsExpanded = false
        if rangeOpen {
            closeRangePage()
            changed = true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            onMain { self?.renderPanel() }
        }
    }

    /// Opens the Custom range popup.
    private func openRangePage() {
        RangeDraft.clear()
        rangeOpen = true
    }

    /// Closes the Custom range popup.
    private func closeRangePage() {
        rangeOpen = false
        RangeDraft.clear()
        panel.closeRangePopup()
    }

    /// Starts a scan for open sessions and plugin activity off the main
    /// thread (one at a time; one asked for during another runs right after
    /// it). When it ends, `liveScanned` draws the result.
    func searchLive() {
        let view = AppState.currentView(state, detected: Tools.detectTools())
        registry.withPlugins = AppState.showsPlugins(view.key, enabled: AppState.strings(state["enabled_tools"]))
        registry.refresh()
    }

    /// A scan ended. The Live tab is drawn after every scan while it is the
    /// tab on show, so ages ("idle for 5 min") and subagents stay current even
    /// when nothing else changed; any other tab is drawn only if the scan
    /// found something new.
    private func liveScanned(changed: Bool) {
        let liveShown = panel.isShown && panel.selected == "sessions"
        if (changed && (panel.isShown || settingsWindow.isShown)) || liveShown {
            renderPanel()
        } else if changed && !panel.isShown {
            prewarmPanel(minimumGap: 5)  // the closed panel's Live tab is out of date: draw it now, not at the click
        }
    }

    // MARK: - Actions

    /// Controls call this from inside their own event handling; act once
    /// that's done, since acting redraws (replaces) the control.
    private func handleLater(_ action: String, _ value: ActionValue) {
        DispatchQueue.main.async { [weak self] in
            onMain { self?.handle(action, value) }
        }
    }

    /// Called when a button, switch or picker in the panel or Settings is used.
    func handle(_ action: String, _ value: ActionValue) {
        guard let parsed = AppAction.parse(action, value) else {
            renderPanel()
            return
        }
        if parsed.opensDialog {
            panel.close()  // dialogs can't sit on top of the popover
        }
        switch parsed {
        case .quit:
            NSApp.terminate(nil)
            return
        case .openSettings:
            panel.close()
            settingsWindow.show()
        case .leaderboardSetup: startLeaderboardSetup()
        case .leaderboardShare: shareFriendCode()
        case .leaderboardAdd: addFriendByCode()
        case .providerKey(let provider): addAPIKey(provider)
        case .providerKeyRemove(let provider): removeAPIKey(provider)
        case .subscriptionEmail(let tool): editSubscriptionEmail(tool)
        case .subscriptionCard(let tool): editSubscriptionCard(tool)
        case .provider(let key, let on): setProviderEnabled(key, on)
        case .leaderboardPush: pushLeaderboardUpdate()
        case .leaderboardPull: pullLeaderboardUpdates()
        case .leaderboardView(let key):
            state["leaderboard_view"] = key
            save()
        case .titleMode(let mode):
            state["title_mode"] = mode
            save()
            updateTitle()
        case .menuBarFontSize(let size):
            state["menu_bar_font_size"] = size
            save()
            updateTitle()
        case .appearance(let key):
            state["appearance"] = key
            Appearance.apply(key)
            save()
        case .panelAnimation(let key):
            state["panel_animation"] = key
            panel.animationSeconds = PanelSpeeds.animationSeconds(key)
            save()
        case .alertsEnabled(let on):
            state["alerts_enabled"] = on
            save()
        case .alertThresholds(let thresholds):
            if AppState.setAlertThresholds(&state, thresholds) {
                save()
            }
        case .alertWindow(let window, let on):
            AppState.setAlertWindow(&state, window, on)
            save()
        case .alertTest: sendTestAlert()
        case .claudeUsageEnabled(let on):
            AppState.setClaudeUsageEnabled(&state, on)
            save()
            fetchClaudeUsage()
        case .scanInterval(let seconds): setScanInterval(seconds)
        case .login(let on): setStartAtLogin(on)
        case .leaderboardEnabled(let on):
            state["leaderboard_enabled"] = on
            save()
        case .showEffort(let on):
            state["show_effort"] = on
            save()
        case .chartDays, .chartAll, .chartCustom, .chartRange:
            let earliest = UsageStats.earliestDay(AppState.currentView(state, detected: Tools.detectTools()).daily)
            AppState.applyChart(parsed, to: &state, today: Day.today(), earliest: earliest)
            save()
            // Custom, and Change dates, open a popup to pick the dates on; Apply or another range closes it.
            if parsed == .chartCustom {
                openRangePage()
            } else {
                closeRangePage()
            }
        case .chartEdit: openRangePage()
        case .chartCancel: closeRangePage()
        case .currency(let code):
            state["currency"] = code
            save()
        case .modelSort(let key):
            state["model_sort"] = key
            save()
        case .projectsExpand: projectsExpanded.toggle()
        case .sessionStop(let pid): pauseOrResume(.stop, [pid])
        case .sessionResume(let pid): pauseOrResume(.resume, [pid])
        case .sessionQuit(let pid): quitSessions([pid])
        case .sessionsQuitAll: quitSessions(livePids)
        case .sessionsStopAll: pauseOrResume(.stop, livePids)
        case .sessionDiagnostics: showSessionDiagnostics()
        case .sessionsResumeAll: pauseOrResume(.resume, liveView.controllable.filter(\.stopped).compactMap(\.pid))
        case .aboutView(let showCredits): aboutShowsCredits = showCredits
        case .checkUpdates: checkForUpdates()
        case .openRepo:
            panel.close()
            if let url = URL(string: Version.repoURL) {
                NSWorkspace.shared.open(url)
            }
        case .selectTool(let index):
            let choices = PanelModel.viewChoices(state, detected: Tools.detectTools())
            if choices.indices.contains(index) {
                state["selected_tool"] = choices[index].key
                save()
                updateTitle()
                searchLive()  // the new view may show plugins the last scan didn't work out
            }
        case .welcomeTool(let key, let on):
            welcomeChoice = AppState.welcomeChoice(welcomeChoice, key, on)
        case .welcomeDone: finishWelcome()
        case .tool(let key, let on): setToolEnabled(key, on)
        case .toggleRow(let id):
            let home = UsageStats.homeDirectory
            OpenRows.toggle(&openRows, id: id, path: rowInfo[id]?.path) { path in
                let full = path.hasPrefix("~") ? home + path.dropFirst() : path
                return FileManager.default.fileExists(atPath: full)
            }
        }
        renderPanel()
    }

    func finishWelcome() {
        AppState.finishWelcome(&state, chosen: welcomeChoice)
        scan()
        save()
        updateTitle()
    }

    func setToolEnabled(_ key: String, _ on: Bool) {
        AppState.setToolEnabled(&state, key, on)
        if on {
            attempt("scan \(key)") { try Tools.scanTools(&state, enabled: [key]) }
        }
        save()
        updateTitle()
    }

    func setProviderEnabled(_ key: String, _ on: Bool) {
        AppState.setProviderEnabled(&state, key, on)
        if on {
            scan()  // a provider's models may be in tools not enabled yet
            fetchAccounts()
        }
        save()
        updateTitle()
    }

    func setStartAtLogin(_ on: Bool) {
        do {
            try LoginItem.setStartAtLogin(on)
        } catch {
            panel.close()
            Dialogs.alert("Couldn't update login setting", "\(error)")
            return
        }
        state["start_at_login"] = on
        save()
    }

    // MARK: - Background work

    /// Runs `work` on a background queue, then `done` with its result on the
    /// main thread. `work` must not touch the controller: pass it copies.
    func inBackground<Result>(on queue: DispatchQueue = .global(qos: .utility),
                              _ work: @escaping @Sendable () -> Result,
                              then done: @escaping @MainActor (Result) -> Void) {
        let box = UncheckedBox((work, done))
        queue.async {
            let result = UncheckedBox(box.value.0())
            DispatchQueue.main.async {
                onMain { box.value.1(result.value) }
            }
        }
    }
}

/// Hands a value to another thread. The values passed this way are copies
/// (JSON objects, strings) that only one thread uses at a time.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
