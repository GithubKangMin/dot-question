import Foundation

public enum QuestionType: String, Codable {
    case multipleChoice = "multiple_choice", shortAnswer = "short_answer"
    case trueFalse = "true_false", longAnswer = "long_answer"
}

public struct ImportedQuestion: Equatable {
    public let id: String
    public let groupID: String
    public let context: String
    public let type: QuestionType
    public let text: String
    public let choices: [MCQChoice]
    public var displayText: String {
        ([context, text].filter { !$0.isEmpty } + choices.map { "\($0.label). \($0.text)" }).joined(separator: "\n\n")
    }
    public var parsed: ParsedQuestion { ParsedQuestion(text: text, choices: choices, type: type, context: context) }
}

public enum BrowserQuestionImport {
    public static let maximumBytes = 128 * 1024
    public enum ImportError: LocalizedError {
        case invalid
        public var errorDescription: String? { "브라우저 문제 JSON이 유효하지 않습니다. dot-question/v1 형식, 고유 ID, 최대 128KB / 30,000자 / 50문제 / 보기 5개를 확인하세요." }
    }
    /// Validate the entire bundle before returning anything; never silently truncate.
    public static func parse(_ data: Data) throws -> [ImportedQuestion] {
        guard data.count <= maximumBytes else { throw ImportError.invalid }
        var audit = JSONKeyAudit(data: data)
        try audit.validate()
        guard
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schema", "groups"], root["schema"] as? String == "dot-question/v1",
              let groups = root["groups"] as? [[String: Any]], !groups.isEmpty, groups.count <= 50 else { throw ImportError.invalid }
        var result: [ImportedQuestion] = [], groupIDs = Set<String>(), questionIDs = Set<String>()
        var characters = 0
        func nonempty(_ value: Any?, limit: Int = 30_000) -> String? {
            guard let value = value as? String, value.unicodeScalars.count <= limit, !value.contains("\0"), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        for group in groups {
            guard Set(group.keys) == ["id", "context", "questions"], let id = nonempty(group["id"], limit: 128),
                  groupIDs.insert(id).inserted, let context = group["context"] as? String, !context.contains("\0"),
                  let questions = group["questions"] as? [[String: Any]], !questions.isEmpty else { throw ImportError.invalid }
            characters += id.unicodeScalars.count + context.unicodeScalars.count
            for question in questions {
                guard Set(question.keys) == ["id", "type", "text", "choices"],
                      let qid = nonempty(question["id"], limit: 128), questionIDs.insert(qid).inserted,
                      let rawType = question["type"] as? String, let type = QuestionType(rawValue: rawType),
                      let text = nonempty(question["text"]), let rawChoices = question["choices"] as? [[String: Any]],
                      rawChoices.count <= 5 else { throw ImportError.invalid }
                var choices: [MCQChoice] = [], labels = Set<String>()
                for choice in rawChoices {
                    guard Set(choice.keys) == ["label", "text"], let label = nonempty(choice["label"], limit: 32),
                          label == label.trimmingCharacters(in: .whitespacesAndNewlines), labels.insert(label).inserted,
                          let value = nonempty(choice["text"]) else { throw ImportError.invalid }
                    choices.append(MCQChoice(label: label, text: value))
                    characters += label.unicodeScalars.count + value.unicodeScalars.count
                }
                switch type {
                case .multipleChoice: guard choices.count >= 2 else { throw ImportError.invalid }
                case .trueFalse: guard choices.isEmpty || choices.count == 2 else { throw ImportError.invalid }
                case .shortAnswer, .longAnswer: guard choices.isEmpty else { throw ImportError.invalid }
                }
                characters += qid.unicodeScalars.count + text.unicodeScalars.count
                result.append(ImportedQuestion(id: qid, groupID: id, context: context, type: type, text: text, choices: choices))
                guard result.count <= 50, characters <= 30_000 else { throw ImportError.invalid }
            }
        }
        return result
    }
}

/// JSONSerialization accepts repeated object keys. Audit the bounded UTF-8 input
/// first, decoding each key so escaped equivalents cannot bypass uniqueness.
private struct JSONKeyAudit {
    let bytes: [UInt8]
    var index = 0
    init(data: Data) {
        let raw = Array(data)
        bytes = raw.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(raw.dropFirst(3)) : raw
    }
    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw BrowserQuestionImport.ImportError.invalid }
    }
    mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw BrowserQuestionImport.ImportError.invalid }
        index += 1
    }
    mutating func string() throws -> String {
        whitespace()
        let start = index
        try consume(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 {
                guard index < bytes.count else { throw BrowserQuestionImport.ImportError.invalid }
                index += 1
            } else if byte == 34 {
                let token = Data(bytes[start..<index])
                guard let decoded = try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else { throw BrowserQuestionImport.ImportError.invalid }
                return decoded
            }
        }
        throw BrowserQuestionImport.ImportError.invalid
    }
    mutating func value(depth: Int) throws {
        whitespace()
        guard depth <= 16, index < bytes.count else { throw BrowserQuestionImport.ImportError.invalid }
        switch bytes[index] {
        case 123:
            index += 1; whitespace()
            var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw BrowserQuestionImport.ImportError.invalid }
                try consume(58); try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                try consume(44)
            }
        case 91:
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                try consume(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw BrowserQuestionImport.ImportError.invalid }
            // JSONSerialization subsequently validates number/boolean/null syntax.
        }
    }
}
