import Foundation

/// Agent- and server-supplied text is untrusted, and some of it (a command the user is about to approve, a thread title) is shown
/// where the user decides something. Invisible and direction-changing characters can make text read differently from what it is,
/// so they are shown as visible escapes (`⟦U+202E⟧`) instead of being interpreted.
public enum DisplayText {
    /// Zero-width, direction-control, tag and other format characters, variation selectors, fillers that render as blanks, and
    /// control characters other than newline (when allowed).
    static func isHidden(_ u: Unicode.Scalar, allowNewlines: Bool) -> Bool {
        switch u.value {
        case 0x0A: return !allowNewlines
        case 0x09: return false                      // a tab is shown as a gap, not hidden
        case 0x00...0x1F, 0x7F...0x9F: return true   // C0, DEL and C1 controls
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180E, 0x2800, 0x3164, 0xFFA0: return true   // soft hyphen, fillers, Mongolian selectors, braille blank
        case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0xFFF9...0xFFFB: return true
        case 0xE0000...0xE007F, 0xE0100...0xE01EF: return true   // tag characters, variation selectors supplement
        default:
            switch u.properties.generalCategory {
            case .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    private static func isMark(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return true
        default: return false
        }
    }

    public static func clean(_ text: String, allowNewlines: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        var changed = false
        var marks = 0                                // consecutive combining marks: more than two stack into an unreadable smear
        for u in text.unicodeScalars {
            if isHidden(u, allowNewlines: allowNewlines) || (isMark(u) && marks >= 2) {
                changed = true
                out.append(contentsOf: String(format: "⟦U+%04X⟧", u.value).unicodeScalars)
                if !isMark(u) { marks = 0 }          // after an escaped mark every further mark is escaped too, until a real character
            } else {
                marks = isMark(u) ? marks + 1 : 0
                out.append(u)
            }
        }
        return changed ? String(out) : text
    }

    /// Does this command have to be expanded before it can be approved? Conservative: anything that could be clipped at the
    /// panel's width in three lines (about 44 characters a line in the monospaced font) or that hides characters.
    public static func commandNeedsExpansion(_ text: String) -> Bool {
        if text.unicodeScalars.count > 80 { return true }       // scalars, not characters: marks cannot hide extra length
        if text.split(separator: "\n", omittingEmptySubsequences: false).count > 2 { return true }
        return clean(text, allowNewlines: true) != text
    }
}

extension CharacterSet {
    /// A-Z, a-z, 0-9 only. `CharacterSet.alphanumerics` also holds every Unicode letter and digit, which is wrong for percent-encoding.
    static let asciiAlphanumerics = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
}
