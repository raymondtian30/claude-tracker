// Tests for the Swift-only foundation (JSON files and values, Day,
// LocalTime). These have no Python counterpart: Python got them from its
// standard library.

import Foundation
import Testing
@testable import TrackerCore

@Test func jsonFileRoundTripKeepsUnknownKeys() throws {
    let tmp = TempDir()
    let file = tmp.url("state.json")
    writeText(file, #"{"grand_total": 5, "future_key": {"nested": [1, 2.5, null, true]}, "first_seen_at": null}"#)

    var state = try TokenMath.loadState(file)
    state["grand_total"] = 6
    try TokenMath.saveState(state, file)

    let saved = try JSON.loadObject(file)
    #expect(jsonEqual(saved, ["grand_total": 6, "future_key": ["nested": [1, 2.5, NSNull(), true]],
                              "first_seen_at": NSNull()]))
}

@Test func loadStateDefaultsWhenTheFileIsMissing() throws {
    let tmp = TempDir()
    let state = try TokenMath.loadState(tmp.url("state.json"))
    #expect(jsonEqual(state, ["grand_total": 0, "file_offsets": JSONObject(), "first_seen_at": NSNull()]))
}

@Test func jsonWriteRefusesValuesJSONCantHold() {
    #expect(throws: JSON.InvalidValue.self) { try JSON.encode(["x": Double.nan]) }
}

@Test func typedGettersTolerateIntAndDoubleMixing() throws {
    let parsed = try #require(JSON.parseObject(Data(#"{"i": 3, "d": 2.5, "w": 4.0, "b": true, "n": null, "s": "x"}"#.utf8)))
    #expect(parsed.int("i") == 3)
    #expect(parsed.double("i") == 3.0)
    #expect(parsed.int("w") == 4)
    #expect(parsed.int("d") == 2)
    #expect(parsed.double("d") == 2.5)
    #expect(parsed.int("b") == nil)
    #expect(parsed.bool("b") == true)
    #expect(parsed.bool("i") == nil)
    #expect(parsed.int("n") == nil)
    #expect(parsed.string("s") == "x")
    #expect(JSON.isInteger(parsed["i"]) && !JSON.isInteger(parsed["d"]))
    let native: JSONObject = ["i": 3, "d": 2.5, "b": false]
    #expect(native.double("i") == 3.0 && native.int("d") == 2 && native.bool("b") == false)
}

@Test func truthyMatchesPythonBool() {
    #expect(!JSON.truthy(nil) && !JSON.truthy(NSNull()) && !JSON.truthy(0) && !JSON.truthy(""))
    #expect(!JSON.truthy([Any]()) && !JSON.truthy(JSONObject()) && !JSON.truthy(false))
    #expect(JSON.truthy(1) && JSON.truthy(0.5) && JSON.truthy("x") && JSON.truthy([1]) && JSON.truthy(true))
}

@Test func dayArithmeticAndISO() {
    #expect(Day(2026, 3, 1).adding(days: -1) == Day(2026, 2, 28))
    #expect(Day(2024, 3, 1).adding(days: -1) == Day(2024, 2, 29))
    #expect(Day(2026, 12, 31).adding(days: 1) == Day(2027, 1, 1))
    #expect(Day(iso: "2026-07-09")?.iso == "2026-07-09")
    #expect(Day(iso: "2026-02-30") == nil)
    #expect(Day.min < Day(2026, 1, 1) && Day(2026, 1, 1) < Day.max)
    #expect(Day(2026, 11, 8).firstOfMonth == Day(2026, 11, 1))
}

@Test func parseISOTimestamps() {
    let utcNoon = Double(Day(2026, 7, 29).ordinal * 86_400 + 12 * 3600)
    #expect(LocalTime.parseISO("2026-07-29T12:00:00.000Z") == utcNoon)
    #expect(LocalTime.parseISO("2026-07-29T12:00:00Z") == utcNoon)
    #expect(LocalTime.parseISO("2026-07-29T14:00:00+02:00") == utcNoon)
    #expect(LocalTime.parseISO("2026-07-29T12:00:00.5Z") == utcNoon + 0.5)
    // No zone: local time, as Python reads it.
    #expect(LocalTime.parseISO("2026-07-29T12:00:00") == LocalTime.timestamp(2026, 7, 29, 12))
    #expect(LocalTime.parseISO("not a time") == nil)
    #expect(Day(timestamp: LocalTime.timestamp(2026, 7, 29, 23, 59)) == Day(2026, 7, 29))
}

@Test func animationSecondsFallsBackToNormal() {
    #expect(PanelSpeeds.animationSeconds("fast") == 0.12)
    #expect(PanelSpeeds.animationSeconds("off") == 0.0)
    #expect(PanelSpeeds.animationSeconds("nope") == 0.22)
}
