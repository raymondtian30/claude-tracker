// Conventions for the Swift port (every wave follows these)
// ----------------------------------------------------------
// - Sources/ compiles with Swift 5.9 in Swift 5 language mode: no
//   Swift-6-only syntax (typed throws, `sending`, noncopyable generics...).
//   Tests may use Swift Testing (`import Testing`, `@Test`, `#expect`).
// - Each Python module is a caseless `enum` of the same name in Swift style
//   (token_math.py -> `enum TokenMath`), so functions from different modules
//   can't collide. Constants are `static let`; snake_case becomes camelCase.
// - Data read from or written to JSON files or APIs stays `JSONObject`, read
//   through the typed getters below (`state.int("grand_total")`). Values the
//   code builds itself (levels, totals, panel items) may be structs, with
//   field names matching the Python keys in camelCase.
// - Anything that shells out, hits the network or reads the clock takes an
//   injectable parameter (a closure, or a `now:` value) with the real thing
//   as the default, like the Python `run=`, `get=`, `now=` parameters.
// - Local dates use the current time zone (see `Day` and `LocalTime`).
// - Python's dict order, rounding and float formatting matter where the
//   tests check text: match Python's output exactly. Where Python relied on
//   dict insertion order to break ties, the Swift code breaks them by name
//   and says so.
// - Tests are ported test for test: one `@Test` per Python test function,
//   same name in camelCase, same fixtures and assertions. Shared helpers
//   live in Tests/TrackerCoreTests/Helpers.swift.
// - Panel types (Tab, Card, Item) are in PanelItems.swift. SwiftUI (macOS 15
//   SDK) also has a `Tab`: in the app target, add
//   `typealias Tab = TrackerCore.Tab` once so the module's own name wins.

import Foundation

/// A JSON object as `JSONSerialization` reads it: what state.json,
/// friends.json entries and API answers are made of.
public typealias JSONObject = [String: Any]

/// Reading and writing JSON files, and typed reads of loosely typed values.
///
/// Files are read and written whole, so keys this app doesn't know survive
/// a load and save untouched. Values keep Python's shapes: numbers, strings,
/// bools, null (`NSNull`), arrays and objects. That keeps state.json and
/// friends.json readable by the Python app too.
public enum JSON {
    /// A value that can't be written as JSON (a non-JSON type, NaN, infinity).
    public struct InvalidValue: Error, CustomStringConvertible {
        public let description: String
    }

    // MARK: - Files

    /// The JSON value in `url`, or nil if the file doesn't exist. Throws if
    /// it can't be read or isn't valid JSON.
    public static func read(_ url: URL) throws -> Any? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The JSON object in `url`, or nil if the file doesn't exist. Throws if
    /// it can't be read or doesn't hold an object.
    public static func loadObject(_ url: URL) throws -> JSONObject? {
        guard let value = try read(url) else { return nil }
        guard let object = value as? JSONObject else {
            throw InvalidValue(description: "\(url.path) doesn't hold a JSON object")
        }
        return object
    }

    /// Writes `value` to `url` atomically: a crash mid-write leaves the old
    /// file, never half a file.
    public static func write(_ value: Any, to url: URL) throws {
        try encode(value).write(to: url, options: .atomic)
    }

    // MARK: - Data

    /// JSON bytes for `value`, compact like Python's `json.dumps`.
    public static func encode(_ value: Any) throws -> Data {
        // JSONSerialization raises an Objective-C exception (which Swift
        // can't catch) for values it can't write, so check first.
        guard JSONSerialization.isValidJSONObject([value]) else {
            throw InvalidValue(description: "not valid JSON: \(value)")
        }
        return try JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    /// The JSON value in `data`, or nil if it isn't valid JSON.
    public static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The JSON object in `data`, or nil if it isn't one.
    public static func parseObject(_ data: Data) -> JSONObject? {
        parse(data) as? JSONObject
    }

    // MARK: - Typed reads

    /// A whole number: Int as is, a Double cut to an Int (5.0 -> 5, 5.7 -> 5).
    /// nil for anything else, bools included (Python's `True` is an int, but
    /// no JSON value here uses one as a number).
    public static func int(_ value: Any?) -> Int? {
        guard let number = plainNumber(value) else { return nil }
        if !CFNumberIsFloatType(number) { return number.intValue }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 9.2e18 else { return nil }
        return Int(double)
    }

    /// Any number as a Double.
    public static func double(_ value: Any?) -> Double? {
        plainNumber(value)?.doubleValue
    }

    /// True when `value` is a number stored without a fraction (a JSON
    /// integer), so arithmetic on it can stay whole as Python's would.
    public static func isInteger(_ value: Any?) -> Bool {
        guard let number = plainNumber(value) else { return false }
        return !CFNumberIsFloatType(number)
    }

    public static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    public static func string(_ value: Any?) -> String? {
        value as? String
    }

    public static func object(_ value: Any?) -> JSONObject? {
        value as? JSONObject
    }

    public static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    /// Python's `bool(value)`: false for null, false, 0, "" and empty
    /// arrays and objects. For settings read like `state.get(key, True)`:
    /// `state[key].map { JSON.truthy($0) } ?? true`.
    public static func truthy(_ value: Any?) -> Bool {
        guard let value = value, !(value is NSNull) else { return false }
        if let flag = bool(value) { return flag }
        if let number = plainNumber(value) { return number.doubleValue != 0 }
        if let text = value as? String { return !text.isEmpty }
        if let list = value as? [Any] { return !list.isEmpty }
        if let object = value as? JSONObject { return !object.isEmpty }
        return true
    }

    /// True for a missing value or JSON null (Python's `None`).
    public static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// Python's `==` on JSON values: 1 == 1.0, dicts compare without order.
    public static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        ([a ?? NSNull()] as NSArray).isEqual(to: [b ?? NSNull()])
    }

    /// A number that isn't a bool. Swift's Int and Double in an `Any` bridge
    /// to NSNumber too, so one path handles both sources of values.
    private static func plainNumber(_ value: Any?) -> NSNumber? {
        guard let value = value, !(value is NSNull),
              let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }
}

/// Typed reads of one key, e.g. `state.int("grand_total") ?? 0`.
public extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? { JSON.int(self[key]) }
    func double(_ key: String) -> Double? { JSON.double(self[key]) }
    func bool(_ key: String) -> Bool? { JSON.bool(self[key]) }
    func string(_ key: String) -> String? { JSON.string(self[key]) }
    func object(_ key: String) -> JSONObject? { JSON.object(self[key]) }
    func array(_ key: String) -> [Any]? { JSON.array(self[key]) }
}
