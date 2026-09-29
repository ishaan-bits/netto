import Foundation

/// Pure, deterministic normalization for duplicate detection. Every function is total over its
/// input (`nil` means "no usable value"), locale-independent, and identical across runs.
///
/// ## Policy
///
/// **Phones** — formatting-insensitive, *not* country-code-assuming:
/// - Separators (spaces, dashes, dots, parentheses, NBSP) are stripped; Unicode digits in the
///   ASCII+Indic ranges are folded to ASCII so `９８７６５` and `98765` agree.
/// - A leading `+` is kept as a marker of an international form; `+91 98765 43210` and
///   `+919876543210` therefore normalize identically.
/// - **Strict key** (`phoneMatchKeys` "s:" entry): digits only, ignoring a leading `+`. A bare
///   `919876543210` therefore matches `+919876543210` — same digit string, pure formatting.
/// - **National-tolerance key** ("n:" entry), bounded and explicit: a bare **exactly 10-digit**
///   number also yields its digits as a national key, and a `+`-number with **more than 10**
///   digits yields its **last 10 digits** as a national key. This is what lets
///   `(98765) 43210` match `+91 98765 43210` without claiming that every numeric string is
///   globally equivalent — only that a 10-digit national form matches the same national form
///   carried inside a longer international one. Trunk-zero forms (`09876543210`) and other
///   country-code arrangements are deliberately **not** rewritten (that would require
///   country-specific assumptions); they simply do not match.
/// - Fewer than 4 digits is treated as meaningless (extension/voicemail fragments) → `nil`.
///
/// **Emails** — `nil` unless there is exactly one `@` with non-empty sides; then trimmed and
/// lowercased. Nothing else: plus-tag stripping (`a+b@` → `a@`) changes delivery identity for
/// many providers, so it is never done.
///
/// **Names / organization** — trimmed, internal whitespace collapsed, lowercased. Diacritics
/// are **kept** (conservative: `José` and `Jose` are different keys — fuzzy matching across
/// accents could merge unrelated people, and every group here is only ever "likely").
/// An empty result is `nil` (never indexed as `""`).
enum ContactNormalization {
    /// The separator/formatting characters phone normalization ignores.
    private static let phoneSeparators = CharacterSet(charactersIn: " \t\u{00A0}-().")

    /// Formatting-insensitive phone key (see the policy comment above). `nil` when the input
    /// has fewer than 4 digits.
    static func phone(_ raw: String) -> String? {
        phoneMatchKeys(raw).first { $0.hasPrefix("s:") }
    }

    /// Every match key for one raw phone: always the strict key, plus the national-tolerance
    /// key when the bounded rule applies. Returned as a `Set` so callers never double-index.
    static func phoneMatchKeys(_ raw: String) -> Set<String> {
        var digits = ""
        var hasPlus = false
        var sawDigit = false
        var sawPlus = false
        for char in raw {
            if char == "+" {
                // One `+`, only in the prefix before any digit ("+1 (555)…"). A `+` after
                // digits or a second `+` is not plain phone formatting → reject.
                if sawDigit || sawPlus { return [] }
                sawPlus = true
                hasPlus = true
            } else if let ascii = asciiDigit(of: char) {
                sawDigit = true
                digits.append(ascii)
            } else if char.unicodeScalars.allSatisfy({ phoneSeparators.contains($0) }) {
                continue // recognized formatting separator
            } else {
                // A genuinely different character (letter, symbol) — not a formatting variant.
                return []
            }
        }
        guard digits.count >= 4 else { return [] }

        var keys: Set<String> = ["s:\(digits)"]
        if hasPlus, digits.count > 10 {
            keys.insert("n:\(digits.suffix(10))")
        } else if !hasPlus, digits.count == 10 {
            keys.insert("n:\(digits)")
        }
        return keys
    }

    /// Trimmed, lowercased email — or `nil` when the input is not exactly one address shape.
    static func email(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return trimmed
    }

    /// Combined full name ("given family"), trimmed/collapsed/lowercased — `nil` when empty.
    static func name(_ given: String, _ family: String) -> String? {
        nonEmptyKey([given, family].joined(separator: " "))
    }

    /// Organization key with the same rules as names.
    static func organization(_ raw: String) -> String? {
        nonEmptyKey(raw)
    }

    // MARK: Shared helpers

    private static func nonEmptyKey(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        return collapsed.isEmpty ? nil : collapsed
    }

    /// ASCII digit for `char`, folding the ASCII and Indic (Devanagari) digit blocks so
    /// keyboard-locale digit variants compare equal. `nil` for everything else.
    private static func asciiDigit(of char: Character) -> String? {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else {
            return nil
        }
        let value = scalar.value
        switch value {
        case 0x30...0x39: // ASCII 0-9
            return String(Character(UnicodeScalar(value - 0x30 + 0x30)!))
        case 0x966...0x96F: // Devanagari 0-9
            return String(Character(UnicodeScalar(value - 0x966 + 0x30)!))
        default:
            return nil
        }
    }
}
