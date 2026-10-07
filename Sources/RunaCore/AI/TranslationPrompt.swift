import Foundation

/// The prompt and output schema every provider uses.
public enum TranslationPrompt {
    public static func system(for request: TranslationRequest) -> String {
        let target = request.targetLocale.displayName()
        let source = request.sourceLocale.displayName()
        var text = """
        You translate user interface strings for the app "\(request.projectName)" from \(source) (\(request.sourceLocale)) \
        to \(target) (\(request.targetLocale)). Write what a native \(target) product copywriter would ship: natural, concise, \
        and consistent with the platform conventions of iOS, Android and the web.

        Each string has a key, often a description, sometimes where it appears in the design and nearby texts on the same \
        screen. Use that context to pick the right meaning: "Book" on a travel screen is a verb, in a library app it is a noun.

        Rules that keep the app working:
        - Copy placeholders exactly as written, braces included: {name}, {count:int}, {price:double.2}. Never translate or \
        rename what is inside the braces. You may move them within the sentence.
        - Keep markup such as <b>…</b> and line breaks.
        - For plural strings, write every requested form. The {count:int} placeholder can be left out of a form only where \
        \(target) grammar drops the number, such as a "one" form written as a word.
        - When a design width is given, keep the translation about as long as the source so it fits.
        - Do not wrap strings in quotes or add explanations inside them.

        Put a short note on a string only when something is genuinely ambiguous or you made a judgement call a reviewer \
        should check; otherwise leave the note empty.
        """
        if !request.styleGuide.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\nStyle guide for \(target):\n\(request.styleGuide)"
        }
        let glossary = request.glossary.filter { !$0.term.isEmpty }
        if !glossary.isEmpty {
            text += "\n\nGlossary (always use these):"
            for term in glossary {
                let translation = term.translations[request.targetLocale] ?? ""
                let rendering = translation.isEmpty ? "keep \"\(term.term)\" untranslated" : "\"\(term.term)\" → \"\(translation)\""
                text += "\n- \(rendering)\(term.note.isEmpty ? "" : " (\(term.note))")"
            }
        }
        return text
    }

    /// Short ids keep the prompt compact and are easy for the model to echo back.
    public static func shortID(_ index: Int) -> String { "s\(index + 1)" }

    public static func user(for request: TranslationRequest) -> String {
        var lines = ["Translate these \(request.items.count) strings into \(request.targetLocale.displayName()). Answer with JSON matching the schema."]
        if !request.images.isEmpty {
            lines.append("")
            lines.append("Screenshots of the designs are attached in order: " +
                         request.images.enumerated().map { "image \($0.offset + 1) shows \($0.element.caption)" }.joined(separator: "; ") + ".")
        }
        for (index, item) in request.items.enumerated() {
            lines.append("")
            lines.append("[\(shortID(index))] key: \(item.key)")
            if !item.description.isEmpty { lines.append("description: \(item.description)") }
            if item.source.count == 1, let text = item.source[.other] {
                lines.append("source: \(quoted(text))")
            } else {
                for category in PluralCategory.allCases {
                    if let text = item.source[category] { lines.append("source \(category.rawValue): \(quoted(text))") }
                }
            }
            if item.requiredForms != [.other] {
                lines.append("write forms: \(item.requiredForms.map(\.rawValue).joined(separator: ", "))")
            }
            if !item.placeholders.isEmpty {
                lines.append("placeholders: \(item.placeholders.map(\.canonical).joined(separator: " "))")
            }
            if let figma = item.figma {
                var where_ = [figma.pageName, figma.frameName].compactMap { $0 }.joined(separator: " / ")
                if let path = figma.nodePath, !path.isEmpty { where_ += where_.isEmpty ? path : " (\(path))" }
                if !where_.isEmpty { lines.append("design: \(where_)") }
                if let width = figma.width {
                    lines.append("design width: \(Int(width))pt\(figma.fontSize.map { " at \(Int($0))pt type" } ?? "")")
                }
                let siblings = figma.siblingTexts.prefix(6).map(quoted)
                if !siblings.isEmpty { lines.append("nearby texts: \(siblings.joined(separator: ", "))") }
            }
            if let image = item.imageIndex { lines.append("screenshot: image \(image + 1)") }
            for (locale, text) in item.otherLocales.sorted(by: { $0.key < $1.key }).prefix(4) {
                lines.append("existing \(locale): \(quoted(text))")
            }
            if let current = item.current?[.other] { lines.append("current translation to improve: \(quoted(current))") }
            if let problems = request.feedback[item.keyID.lowercased], !problems.isEmpty {
                lines.append("fix these problems from your last attempt: \(problems.joined(separator: "; "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// Output schema. Arrays of {category, text} instead of optional fields, so it is valid under
    /// the strict modes of Anthropic, OpenAI and Gemini alike.
    public static let schema: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("translations", .object([
                ("type", .string("array")),
                ("items", .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("id", .object([("type", .string("string"))])),
                        ("forms", .object([
                            ("type", .string("array")),
                            ("items", .object([
                                ("type", .string("object")),
                                ("properties", .object([
                                    ("category", .object([("type", .string("string")),
                                                          ("enum", .array(PluralCategory.allCases.map { .string($0.rawValue) }))])),
                                    ("text", .object([("type", .string("string"))])),
                                ])),
                                ("required", .array([.string("category"), .string("text")])),
                                ("additionalProperties", .bool(false)),
                            ])),
                        ])),
                        ("note", .object([("type", .string("string"))])),
                    ])),
                    ("required", .array([.string("id"), .string("forms"), .string("note")])),
                    ("additionalProperties", .bool(false)),
                ])),
            ])),
        ])),
        ("required", .array([.string("translations")])),
        ("additionalProperties", .bool(false)),
    ])

    /// Parses the model's JSON. Tolerates a fenced code block around it.
    public static func parse(_ text: String, request: TranslationRequest) throws -> [TranslationDraft] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
        }
        if !body.hasPrefix("{"), let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") {
            body = String(body[start...end])
        }
        let json: JSONValue
        do {
            json = try JSONValue.parse(Data(body.utf8))
        } catch {
            throw TranslationError.invalidResponse("not JSON")
        }
        guard case .array(let items)? = json["translations"] else { throw TranslationError.invalidResponse("no translations array") }
        var drafts: [TranslationDraft] = []
        for item in items {
            guard let id = item["id"]?.stringValue, id.hasPrefix("s"), let number = Int(id.dropFirst()),
                  request.items.indices.contains(number - 1)
            else { continue }
            var forms: [PluralCategory: String] = [:]
            if case .array(let rawForms)? = item["forms"] {
                for form in rawForms {
                    guard let category = form["category"]?.stringValue.flatMap(PluralCategory.init(rawValue:)),
                          let text = form["text"]?.stringValue
                    else { continue }
                    forms[category] = text
                }
            }
            let note = item["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            drafts.append(TranslationDraft(keyID: request.items[number - 1].keyID, forms: forms, note: note?.isEmpty == false ? note : nil))
        }
        return drafts
    }
}
