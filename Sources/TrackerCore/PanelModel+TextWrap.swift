import Foundation

/// Python's `textwrap.wrap(text, width)` with its default options, so notes
/// and warnings break into the same lines as before: words are split at
/// whitespace and after hyphens ("sk-admin-…"), words longer than a line
/// are cut, and spaces at line ends are dropped. Lengths count Unicode
/// scalars, as Python's `len` counts code points.
extension PanelModel {
    static func wrap(_ text: String, width: Int) -> [String] {
        var chunks = splitChunks(mungeWhitespace(text))
        chunks.reverse()  // so the next chunk is popped off the end
        var lines = [String]()
        while !chunks.isEmpty {
            var line = [[Unicode.Scalar]]()
            var length = 0
            // A space at the start of any line but the first is dropped.
            if isBlank(chunks[chunks.count - 1]) && !lines.isEmpty {
                chunks.removeLast()
            }
            while let chunk = chunks.last, length + chunk.count <= width {
                line.append(chunks.removeLast())
                length += chunk.count
            }
            // The next chunk is too long for any line: cut it.
            if let chunk = chunks.last, chunk.count > width {
                handleLongWord(&chunks, &line, length: length, width: width)
                length = line.reduce(0) { $0 + $1.count }
            }
            if let last = line.last, isBlank(last) {
                length -= last.count
                line.removeLast()
            }
            if !line.isEmpty {
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: line.joined())
                lines.append(String(scalars))
            }
        }
        return lines
    }

    /// textwrap's `_handle_long_word`: as much of the chunk as fits, cut
    /// after its last hyphen when there's one in reach.
    private static func handleLongWord(_ chunks: inout [[Unicode.Scalar]], _ line: inout [[Unicode.Scalar]],
                                       length: Int, width: Int) {
        let spaceLeft = width < 1 ? 1 : width - length
        let chunk = chunks[chunks.count - 1]
        var end = spaceLeft
        if chunk.count > spaceLeft,
           let hyphen = chunk[0..<spaceLeft].lastIndex(of: "-"), hyphen > 0,
           chunk[0..<hyphen].contains(where: { $0 != "-" }) {
            end = hyphen + 1
        }
        line.append(Array(chunk[0..<end]))
        chunks[chunks.count - 1] = Array(chunk[end...])
    }

    /// Python's `str.strip() == ""`.
    private static func isBlank(_ chunk: [Unicode.Scalar]) -> Bool {
        chunk.allSatisfy { $0.properties.isWhitespace }
    }

    private static let whitespace: Set<Unicode.Scalar> = ["\t", "\n", "\u{0B}", "\u{0C}", "\r", " "]

    /// Tabs expanded (every 8 columns) and other whitespace turned into spaces.
    private static func mungeWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var column = 0
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                let spaces = 8 - column % 8
                out.append(contentsOf: Array(repeating: " ", count: spaces))
                column += spaces
            } else if scalar == "\n" || scalar == "\r" {
                out.append(" ")
                column = 0
            } else {
                out.append(whitespace.contains(scalar) ? " " : scalar)
                column += 1
            }
        }
        return String(out)
    }

    /// textwrap's `wordsep_re`: runs of whitespace, em-dashes ("--") between
    /// words, and words, each hyphenated part on its own.
    private static let wordSeparator: NSRegularExpression = {
        let ws = #"[\t\n\x{0B}\x{0C}\r ]"#
        let nws = #"[^\t\n\x{0B}\x{0C}\r ]"#
        let wordPunct = #"[\w!"'&.,?]"#
        let letter = #"[^\d\W]"#
        let pattern = "(" + ws + "+"
            + "|(?<=" + wordPunct + ")-{2,}(?=\\w)"
            + "|" + nws + "+?(?:"
            + "-(?:(?<=" + letter + "{2}-)|(?<=" + letter + "-" + letter + "-))"
            + "(?=" + letter + "-?" + letter + ")"
            + "|(?=" + ws + "|\\z)"
            + "|(?<=" + wordPunct + ")(?=-{2,}\\w)"
            + "))"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Python's `[c for c in wordsep_re.split(text) if c]`.
    private static func splitChunks(_ text: String) -> [[Unicode.Scalar]] {
        let ns = text as NSString
        var pieces = [String]()
        var last = 0
        for match in wordSeparator.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > last {
                pieces.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            }
            pieces.append(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        if last < ns.length {
            pieces.append(ns.substring(from: last))
        }
        return pieces.filter { !$0.isEmpty }.map { Array($0.unicodeScalars) }
    }

    /// Lines of `text` no wider than `width` points, by `measure`: breaks at
    /// spaces, and by character inside a word wider than a line.
    public static func wrapMeasured(_ text: String, width: CGFloat, size: CGFloat,
                                    measure: TextMeasure) -> [String] {
        func fits(_ s: String) -> Bool { measure(s, size, .regular) <= width }
        var lines = [String]()
        var line = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let joined = line.isEmpty ? word : line + " " + word
            if fits(joined) {
                line = joined
                continue
            }
            if !line.isEmpty {
                lines.append(line)
                line = ""
            }
            // A word on a line of its own; cut it by character if it's too wide.
            var rest = Substring(word)
            while !fits(String(rest)) {
                var cut = rest.startIndex
                for index in rest.indices {
                    let next = rest.index(after: index)
                    if !fits(String(rest[..<next])) { break }
                    cut = next
                }
                if cut == rest.startIndex { cut = rest.index(after: cut) }  // at least one character
                lines.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
            line = String(rest)
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
