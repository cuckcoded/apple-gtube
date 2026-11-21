import Foundation

/// Turns plain descriptions and comments into attributed text with clickable
/// links, timestamps (`seek:<seconds>`) and hashtags (`search:<query>`).
public enum Linkify {
    static let tokenRe = try! NSRegularExpression(
        pattern: #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]])|(\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b)|(#[\p{L}\p{N}_]+)"#)

    public static func timestampSeconds(_ s: String) -> Double? {
        var total = 0.0
        for part in s.split(separator: ":") {
            guard let n = Double(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    public static func searchLink(_ q: String) -> URL? {
        URL(string: "search:" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q))
    }

    /// Where a collapsed preview of `text` ends: after at most `maxLines` lines
    /// and `maxChars` characters.
    public static func excerpt(_ text: String, maxLines: Int, maxChars: Int) -> (String, truncated: Bool) {
        var t = text
        while t.last?.isWhitespace == true { t.removeLast() }
        var cut = t.endIndex
        if maxLines > 0 {
            var n = 0
            var i = t.startIndex
            while i < t.endIndex {
                if t[i] == "\n" {
                    n += 1
                    if n == maxLines {
                        cut = i
                        break
                    }
                }
                i = t.index(after: i)
            }
        }
        if let i = t.index(t.startIndex, offsetBy: maxChars, limitedBy: t.endIndex), i < cut { cut = i }
        return (String(t[..<cut]), cut < t.endIndex)
    }

    public static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        var last = 0
        for m in tokenRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let s = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound {
                let shown = s.count > 60 ? String(s.prefix(57)) + "…" : s
                var a = AttributedString(shown)
                a.link = URL(string: s)
                out += a
            } else if m.range(at: 2).location != NSNotFound {
                var a = AttributedString(s)
                if let t = timestampSeconds(s) { a.link = URL(string: "seek:\(t)") }
                out += a
            } else {
                var a = AttributedString(s)
                a.link = searchLink(s)
                out += a
            }
            last = m.range.location + m.range.length
        }
        out += AttributedString(ns.substring(from: last))
        return out
    }

    /// Like `attributed`, but first applies YouTube's own link ranges (UTF-16
    /// offsets), which cover links whose text isn't a URL.
    public static func attributed(_ text: String, links: [DescriptionLink]) -> AttributedString {
        let ns = text as NSString
        var out = AttributedString()
        var last = 0
        for l in links {
            let end = l.start + l.length
            if l.start < last || end > ns.length { continue }
            out += attributed(ns.substring(with: NSRange(location: last, length: l.start - last)))
            var a = AttributedString(ns.substring(with: NSRange(location: l.start, length: l.length)))
            a.link = URL(string: l.target) ?? searchLink(l.target)
            out += a
            last = end
        }
        out += attributed(ns.substring(from: last))
        return out
    }
}
