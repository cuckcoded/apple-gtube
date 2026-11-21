import Foundation

/// A parsed JSON value.
///
/// YouTube's responses shift constantly, so the parsers walk the tree looking
/// for renderers they know rather than following fixed paths. Objects are
/// walked in sorted key order, so every walk is deterministic.
public indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: any)
    }

    public init(string: String) throws {
        try self.init(data: Data(string.utf8))
    }

    public init(any: Any) {
        switch any {
        case let d as [String: Any]:
            var out = [String: JSON](minimumCapacity: d.count)
            for (k, v) in d { out[k] = JSON(any: v) }
            self = .object(out)
        case let a as [Any]:
            self = .array(a.map(JSON.init(any:)))
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }

    /// Back to Foundation objects (for JSONSerialization).
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    // MARK: Access

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    /// A JSON pointer ("/contents/0/videoRenderer").
    public func pointer(_ path: String) -> JSON? {
        if path.isEmpty { return self }
        var cur: JSON = self
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch cur {
            case .object(let o):
                guard let next = o[String(part)] else { return nil }
                cur = next
            case .array(let a):
                guard let i = Int(part), i >= 0, i < a.count else { return nil }
                cur = a[i]
            default:
                return nil
            }
        }
        return cur
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// A non-negative whole number (like serde_json's `as_u64`).
    public var uint: Int? {
        if case .number(let n) = self, n >= 0, n.rounded() == n, n < 9.0e18 { return Int(n) }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The object's entries in sorted key order.
    public var sortedEntries: [(key: String, value: JSON)] {
        guard case .object(let o) = self else { return [] }
        return o.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }

    /// The first (by sorted key) entry of an object: renderers are objects
    /// with a single key naming their type.
    public var firstEntry: (key: String, value: JSON)? {
        guard case .object(let o) = self, let k = o.keys.min() else { return nil }
        return (key: k, value: o[k]!)
    }

    // MARK: Searching

    /// The first value under `key`, anywhere in the tree (depth first).
    public func findFirst(_ key: String) -> JSON? {
        switch self {
        case .object(let o):
            if let x = o[key] { return x }
            for k in o.keys.sorted() {
                if let found = o[k]!.findFirst(key) { return found }
            }
            return nil
        case .array(let a):
            for x in a {
                if let found = x.findFirst(key) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// Every value under `key`, anywhere in the tree (not looking inside them).
    public func findAll(_ key: String) -> [JSON] {
        var out: [JSON] = []
        findAll(key, into: &out)
        return out
    }

    public func findAll(_ key: String, into out: inout [JSON]) {
        switch self {
        case .object(let o):
            for k in o.keys.sorted() {
                let x = o[k]!
                if k == key {
                    out.append(x)
                } else {
                    x.findAll(key, into: &out)
                }
            }
        case .array(let a):
            for x in a { x.findAll(key, into: &out) }
        default:
            break
        }
    }
}

extension JSON {
    /// A number given as a number or a numeric string.
    public var numeric: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}

public enum JSONBody {
    /// Serializes a Foundation object (dictionaries, arrays, strings, numbers).
    public static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }
}
