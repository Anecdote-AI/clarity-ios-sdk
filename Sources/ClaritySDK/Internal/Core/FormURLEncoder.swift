import Foundation

/// Percent-encoder that reproduces `java.net.URLEncoder.encode(value, "UTF-8")`
/// byte for byte, so widget URLs built here are identical to the Android
/// SDK's (fixtures captured from the Kotlin builder pass verbatim).
///
/// Rules: `A–Z a–z 0–9 . - * _` pass through, space becomes `+`, every other
/// byte of the UTF-8 encoding becomes `%XX` (uppercase hex).
enum FormURLEncoder {
    static func encode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)

        for byte in Array(value.utf8) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"),
                 UInt8(ascii: "*"), UInt8(ascii: "_"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                result.append("+")
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }
}
