// Model/Search.swift
// Ranks apps against what was typed: name prefix, then word prefix, then initials
// ("vsc" → Visual Studio Code), then substring, then letters in order. Case and accents
// are ignored, so "tieng" finds "Tiếng Việt".

import Foundation

enum Search {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Higher is better; nil means no match.
    static func score(name: String, query: String, extra: [String] = []) -> Int? {
        let q = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let n = normalize(name)
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 900 - min(n.count, 100) }
        let words = n.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - min(n.count, 100) }
        let initials = String(words.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 700 }
        if n.contains(q) { return 600 - min(n.count, 100) }
        for e in extra where normalize(e).contains(q) { return 400 }
        // Letters in order ("xcd" → Xcode) only for longer queries and from the first letter,
        // so two typed letters don't match half the Mac.
        if q.count >= 3, q.first == n.first, isSubsequence(q.replacingOccurrences(of: " ", with: ""), of: n) { return 200 - min(n.count, 100) }
        return nil
    }

    static func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        outer: for c in q {
            while let x = it.next() { if x == c { continue outer } }
            return false
        }
        return true
    }
}
