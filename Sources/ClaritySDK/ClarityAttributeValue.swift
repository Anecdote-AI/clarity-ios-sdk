import Foundation

/// A typed custom-attribute value, matching the platform's custom-attributes
/// release: values are stored as real JSON types (string / number / boolean),
/// `list`-type attributes hold an array of selected option ids, and `nil`
/// removes the attribute from the contact.
///
/// All literal forms work directly, so a mixed dictionary reads naturally:
///
///     Clarity.setUserAttributes([
///         "plan": "gold",          // string
///         "seat_count": 7,         // number
///         "vip": true,             // boolean
///         "region": ["emea"],      // list-type attribute (option ids)
///         "legacy_flag": nil,      // removes the attribute
///     ])
public enum ClarityAttributeValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    /// Selected option ids of a `list`-type attribute definition.
    case stringList([String])
    /// Removes the attribute: the platform drops the key entirely.
    case null

    /// JSON-serializable form for the bridge payload.
    var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .stringList(let value): return value
        case .null: return NSNull()
        }
    }

    /// Form for the handshake URL's JSON param, or nil when the value cannot
    /// ride the URL: the page's `customAttributes` parser accepts primitives
    /// only and rejects the WHOLE dictionary otherwise, and a removal has no
    /// meaning at session bootstrap. Non-URL values still reach the platform
    /// through the page-loaded bridge flush.
    var urlPrimitive: Any? {
        switch self {
        case .stringList, .null: return nil
        default: return jsonValue
        }
    }

    /// NaN/±inf are not JSON: `JSONSerialization` rejects the WHOLE containing
    /// dictionary, so one bad double would silently discard every attribute
    /// in the call (URL and bridge payloads both). Dropped up front instead.
    static func droppingNonFiniteValues(
        _ attributes: [String: ClarityAttributeValue]
    ) -> [String: ClarityAttributeValue] {
        attributes.filter { entry in
            if case .double(let value) = entry.value { return value.isFinite }
            return true
        }
    }
}

extension ClarityAttributeValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension ClarityAttributeValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension ClarityAttributeValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension ClarityAttributeValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension ClarityAttributeValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension ClarityAttributeValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: String...) { self = .stringList(elements) }
}
