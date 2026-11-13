import Foundation
import Testing
@testable import TrackerCore

private func models(_ text: String) -> [OpencodeCatalog.Model]? {
    OpencodeCatalog.models(Data(text.utf8))
}

@Test func catalogBodyReadsTheSameAsObjectOrAsText() {
    let body = #"{"google":{"models":{"g-1":{"name":"G \"one\" é😀","limit":{"context":1e3,"output":-2.5}}}}}"#
    let asObject = models(#"{"updatedAt":1,"body":\#(body)}"#)
    let escaped = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let asText = models(#"{"body":"\#(escaped)","digest":"x"}"#)
    let expected = [OpencodeCatalog.Model(vendor: "google", id: "g-1", isObject: true, name: "G \"one\" é😀",
                                          context: 1000, output: -2.5)]
    #expect(asObject == expected)
    #expect(asText == expected)
}

@Test func catalogSkipsWhatIsNotUsedAndKeepsTheLastOfARepeatedKey() {
    let found = models(#"""
        {"body": {"a": {"x": [1, {"y": null}, "z"], "models": {"m": 5, "n": {"name": 7, "name": "N",
         "cost": {"text": {"input": {"price": true, "cache": {"read": 0.25}}, "output": {"price": 4}}}}}},
          "b": "text", "c": {"models": [1]}, "d": {"models": {}}}}
        """#)
    #expect(found == [
        OpencodeCatalog.Model(vendor: "a", id: "m"),
        OpencodeCatalog.Model(vendor: "a", id: "n", isObject: true, name: "N", outputPrice: 4, cacheReadPrice: 0.25),
    ])
}

@Test func catalogThatIsNotValidJSONGivesNothing() {
    #expect(models(#"{"body": {"a": {"models": {"m": {}}}}"#) == nil)  // unclosed
    #expect(models(#"{"body": {"a": {"models": {"m": {}}}}} junk"#) == nil)
    #expect(models(#"{"body": {"a": {"models": {"m": tru}}}}"#) == nil)
    #expect(models(#"{"body": "{\"a\": {\"models\": {\"m\": {}}}"}"#) == nil)  // body text unclosed
    #expect(models(#"{"body": "{\"a\": 1} x"}"#) == nil)
    #expect(models(#"{"body": [1]}"#) == nil)
    #expect(models(#"{"other": 1}"#) == nil)
    #expect(models("") == nil)
    #expect(models(#"{"body": {}}"#) == [])
}
