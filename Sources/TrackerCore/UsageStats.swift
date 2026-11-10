import Foundation

/// Per-day usage buckets, and the views built from them (breakdown, models,
/// projects, history).
///
/// state["daily"] maps an ISO date to:
///
///     {
///         "models": {model_id: {category: tokens, ...}, ...},
///         "projects": {project_label: tokens, ...},
///         "model_projects": {model_id: {project_label: tokens}},  # newer buckets
///         "recorded_cost": {model_id: dollars},  # when a tool records cost
///     }
///
/// where category is one of `categories`. Everything the menu shows (today,
/// by model, by project, history, cost) is derived from these buckets.
public enum UsageStats {
    public static let categories = ["input", "output", "cache_write_5m", "cache_write_1h", "cache_read"]

    public static let worktreeMarker = "/.claude/worktrees/"

    /// {model: {category: tokens}}, as built from the buckets.
    public typealias Models = [String: [String: Int]]

    /// A name (model or project) and its tokens, as the sorted lists give them.
    public struct NamedTotal: Equatable {
        public let name: String
        public let tokens: Int
        public init(_ name: String, _ tokens: Int) {
            self.name = name
            self.tokens = tokens
        }
    }

    /// A day and its tokens.
    public struct DayTotal: Equatable {
        public let day: Day
        public let tokens: Int
        public init(_ day: Day, _ tokens: Int) {
            self.day = day
            self.tokens = tokens
        }
    }

    /// Totals for the History menu.
    public struct History: Equatable {
        public let yesterday: Int
        public let last7Days: Int
        public let thisMonth: Int
        public let biggestDay: DayTotal?
    }

    /// A tool's data on disk isn't in the shape the app expects.
    public struct SourceFormatError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// The local calendar date a log entry's UTC timestamp (e.g.
    /// "2026-07-23T04:42:51.880Z") falls on; nil if it can't be read.
    static func localDateOf(_ timestamp: String) -> Day? {
        LocalTime.parseISO(timestamp).map { Day(timestamp: $0) }
    }

    /// Split one API usage object into `categories` token counts.
    public static func splitUsage(_ usage: JSONObject) -> [String: Int] {
        let cacheWrite = usage.int("cache_creation_input_tokens") ?? 0
        let detail = usage.object("cache_creation") ?? [:]
        let write1h = Swift.min(detail.int("ephemeral_1h_input_tokens") ?? 0, cacheWrite)
        return [
            "input": usage.int("input_tokens") ?? 0,
            "output": usage.int("output_tokens") ?? 0,
            "cache_write_5m": cacheWrite - write1h,
            "cache_write_1h": write1h,
            "cache_read": usage.int("cache_read_input_tokens") ?? 0,
        ]
    }

    /// The user's home folder, as Python's `Path.home()` finds it.
    public static var homeDirectory: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// Human-readable project name for a session's working directory.
    ///
    /// Agent worktrees (<project>/.claude/worktrees/<id>) are folded into the
    /// project they belong to.
    public static func projectLabel(_ cwd: String?, home: String? = nil) -> String {
        guard var cwd = cwd, !cwd.isEmpty else { return "Unknown" }
        if let marker = cwd.range(of: worktreeMarker) {
            cwd = String(cwd[..<marker.lowerBound])
        }
        let home = home ?? homeDirectory
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~/" + cwd.dropFirst(home.count + 1)
        }
        return cwd
    }

    /// Add one parsed assistant log entry to the daily buckets.
    public static func recordEntry(_ daily: inout JSONObject, _ entry: JSONObject) {
        let message = entry.object("message") ?? [:]
        guard let usage = message.object("usage"), !usage.isEmpty,
              let timestamp = entry.string("timestamp"), !timestamp.isEmpty,
              let day = localDateOf(timestamp)
        else { return }
        let parts = splitUsage(usage)
        if parts.values.reduce(0, +) == 0 {
            return
        }
        let model = message.string("model").flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        // `effort` is the level the response ran at; `perTurnEffort` is the
        // fallback (the two differ on some entries, and `effort` is preferred).
        let effort = normalizeEffort(entry["effort"]) ?? normalizeEffort(entry["perTurnEffort"])
        addUsage(&daily, day: day, model: model, project: projectLabel(entry.string("cwd")),
                 parts: parts, effort: effort)
    }

    /// An effort level as kept ("high"): lowercase letters, digits, "_" and
    /// "-", 1 to 12 characters. Anything else is no effort.
    public static func normalizeEffort(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (1...12).contains(text.count),
              text.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-" })
        else { return nil }
        return text
    }

    /// Add one response's token `parts` ({category: tokens}) to the buckets
    /// for `day`. `cost` is a dollar amount the tool itself recorded, if any.
    public static func addUsage(_ daily: inout JSONObject, day: Day, model: String, project: String,
                                parts: [String: Int], cost: Double? = nil, effort: String? = nil) {
        var bucket = daily.object(day.iso) ?? ["models": JSONObject(), "projects": JSONObject()]
        var models = bucket.object("models") ?? [:]
        var modelParts = models.object(model) ?? zeroParts()
        for (category, count) in parts {
            modelParts[category] = (modelParts.int(category) ?? 0) + count
        }
        models[model] = modelParts
        bucket["models"] = models

        let tokens = parts.values.reduce(0, +)
        var projects = bucket.object("projects") ?? [:]
        projects[project] = (projects.int(project) ?? 0) + tokens
        bucket["projects"] = projects

        var modelProjects = bucket.object("model_projects") ?? [:]
        var perModel = modelProjects.object(model) ?? [:]
        perModel[project] = (perModel.int(project) ?? 0) + tokens
        modelProjects[model] = perModel
        bucket["model_projects"] = modelProjects

        // Tokens per model and effort, for the models whose tool says the level.
        if let effort = effort {
            var efforts = bucket.object("efforts") ?? [:]
            var perEffort = efforts.object(model) ?? [:]
            perEffort[effort] = (perEffort.int(effort) ?? 0) + tokens
            efforts[model] = perEffort
            bucket["efforts"] = efforts
        }

        if let cost = cost {
            var costs = bucket.object("recorded_cost") ?? [:]
            costs[model] = (costs.double(model) ?? 0.0) + cost
            bucket["recorded_cost"] = costs
        }
        daily[day.iso] = bucket
    }

    static func zeroParts() -> JSONObject {
        var parts = JSONObject()
        for category in categories {
            parts[category] = 0
        }
        return parts
    }

    // MARK: - Merging and filtering buckets

    private enum Combine {
        case sum, max
    }

    /// `combine(a, b)` on two JSON numbers, staying whole when both are,
    /// as Python's int arithmetic does.
    private static func combined(_ a: Any, _ b: Any?, _ combine: Combine) -> Any {
        if JSON.isInteger(a), JSON.isInteger(b) {
            let (x, y) = (JSON.int(a) ?? 0, JSON.int(b) ?? 0)
            return combine == .sum ? x + y : Swift.max(x, y)
        }
        let (x, y) = (JSON.double(a) ?? 0, JSON.double(b) ?? 0)
        return combine == .sum ? x + y : Swift.max(x, y)
    }

    /// Merge per-day buckets with `combine` for each number.
    private static func combineBuckets(_ dailies: [JSONObject], _ combine: Combine) -> JSONObject {
        var merged = JSONObject()
        for daily in dailies {
            for (iso, value) in daily {
                let bucket = JSON.object(value) ?? [:]
                var into = merged.object(iso) ?? ["models": JSONObject(), "projects": JSONObject()]
                var models = into.object("models") ?? [:]
                for (model, parts) in bucket.object("models") ?? [:] {
                    var intoParts = models.object(model) ?? zeroParts()
                    for (category, count) in JSON.object(parts) ?? [:] {
                        intoParts[category] = combined(intoParts[category] ?? 0, count, combine)
                    }
                    models[model] = intoParts
                }
                into["models"] = models
                into["projects"] = combineNumbers(into.object("projects") ?? [:],
                                                  bucket.object("projects") ?? [:], start: 0, combine)
                if let costs = bucket.object("recorded_cost"), !costs.isEmpty {
                    into["recorded_cost"] = combineNumbers(into.object("recorded_cost") ?? [:],
                                                           costs, start: 0.0, combine)
                }
                if let perModel = bucket.object("model_projects"), !perModel.isEmpty {
                    var intoPerModel = into.object("model_projects") ?? [:]
                    for (model, projects) in perModel {
                        intoPerModel[model] = combineNumbers(intoPerModel.object(model) ?? [:],
                                                             JSON.object(projects) ?? [:], start: 0, combine)
                    }
                    into["model_projects"] = intoPerModel
                }
                if let efforts = bucket.object("efforts"), !efforts.isEmpty {
                    var intoEfforts = into.object("efforts") ?? [:]
                    for (model, perEffort) in efforts {
                        intoEfforts[model] = combineNumbers(intoEfforts.object(model) ?? [:],
                                                            JSON.object(perEffort) ?? [:], start: 0, combine)
                    }
                    into["efforts"] = intoEfforts
                }
                merged[iso] = into
            }
        }
        return merged
    }

    /// {key: number} `into` with each of `more` combined in; a key `into`
    /// doesn't have starts at `start`.
    private static func combineNumbers(_ into: JSONObject, _ more: JSONObject, start: Any,
                                       _ combine: Combine) -> JSONObject {
        var result = into
        for (key, number) in more {
            result[key] = combined(result[key] ?? start, number, combine)
        }
        return result
    }

    /// New buckets holding only the models `keepModel(model)` accepts.
    ///
    /// Projects come from the per-model record. Older buckets don't have one:
    /// their projects are kept only when every model in the bucket is kept, and
    /// left out otherwise rather than guessed.
    public static func filterDaily(_ daily: JSONObject, keepModel: (String) -> Bool) -> JSONObject {
        var filtered = JSONObject()
        for (iso, value) in daily {
            let bucket = JSON.object(value) ?? [:]
            let allModels = bucket.object("models") ?? [:]
            let models = allModels.filter { keepModel($0.key) }
            if models.isEmpty {
                continue
            }
            var out: JSONObject = ["models": models, "projects": JSONObject()]
            if let perModel = bucket.object("model_projects") {
                var outPerModel = JSONObject()
                var projects = JSONObject()
                for model in models.keys {
                    let modelProjects = perModel.object(model) ?? [:]
                    outPerModel[model] = modelProjects
                    projects = combineNumbers(projects, modelProjects, start: 0, .sum)
                }
                out["model_projects"] = outPerModel
                out["projects"] = projects
            } else if models.count == allModels.count {
                out["projects"] = bucket.object("projects") ?? [:]
            }
            let costs = (bucket.object("recorded_cost") ?? [:]).filter { models[$0.key] != nil }
            if !costs.isEmpty {
                out["recorded_cost"] = costs
            }
            let efforts = (bucket.object("efforts") ?? [:]).filter { models[$0.key] != nil }
            if !efforts.isEmpty {
                out["efforts"] = efforts
            }
            filtered[iso] = out
        }
        return filtered
    }

    /// Sum several tools' per-day buckets into new buckets.
    public static func mergeDaily(_ dailies: [JSONObject]) -> JSONObject {
        combineBuckets(dailies, .sum)
    }

    /// Merge a fresh read into saved buckets, keeping the larger number
    /// everywhere, so data a tool later deletes never shrinks history.
    public static func mergeMaxDaily(_ saved: JSONObject, _ current: JSONObject) -> JSONObject {
        combineBuckets([saved, current], .max)
    }

    // MARK: - Views over a date range

    /// {model: dollars} the tools themselves recorded for [start, end].
    public static func recordedCostInRange(_ daily: JSONObject, _ start: Day, _ end: Day) -> [String: Double] {
        var totals = [String: Double]()
        for bucket in daysInRange(daily, start, end) {
            for (model, dollars) in bucket.object("recorded_cost") ?? [:] {
                totals[model, default: 0.0] += JSON.double(dollars) ?? 0
            }
        }
        return totals
    }

    /// Buckets for dates in [start, end], inclusive.
    static func daysInRange(_ daily: JSONObject, _ start: Day, _ end: Day) -> [JSONObject] {
        daily.compactMap { iso, bucket in
            guard let day = Day(iso: iso), start <= day, day <= end else { return nil }
            return JSON.object(bucket)
        }
    }

    /// {model: {category: tokens}} summed over [start, end].
    public static func modelsInRange(_ daily: JSONObject, _ start: Day, _ end: Day) -> Models {
        var totals = Models()
        for bucket in daysInRange(daily, start, end) {
            for (model, value) in bucket.object("models") ?? [:] {
                let parts = JSON.object(value) ?? [:]
                var into = totals[model] ?? Dictionary(uniqueKeysWithValues: categories.map { ($0, 0) })
                for category in categories {
                    into[category, default: 0] += parts.int(category) ?? 0
                }
                totals[model] = into
            }
        }
        return totals
    }

    /// {model: {effort: tokens}} over [start, end], for the responses whose
    /// effort is known. A model's total in `modelsInRange` can be larger (the
    /// rest has no known effort), never meant to be smaller. Anything in the
    /// saved maps that isn't a count reads as none.
    public static func effortsInRange(_ daily: JSONObject, _ start: Day, _ end: Day) -> [String: [String: Int]] {
        var totals = [String: [String: Int]]()
        for bucket in daysInRange(daily, start, end) {
            for (model, value) in bucket.object("efforts") ?? [:] {
                for (effort, tokens) in JSON.object(value) ?? [:] {
                    if let count = JSON.int(tokens), count > 0 {
                        totals[model, default: [:]][effort, default: 0] += count
                    }
                }
            }
        }
        return totals
    }

    public static func effortsAllTime(_ daily: JSONObject) -> [String: [String: Int]] {
        effortsInRange(daily, .min, .max)
    }

    public static func modelsAllTime(_ daily: JSONObject) -> Models {
        modelsInRange(daily, .min, .max)
    }

    /// {category: tokens} summed across models.
    public static func categoryTotals(_ models: Models) -> [String: Int] {
        var totals = [String: Int]()
        for category in categories {
            totals[category] = models.values.reduce(0) { $0 + ($1[category] ?? 0) }
        }
        return totals
    }

    /// [(model, tokens)] sorted by tokens, most first. Python kept dict
    /// order for ties; Swift dictionaries have none, so ties go by name.
    public static func modelTotals(_ models: Models) -> [NamedTotal] {
        sortedMostFirst(models.map { NamedTotal($0.key, $0.value.values.reduce(0, +)) })
    }

    public static func totalInRange(_ daily: JSONObject, _ start: Day, _ end: Day) -> Int {
        modelTotals(modelsInRange(daily, start, end)).reduce(0) { $0 + $1.tokens }
    }

    static func sortedMostFirst(_ rows: [NamedTotal]) -> [NamedTotal] {
        rows.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
    }

    /// Merge a subfolder's tokens into its parent when the parent is also a
    /// project (e.g. "~/game/tools" into "~/game"). "~" and "/" (and "~/",
    /// which is "~" without its slash) are never parents: they would
    /// otherwise swallow every other project, and keep their own row.
    static func foldSubfolders(_ totals: [String: Int]) -> [String: Int] {
        var folded = [String: Int]()
        // Shortest first, so a parent is always in `folded` before its
        // subfolders; ties by name only to make the order fixed.
        let byLength = totals.keys.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
        for project in byLength {
            let parent = folded.keys.first {
                let trimmed = trimmingTrailingSlashes($0)
                return !trimmed.isEmpty && trimmed != "~" && project.hasPrefix(trimmed + "/")
            }
            folded[parent ?? project, default: 0] += totals[project] ?? 0
        }
        return folded
    }

    /// Python's `str.rstrip("/")`.
    private static func trimmingTrailingSlashes(_ text: String) -> String {
        var text = Substring(text)
        while text.hasSuffix("/") {
            text = text.dropLast()
        }
        return String(text)
    }

    /// (project, tokens) used between `start` and `end`, most first; all of
    /// them unless `limit` is given.
    public static func topProjects(_ daily: JSONObject, _ start: Day, _ end: Day,
                                   limit: Int? = nil) -> [NamedTotal] {
        var totals = [String: Int]()
        for bucket in daysInRange(daily, start, end) {
            for (project, tokens) in bucket.object("projects") ?? [:] {
                totals[project, default: 0] += JSON.int(tokens) ?? 0
            }
        }
        let rows = sortedMostFirst(foldSubfolders(totals).map { NamedTotal($0.key, $0.value) })
        return limit.map { Array(rows.prefix($0)) } ?? rows
    }

    /// (date, tokens) of the highest-usage day, or nil if no data. Python
    /// kept the first of equal days in dict order; here it's the earliest.
    public static func biggestDay(_ daily: JSONObject) -> DayTotal? {
        var best: DayTotal?
        for iso in daily.keys.sorted() {
            guard let day = Day(iso: iso), let bucket = daily.object(iso) else { continue }
            let tokens = (bucket.object("models") ?? [:]).values.reduce(0) { total, parts in
                total + (JSON.object(parts) ?? [:]).values.reduce(0) { $0 + (JSON.int($1) ?? 0) }
            }
            if best == nil || tokens > best!.tokens {
                best = DayTotal(day, tokens)
            }
        }
        return best
    }

    /// Totals for the History menu.
    public static func history(_ daily: JSONObject, today: Day? = nil) -> History {
        let today = today ?? Day.today()
        let yesterday = today.adding(days: -1)
        return History(
            yesterday: totalInRange(daily, yesterday, yesterday),
            last7Days: totalInRange(daily, today.adding(days: -6), today),
            thisMonth: totalInRange(daily, today.firstOfMonth, today),
            biggestDay: biggestDay(daily)
        )
    }

    /// One point of a chart: the tokens used from `start` to `end`, both
    /// included (a single day when they are the same).
    public struct RangePoint: Equatable {
        public let start: Day
        public let end: Day
        public let tokens: Int
        public init(_ start: Day, _ end: Day, _ tokens: Int) {
            self.start = start
            self.end = end
            self.tokens = tokens
        }
    }

    /// The oldest day with a bucket, or nil when there is none.
    public static func earliestDay(_ daily: JSONObject) -> Day? {
        daily.keys.compactMap { Day(iso: $0) }.min()
    }

    /// Tokens per day from `from` to `to`, oldest first, 0 for days with no
    /// usage. A range longer than `maxPoints` days is grouped into equal runs
    /// of days (the last may be shorter), so a long history stays readable;
    /// every token still lands in exactly one point. Empty when `to` is
    /// before `from`. One pass over the saved days, however long the range.
    public static func rangeSeries(_ daily: JSONObject, from: Day, to: Day, maxPoints: Int = 60) -> [RangePoint] {
        let count = from.days(to: to) + 1
        guard count > 0 else { return [] }
        let run = Swift.max((count + maxPoints - 1) / maxPoints, 1)
        var tokens = [Int](repeating: 0, count: (count + run - 1) / run)
        for (iso, value) in daily {
            guard let day = Day(iso: iso), from <= day, day <= to else { continue }
            let models = JSON.object(value)?.object("models") ?? [:]
            let used = models.values.reduce(0) { total, parts in
                let parts = JSON.object(parts) ?? [:]
                return total + categories.reduce(0) { $0 + (parts.int($1) ?? 0) }
            }
            tokens[from.days(to: day) / run] += used
        }
        return tokens.enumerated().map { index, used in
            let start = from.adding(days: index * run)
            let end = Swift.min(start.adding(days: run - 1), to)
            return RangePoint(start, end, used)
        }
    }

    /// [(date, tokens)] for each of the `days` days ending on `end`, oldest
    /// first, with 0 for days that have no usage.
    public static func dailySeries(_ daily: JSONObject, _ end: Day, _ days: Int) -> [DayTotal] {
        stride(from: days - 1, through: 0, by: -1).map { offset in
            let day = end.adding(days: -offset)
            return DayTotal(day, totalInRange(daily, day, day))
        }
    }
}
