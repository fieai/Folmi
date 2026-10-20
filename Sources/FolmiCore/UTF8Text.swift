import Foundation

/// Strict UTF-8 decoding for file contents that keeps leading byte-order marks.
///
/// `String(data:encoding: .utf8)` drops a leading BOM on newer macOS (seen on 27.0). Text that is written back
/// (line staging, discarding a hunk) would lose the mark, and UTF-16 offsets into the original text shift by one.
public enum UTF8Text {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The text with every leading BOM kept as U+FEFF; nil when the bytes are not valid UTF-8.
    public static func decode(_ data: Data) -> String? {
        var rest = data[...]
        var marks = 0
        while rest.starts(with: bom) { rest = rest.dropFirst(3); marks += 1 }
        guard let text = String(data: rest, encoding: .utf8) else { return nil }
        return marks == 0 ? text : String(repeating: "\u{FEFF}", count: marks) + text
    }
}
