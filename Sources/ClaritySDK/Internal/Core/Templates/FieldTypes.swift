import Foundation

/// Form field types: the web's `autocomplete` tokens are the wire values on
/// every platform (spec Appendix A). Pure, so `swift test` pins the mapping.
enum FieldTypes {

    /// The fields the agent may see and fill: a name, contact details, an address.
    static let fillable = [
        "name", "given-name", "family-name", "organization", "email", "tel",
        "street-address", "address-line1", "address-line2", "address-level1",
        "address-level2", "postal-code", "country-name",
    ]

    /// Fields only the customer types: a password, a one-time code, a card.
    /// The agent may point at them and never reads or writes them.
    static let customerOnly = [
        "current-password", "new-password", "one-time-code", "cc-name", "cc-number",
        "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc",
    ]

    /// What `focus_form_field` takes to stop asking about a field.
    static let none = "none"

    static func isFillable(_ type: String?) -> Bool {
        type.map(fillable.contains) ?? false
    }

    static func isCustomerOnly(_ type: String?) -> Bool {
        type.map(customerOnly.contains) ?? false
    }

    /// `UITextContentType` raw values (what `textContentType.rawValue` holds
    /// at run time) → web tokens.
    static let contentTypes: [String: String] = [
        "name": "name",
        "given-name": "given-name",
        "family-name": "family-name",
        "organization": "organization",
        "email": "email",
        "tel": "tel",
        "street-address": "street-address",
        "address-line1": "address-line1",
        "address-line2": "address-line2",
        "address-level1": "address-level1",
        "address-level2": "address-level2",
        "postal-code": "postal-code",
        "country-name": "country-name",
        "password": "current-password",
        "new-password": "new-password",
        "one-time-code": "one-time-code",
        "cc-name": "cc-name",
        "cc-number": "cc-number",
        "cc-exp": "cc-exp",
        "cc-exp-month": "cc-exp-month",
        "cc-exp-year": "cc-exp-year",
        "cc-csc": "cc-csc",
    ]

    /// Swift spellings of the same types, for a content type whose raw value
    /// is the constant's name on some OS versions.
    private static let swiftNames: [String: String] = [
        "name": "name", "givenname": "given-name", "familyname": "family-name",
        "organizationname": "organization", "emailaddress": "email",
        "telephonenumber": "tel", "fullstreetaddress": "street-address",
        "streetaddressline1": "address-line1", "streetaddressline2": "address-line2",
        "addressstate": "address-level1", "addresscity": "address-level2",
        "postalcode": "postal-code", "countryname": "country-name",
        "password": "current-password", "newpassword": "new-password",
        "onetimecode": "one-time-code", "creditcardname": "cc-name",
        "creditcardnumber": "cc-number", "creditcardexpiration": "cc-exp",
        "creditcardexpirationmonth": "cc-exp-month", "creditcardexpirationyear": "cc-exp-year",
        "creditcardsecuritycode": "cc-csc",
    ]

    /// `UIKeyboardType` raw values used as a fallback: `.emailAddress` (7) →
    /// email, `.phonePad` (5) → tel.
    static let keyboardEmail = 7
    static let keyboardPhonePad = 5
    static let keyboardNumberPad = 4
    static let keyboardDecimalPad = 8

    /// The field's type: its content type when it maps, then the keyboard,
    /// and any secure field is a password whatever its hints.
    static func type(contentType: String?, keyboardType: Int, isSecure: Bool) -> String? {
        if isSecure {
            let mapped = contentType.flatMap(mapContentType)
            return isCustomerOnly(mapped) ? mapped : "current-password"
        }
        if let mapped = contentType.flatMap(mapContentType) { return mapped }
        switch keyboardType {
        case keyboardEmail: return "email"
        case keyboardPhonePad: return "tel"
        default: return nil
        }
    }

    /// `text`, `email`, `tel` or `number`, from the keyboard, for an error on a
    /// field with no recognised type (the web uses the input type the same way).
    static func inputKind(keyboardType: Int) -> String {
        switch keyboardType {
        case keyboardEmail: return "email"
        case keyboardPhonePad: return "tel"
        case keyboardNumberPad, keyboardDecimalPad: return "number"
        default: return "text"
        }
    }

    static func mapContentType(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let token = contentTypes[trimmed] { return token }
        let folded = trimmed.lowercased()
            .replacingOccurrences(of: "uitextcontenttype", with: "")
            .filter { $0.isLetter || $0.isNumber }
        return swiftNames[folded]
    }
}
