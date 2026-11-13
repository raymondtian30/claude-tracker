import Foundation

/// opencode's model catalog (`kv` row `models-dev:v2:catalog`), read a piece
/// at a time. The catalog runs to megabytes and parsing it whole, in the app
/// or in SQLite, took 50 to 90 MB; this keeps only the few fields
/// `OpencodeSource.scanBYOK` uses and skips the rest as it goes, so reading
/// it takes about the same memory whatever its size.
///
/// The row is `{"body": {...}}` or `{"body": "<that object as text>"}`.
/// Fields read as the typed getters would read them from the parsed JSON: a
/// name only when it's text, limits and prices only when they're numbers.
public enum OpencodeCatalog {
    /// One model entry of one integration.
    public struct Model: Equatable {
        public var vendor: String
        public var id: String
        /// Whether the entry is a JSON object; only those have details.
        public var isObject = false
        public var name: String?
        public var context: Double?
        public var input: Double?
        public var output: Double?
        public var inputPrice: Double?
        public var outputPrice: Double?
        public var cacheReadPrice: Double?
    }

    /// The JSON isn't valid, or doesn't have the expected shape.
    struct Malformed: Error {}

    /// Every model entry in `source`'s catalog. Integrations that aren't
    /// objects, or whose `models` isn't one, have none. nil when the JSON
    /// isn't valid or its body isn't an object.
    static func models<S: ByteSource>(_ source: S) -> [Model]? {
        try? readWrapper(JSONReader(source))
    }

    /// Every model entry in `data` (see `models(_:)`).
    public static func models(_ data: Data) -> [Model]? {
        models(DataSource(data))
    }

    private static func readWrapper<S>(_ reader: JSONReader<S>) throws -> [Model]? {
        var found: [Model]?
        try reader.forEachMember { key in
            guard key == "body" else { return try reader.skipValue() }
            switch try reader.peekNonSpace() {
            case UInt8(ascii: "{"):
                found = try readBody(reader)
            case UInt8(ascii: "\""):
                _ = try reader.next()  // the opening quote
                let text = EscapedString(reader)
                let inner = JSONReader(text)
                do {
                    let body = try readBody(inner)
                    guard try inner.peekNonSpace() == nil else { throw Malformed() }
                    found = body
                } catch {
                    found = nil  // text that isn't a JSON object: no catalog
                    try text.drain()
                }
            default:
                found = nil
                try reader.skipValue()
            }
        }
        guard try reader.peekNonSpace() == nil else { throw Malformed() }
        return found
    }

    /// `{integration: {"models": {id: entry}}}`.
    private static func readBody<S>(_ reader: JSONReader<S>) throws -> [Model] {
        guard try reader.peekNonSpace() == UInt8(ascii: "{") else { throw Malformed() }
        var found = [Model]()
        try reader.forEachMember { vendor in
            guard try reader.peekNonSpace() == UInt8(ascii: "{") else { return try reader.skipValue() }
            var models: [Model]?
            try reader.forEachMember { key in
                guard key == "models" else { return try reader.skipValue() }
                guard try reader.peekNonSpace() == UInt8(ascii: "{") else {
                    models = nil
                    return try reader.skipValue()
                }
                var here = [Model]()
                try reader.forEachMember { id in
                    here.append(try readModel(reader, vendor: vendor, id: id))
                }
                models = here
            }
            found += models ?? []
        }
        return found
    }

    private static func readModel<S>(_ reader: JSONReader<S>, vendor: String, id: String) throws -> Model {
        var model = Model(vendor: vendor, id: id)
        guard try reader.peekNonSpace() == UInt8(ascii: "{") else {
            try reader.skipValue()
            return model
        }
        model.isObject = true
        try reader.forEachMember { key in
            switch key {
            case "name":
                model.name = try reader.textOrSkip()
            case "limit":
                (model.context, model.input, model.output) = (nil, nil, nil)
                try reader.forEachMemberOrSkip { key in
                    switch key {
                    case "context": model.context = try reader.numberOrSkip()
                    case "input": model.input = try reader.numberOrSkip()
                    case "output": model.output = try reader.numberOrSkip()
                    default: try reader.skipValue()
                    }
                }
            case "cost":
                (model.inputPrice, model.outputPrice, model.cacheReadPrice) = (nil, nil, nil)
                try reader.forEachMemberOrSkip { key in
                    guard key == "text" else { return try reader.skipValue() }
                    (model.inputPrice, model.outputPrice, model.cacheReadPrice) = (nil, nil, nil)
                    try reader.forEachMemberOrSkip { key in
                        switch key {
                        case "input":
                            (model.inputPrice, model.cacheReadPrice) = (nil, nil)
                            try reader.forEachMemberOrSkip { key in
                                switch key {
                                case "price": model.inputPrice = try reader.numberOrSkip()
                                case "cache":
                                    model.cacheReadPrice = nil
                                    try reader.forEachMemberOrSkip { key in
                                        guard key == "read" else { return try reader.skipValue() }
                                        model.cacheReadPrice = try reader.numberOrSkip()
                                    }
                                default: try reader.skipValue()
                                }
                            }
                        case "output":
                            model.outputPrice = nil
                            try reader.forEachMemberOrSkip { key in
                                guard key == "price" else { return try reader.skipValue() }
                                model.outputPrice = try reader.numberOrSkip()
                            }
                        default: try reader.skipValue()
                        }
                    }
                }
            default:
                try reader.skipValue()
            }
        }
        return model
    }
}

/// Bytes handed out one at a time.
protocol ByteSource: AnyObject {
    /// The next byte, or nil at the end.
    func next() throws -> UInt8?
}

/// Bytes already in memory (tests, small values).
final class DataSource: ByteSource {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    func next() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }
}

/// The contents of a JSON string whose opening quote was just read, with its
/// escapes undone, ending at the closing quote.
final class EscapedString<S: ByteSource>: ByteSource {
    private let outer: JSONReader<S>
    private var pending = [UInt8]()  // a \u escape's UTF-8, last byte first
    private var done = false

    init(_ outer: JSONReader<S>) {
        self.outer = outer
    }

    func next() throws -> UInt8? {
        if let byte = pending.popLast() { return byte }
        if done { return nil }
        guard let byte = try outer.next() else { throw OpencodeCatalog.Malformed() }
        switch byte {
        case UInt8(ascii: "\""):
            done = true
            return nil
        case UInt8(ascii: "\\"):
            return try escape()
        case 0..<0x20:
            throw OpencodeCatalog.Malformed()
        default:
            return byte
        }
    }

    /// Reads to the closing quote.
    func drain() throws {
        pending.removeAll()
        while try next() != nil {}
    }

    private func escape() throws -> UInt8 {
        guard let byte = try outer.next() else { throw OpencodeCatalog.Malformed() }
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return byte
        case UInt8(ascii: "b"): return 0x08
        case UInt8(ascii: "f"): return 0x0C
        case UInt8(ascii: "n"): return 0x0A
        case UInt8(ascii: "r"): return 0x0D
        case UInt8(ascii: "t"): return 0x09
        case UInt8(ascii: "u"):
            var value = try hex4()
            if (0xD800...0xDBFF).contains(value) {
                guard try outer.next() == UInt8(ascii: "\\"), try outer.next() == UInt8(ascii: "u") else {
                    throw OpencodeCatalog.Malformed()
                }
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw OpencodeCatalog.Malformed() }
                value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(value) else { throw OpencodeCatalog.Malformed() }
            pending = Array(String(Character(scalar)).utf8.reversed())
            return pending.removeLast()
        default:
            throw OpencodeCatalog.Malformed()
        }
    }

    private func hex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = try outer.next(), let digit = Self.hexValue(byte) else {
                throw OpencodeCatalog.Malformed()
            }
            value = value << 4 | digit
        }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }
}

/// A pull reader for JSON: hands out one member or value at a time and
/// skips what isn't wanted without building it.
final class JSONReader<S: ByteSource> {
    private let source: S
    private var lookahead: UInt8?
    private var hasLookahead = false
    /// How deep `skipValue` may go before giving up (JSONSerialization's limit is similar).
    private static var maxDepth: Int { 512 }

    init(_ source: S) {
        self.source = source
    }

    func next() throws -> UInt8? {
        if hasLookahead {
            hasLookahead = false
            return lookahead
        }
        return try source.next()
    }

    private func peek() throws -> UInt8? {
        if !hasLookahead {
            lookahead = try source.next()
            hasLookahead = true
        }
        return lookahead
    }

    /// The next byte that isn't white space, left unread; nil at the end.
    func peekNonSpace() throws -> UInt8? {
        while let byte = try peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            hasLookahead = false
        }
        return try peek()
    }

    private func expect(_ byte: UInt8) throws {
        guard try peekNonSpace() == byte else { throw OpencodeCatalog.Malformed() }
        hasLookahead = false
    }

    /// Calls `body` with each key of the object that comes next; `body` must
    /// read or skip the key's value.
    func forEachMember(_ body: (String) throws -> Void) throws {
        try expect(UInt8(ascii: "{"))
        if try peekNonSpace() == UInt8(ascii: "}") {
            hasLookahead = false
            return
        }
        while true {
            let key = try readText()
            try expect(UInt8(ascii: ":"))
            try body(key)
            switch try peekNonSpace() {
            case UInt8(ascii: ","): hasLookahead = false
            case UInt8(ascii: "}"): hasLookahead = false; return
            default: throw OpencodeCatalog.Malformed()
            }
        }
    }

    /// `forEachMember` when an object comes next, else skips the value.
    func forEachMemberOrSkip(_ body: (String) throws -> Void) throws {
        if try peekNonSpace() == UInt8(ascii: "{") {
            try forEachMember(body)
        } else {
            try skipValue()
        }
    }

    /// The string that comes next.
    func readText() throws -> String {
        try expect(UInt8(ascii: "\""))
        let text = EscapedString(self)
        var bytes = [UInt8]()
        while let byte = try text.next() {
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The string that comes next, or nil (the value skipped) if it isn't one.
    func textOrSkip() throws -> String? {
        if try peekNonSpace() == UInt8(ascii: "\"") {
            return try readText()
        }
        try skipValue()
        return nil
    }

    /// The number that comes next, or nil (the value skipped) if it isn't one.
    func numberOrSkip() throws -> Double? {
        guard let first = try peekNonSpace(),
              first == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first)
        else {
            try skipValue()
            return nil
        }
        return try readNumber()
    }

    private func readNumber() throws -> Double {
        var bytes = [UInt8]()
        while let byte = try peek(), Self.isNumberByte(byte) {
            bytes.append(byte)
            hasLookahead = false
            guard bytes.count <= 64 else { throw OpencodeCatalog.Malformed() }
        }
        guard let value = Double(String(decoding: bytes, as: UTF8.self)), value.isFinite else {
            throw OpencodeCatalog.Malformed()
        }
        return value
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
    }

    /// Reads past the value that comes next, checking it is valid JSON.
    func skipValue(depth: Int = 0) throws {
        guard depth < Self.maxDepth, let first = try peekNonSpace() else { throw OpencodeCatalog.Malformed() }
        switch first {
        case UInt8(ascii: "{"):
            try forEachMember { _ in try skipValue(depth: depth + 1) }
        case UInt8(ascii: "["):
            hasLookahead = false
            if try peekNonSpace() == UInt8(ascii: "]") {
                hasLookahead = false
                return
            }
            while true {
                try skipValue(depth: depth + 1)
                switch try peekNonSpace() {
                case UInt8(ascii: ","): hasLookahead = false
                case UInt8(ascii: "]"): hasLookahead = false; return
                default: throw OpencodeCatalog.Malformed()
                }
            }
        case UInt8(ascii: "\""):
            hasLookahead = false
            try EscapedString(self).drain()
        case UInt8(ascii: "t"): try literal("true")
        case UInt8(ascii: "f"): try literal("false")
        case UInt8(ascii: "n"): try literal("null")
        default:
            _ = try readNumber()
        }
    }

    private func literal(_ word: StaticString) throws {
        let bytes = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
        for expected in bytes {
            guard try next() == expected else { throw OpencodeCatalog.Malformed() }
        }
    }
}
