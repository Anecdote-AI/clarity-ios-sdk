import Foundation

/// The backend's rules for a declaration (`in_app_tool_validation.py` in
/// anecdote-back), checked when the host registers the tool: a tool the
/// backend would refuse is refused here, with the reason in the device log,
/// instead of silently never reaching the agent. The backend stays the
/// authority and checks everything again.
enum InAppToolValidation {

    static let namePattern = "^[a-z][a-z0-9_]{0,63}$"
    static let maxDescriptionLength = 1000
    static let minTimeoutSeconds = 1
    static let maxTimeoutSeconds = 90
    static let maxSchemaDepth = 4
    static let maxSchemaProperties = 32
    static let maxEnumValues = 50
    static let maxEnumValueLength = 100
    static let maxSchemaDescriptionLength = 300
    static let maxDeclarationBytes = 8 * 1024
    static let reservedArgument = "confirmation_text"
    static let maxRevealMessageLength = 80
    static let maxRevealDelaySeconds: TimeInterval = 3

    private static let allowedKeywords: Set<String> = ["type", "description", "properties", "required", "items", "enum"]
    private static let scalarTypes: Set<String> = ["string", "number", "integer", "boolean"]

    /// Why the tool cannot be declared, or nil when it can.
    static let securityCheckKindProblem =
        "requiresSecurityCheck needs kind .action: only an action has a card to confirm on Allow"

    static func problem(with tool: ClarityTool) -> String? {
        if !isName(tool.name) {
            return "the name must be lowercase letters, digits and _, starting with a letter (at most 64)"
        }
        let trimmed = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Code points, as the backend counts them: Arabic marks are separate
        // code points inside one visible character.
        if trimmed.isEmpty || tool.description.unicodeScalars.count > maxDescriptionLength {
            return "the description must be 1…\(maxDescriptionLength) characters"
        }
        if let timeout = tool.timeoutSeconds, !(minTimeoutSeconds...maxTimeoutSeconds).contains(timeout) {
            return "timeoutSeconds must be \(minTimeoutSeconds)…\(maxTimeoutSeconds)"
        }
        if let reveal = tool.reveal, let problem = revealProblem(reveal) {
            return problem
        }
        if tool.requiresSecurityCheck && tool.kind != .action {
            return securityCheckKindProblem
        }
        if let problem = schemaProblem(tool.parameters, label: "parameters") {
            return problem
        }
        if let properties = tool.parameters["properties"] as? [String: Any], properties[reservedArgument] != nil {
            return "\(reservedArgument) is reserved: the platform adds it to actions for the consent card"
        }
        if let result = tool.resultSchema, let problem = schemaProblem(result, label: "resultSchema") {
            return problem
        }
        let declared: [Any] = [tool.description, tool.parameters, tool.resultSchema ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(declared),
              let data = try? JSONSerialization.data(withJSONObject: declared)
        else { return "the schemas must be JSON" }
        if data.count > maxDeclarationBytes {
            return "the declaration must be at most \(maxDeclarationBytes) bytes (description and schemas together)"
        }
        return nil
    }

    /// The loader text and the two pauses; checked here only, the backend
    /// never sees them.
    static func revealProblem(_ reveal: ClarityToolReveal) -> String? {
        if let problem = revealMessageProblem(reveal.message) {
            return "reveal.\(problem)"
        }
        let pauses = 0...maxRevealDelaySeconds
        if !pauses.contains(reveal.delayBefore) || !(reveal.holdAfter.map(pauses.contains) ?? true) {
            return "reveal.delayBefore and reveal.holdAfter must be 0…\(Int(maxRevealDelaySeconds)) seconds"
        }
        return nil
    }

    /// The loader's text, for a tool's reveal and for `Clarity.stepAside`.
    static func revealMessageProblem(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || message.count > maxRevealMessageLength {
            return "message must be 1…\(maxRevealMessageLength) characters"
        }
        return nil
    }

    static func isName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    private static func schemaProblem(_ schema: [String: Any], label: String) -> String? {
        guard schema["type"] as? String == "object" else {
            return "\(label) must be a JSON Schema of type object"
        }
        return node(schema, path: label, depth: 1)
    }

    private static func node(_ value: Any, path: String, depth: Int) -> String? {
        if depth > maxSchemaDepth { return "\(path) is nested deeper than \(maxSchemaDepth)" }
        guard let node = value as? [String: Any] else { return "\(path) must be an object" }
        let unknown = Set(node.keys).subtracting(allowedKeywords).sorted()
        if !unknown.isEmpty { return "\(path) uses unsupported keywords: \(unknown.joined(separator: ", "))" }
        if let description = node["description"] {
            guard let text = description as? String else { return "\(path).description must be a string" }
            if text.unicodeScalars.count > maxSchemaDescriptionLength {
                return "\(path).description must be at most \(maxSchemaDescriptionLength) characters"
            }
        }
        let type = node["type"] as? String
        if type == "object" {
            let properties = node["properties"] ?? [String: Any]()
            guard let props = properties as? [String: Any] else { return "\(path).properties must be an object" }
            if props.count > maxSchemaProperties { return "\(path) declares more than \(maxSchemaProperties) properties" }
            for (key, child) in props.sorted(by: { $0.key < $1.key }) {
                if !isName(key) {
                    return "\(path).properties has an invalid name \"\(key)\" (lowercase letters, digits and _)"
                }
                if let problem = self.node(child, path: "\(path).\(key)", depth: depth + 1) { return problem }
            }
            let required = node["required"] ?? [String]()
            guard let names = required as? [String] else { return "\(path).required must be a list of names" }
            let missing = Set(names).subtracting(props.keys).sorted()
            if !missing.isEmpty { return "\(path).required names undeclared properties: \(missing.joined(separator: ", "))" }
            if node["items"] != nil || node["enum"] != nil { return "\(path): an object takes no items or enum" }
            return nil
        }
        if node["properties"] != nil || node["required"] != nil { return "\(path): only an object takes properties" }
        if type == "array" {
            guard let items = node["items"] else { return "\(path): an array needs items" }
            if node["enum"] != nil { return "\(path): an array takes no enum" }
            return self.node(items, path: "\(path)[]", depth: depth + 1)
        }
        guard let scalar = type, scalarTypes.contains(scalar) else {
            return "\(path).type must be one of object, array, string, number, integer, boolean"
        }
        if node["items"] != nil { return "\(path): only an array takes items" }
        if let values = node["enum"] {
            guard let list = values as? [Any], !list.isEmpty, list.count <= maxEnumValues else {
                return "\(path).enum must list 1…\(maxEnumValues) values"
            }
            if list.contains(where: { "\($0)".unicodeScalars.count > maxEnumValueLength }) {
                return "\(path).enum values must be at most \(maxEnumValueLength) characters"
            }
        }
        return nil
    }
}
