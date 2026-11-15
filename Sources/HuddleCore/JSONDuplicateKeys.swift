import Foundation

/// Two parsers can read `{"command":"ls","command":"rm -rf ~"}` differently (Foundation keeps the first key, JavaScript and
/// Python the last). Text the user is asked to approve must not be ambiguous, so any object with a repeated key is refused.
public enum JSONDuplicateKeys {
    /// True when some object in `text` has the same key twice. Text that is not well-formed JSON returns true (refused too).
    public static func hasDuplicate(_ text: String) -> Bool {
        var p = Scanner(Array(text.unicodeScalars))
        return p.scanValue() == nil || p.sawDuplicate
    }

    private struct Scanner {
        let s: [Unicode.Scalar]
        var i = 0
        var sawDuplicate = false
        var depth = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skipWS() { while i < s.count, [" ", "\t", "\n", "\r"].contains(s[i]) { i += 1 } }

        /// nil = malformed (or too deep). Trailing garbage after the value is malformed too.
        mutating func scanValue() -> Void? {
            guard value() != nil else { return nil }
            skipWS()
            return i == s.count ? () : nil
        }

        mutating func value() -> Void? {
            skipWS()
            guard i < s.count, depth < 64 else { return nil }
            switch s[i] {
            case "{":
                depth += 1; defer { depth -= 1 }
                i += 1; skipWS()
                var keys = Set<String>()
                if i < s.count, s[i] == "}" { i += 1; return () }
                while true {
                    skipWS()
                    guard let key = string() else { return nil }
                    if !keys.insert(key).inserted { sawDuplicate = true }
                    skipWS()
                    guard i < s.count, s[i] == ":" else { return nil }
                    i += 1
                    guard value() != nil else { return nil }
                    skipWS()
                    guard i < s.count else { return nil }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "}" { i += 1; return () }
                    return nil
                }
            case "[":
                depth += 1; defer { depth -= 1 }
                i += 1; skipWS()
                if i < s.count, s[i] == "]" { i += 1; return () }
                while true {
                    guard value() != nil else { return nil }
                    skipWS()
                    guard i < s.count else { return nil }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "]" { i += 1; return () }
                    return nil
                }
            case "\"": return string() == nil ? nil : ()
            default:
                // number, true, false, null: consume the bare token
                let start = i
                while i < s.count, !([",", "]", "}", " ", "\t", "\n", "\r"].contains(s[i])) { i += 1 }
                return i > start ? () : nil
            }
        }

        mutating func string() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return String(out) }
                if c == "\\" {
                    guard i < s.count else { return nil }
                    let e = s[i]; i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{8}")
                    case "f": out.append("\u{C}")
                    case "u":
                        guard i + 4 <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else { return nil }
                        i += 4
                        if let u = Unicode.Scalar(v) { out.append(u) } else { out.append("\u{FFFD}") }   // a lone surrogate: any placeholder is fine for key comparison
                    default: out.append(e)
                    }
                } else { out.append(c) }
            }
            return nil
        }
    }
}
