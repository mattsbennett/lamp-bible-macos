import Foundation

/// Classifies the parts of a fenced block so a reader's eye can find them.
///
/// Deliberately a small lexer rather than a dependency: an agent reply is
/// read, not compiled, so the point is to separate what is said (comments and
/// strings) from what is done (keywords), and to leave anything unrecognised
/// looking exactly as it was written. A language this does not know renders as
/// plain monospaced text rather than guessing.
public enum LampCodeHighlighter {
    public enum Token: String, Equatable, Sendable {
        case plain
        case keyword
        case string
        case comment
        case number
    }

    public struct Span: Equatable, Sendable {
        public let text: String
        public let token: Token

        public init(text: String, token: Token) {
            self.text = text
            self.token = token
        }
    }

    /// What a fence's info string means, as the CLIs write it.
    public enum Language: Equatable, Sendable {
        case swift
        case json
        case shell
        case python
        case javascript
        case unknown

        public init(info: String?) {
            switch info?.lowercased().trimmingCharacters(in: .whitespaces) {
            case "swift": self = .swift
            case "json", "json5", "jsonc": self = .json
            case "sh", "bash", "zsh", "shell", "console", "terminal": self = .shell
            case "python", "py": self = .python
            case "js", "javascript", "ts", "typescript", "jsx", "tsx": self = .javascript
            default: self = .unknown
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift:
                [
                    "actor", "any", "as", "async", "await", "break", "case", "catch",
                    "class", "continue", "default", "defer", "deinit", "do", "else",
                    "enum", "extension", "fallthrough", "false", "for", "func", "guard",
                    "if", "import", "in", "init", "inout", "internal", "is", "let",
                    "nil", "open", "operator", "private", "protocol", "public",
                    "repeat", "return", "self", "Self", "static", "struct", "subscript",
                    "super", "switch", "throw", "throws", "true", "try", "typealias",
                    "var", "where", "while",
                ]
            case .json:
                ["true", "false", "null"]
            case .shell:
                [
                    "case", "do", "done", "elif", "else", "esac", "exit", "export",
                    "fi", "for", "function", "if", "in", "local", "return", "then",
                    "while",
                ]
            case .python:
                [
                    "and", "as", "assert", "async", "await", "break", "class",
                    "continue", "def", "del", "elif", "else", "except", "False",
                    "finally", "for", "from", "global", "if", "import", "in", "is",
                    "lambda", "None", "nonlocal", "not", "or", "pass", "raise",
                    "return", "True", "try", "while", "with", "yield",
                ]
            case .javascript:
                [
                    "async", "await", "break", "case", "catch", "class", "const",
                    "continue", "default", "delete", "do", "else", "export", "extends",
                    "false", "finally", "for", "from", "function", "if", "import",
                    "in", "instanceof", "let", "new", "null", "of", "return", "static",
                    "super", "switch", "this", "throw", "true", "try", "typeof", "var",
                    "void", "while", "yield",
                ]
            case .unknown:
                []
            }
        }

        /// What starts a comment that runs to the end of the line.
        var lineCommentMarkers: [String] {
            switch self {
            case .swift, .javascript: ["//"]
            case .shell, .python: ["#"]
            case .json, .unknown: []
            }
        }

        var hasBlockComments: Bool {
            self == .swift || self == .javascript
        }

        var stringDelimiters: Set<Character> {
            switch self {
            case .json: ["\""]
            case .unknown: []
            default: ["\"", "'", "`"]
            }
        }
    }

    /// Splits `code` into runs, each labelled with what it is.
    ///
    /// The spans joined back together are exactly `code`: highlighting never
    /// adds, drops or reorders a character.
    public static func spans(in code: String, language: Language) -> [Span] {
        guard language != .unknown else {
            return code.isEmpty ? [] : [Span(text: code, token: .plain)]
        }

        var spans: [Span] = []
        var pending = ""
        var pendingToken = Token.plain

        func emit(_ text: String, as token: Token) {
            guard !text.isEmpty else { return }
            if token == pendingToken {
                pending += text
            } else {
                if !pending.isEmpty { spans.append(Span(text: pending, token: pendingToken)) }
                pending = text
                pendingToken = token
            }
        }

        let characters = Array(code)
        var index = 0
        let keywords = language.keywords

        while index < characters.count {
            let character = characters[index]

            // A comment to the end of the line.
            if let marker = language.lineCommentMarkers.first(where: {
                matches($0, in: characters, at: index)
            }) {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(String(characters[index..<end]), as: .comment)
                index = end
                _ = marker
                continue
            }

            // A comment that runs until it is closed.
            if language.hasBlockComments, matches("/*", in: characters, at: index) {
                var end = index + 2
                while end < characters.count, !matches("*/", in: characters, at: end) { end += 1 }
                end = min(end + 2, characters.count)
                emit(String(characters[index..<end]), as: .comment)
                index = end
                continue
            }

            // A string, up to its unescaped closing delimiter.
            if language.stringDelimiters.contains(character) {
                var end = index + 1
                while end < characters.count {
                    if characters[end] == "\\" {
                        end += 2
                        continue
                    }
                    if characters[end] == character { end += 1; break }
                    // An unterminated string stops at the line, so one stray
                    // quotation mark cannot colour the rest of the block.
                    if characters[end] == "\n" { break }
                    end += 1
                }
                end = min(end, characters.count)
                emit(String(characters[index..<end]), as: .string)
                index = end
                continue
            }

            // A number, but not the tail of an identifier such as `utf8`.
            if character.isNumber, index == 0 || !isWordCharacter(characters[index - 1]) {
                var end = index
                while end < characters.count,
                      characters[end].isHexDigit || characters[end] == "."
                        || characters[end] == "_" || characters[end] == "x" {
                    end += 1
                }
                emit(String(characters[index..<end]), as: .number)
                index = end
                continue
            }

            // A word, which may be a keyword.
            if isWordCharacter(character) {
                var end = index
                while end < characters.count, isWordCharacter(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                emit(word, as: keywords.contains(word) ? .keyword : .plain)
                index = end
                continue
            }

            emit(String(character), as: .plain)
            index += 1
        }

        if !pending.isEmpty { spans.append(Span(text: pending, token: pendingToken)) }
        return spans
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func matches(_ needle: String, in characters: [Character], at index: Int) -> Bool {
        let needle = Array(needle)
        guard index + needle.count <= characters.count else { return false }
        for offset in needle.indices where characters[index + offset] != needle[offset] {
            return false
        }
        return true
    }
}

/// Reads a unified diff a line at a time.
///
/// A diff is the one fence where colour carries meaning rather than decoration,
/// and where a syntax lexer would be actively wrong: every line begins with a
/// marker that is not part of the code.
public enum LampDiffHighlighter {
    public enum Line: String, Equatable, Sendable {
        case added
        case removed
        /// File headers and hunk ranges: structure, not content.
        case meta
        case context
    }

    public struct Row: Equatable, Sendable {
        public let text: String
        public let kind: Line

        public init(text: String, kind: Line) {
            self.text = text
            self.kind = kind
        }
    }

    public static func rows(in diff: String) -> [Row] {
        diff.components(separatedBy: .newlines).map { line in
            Row(text: line, kind: kind(of: line))
        }
    }

    private static func kind(of line: String) -> Line {
        // The headers are checked first: `+++` and `---` open with the same
        // characters as an added and a removed line.
        for marker in ["+++", "---", "@@", "diff ", "index ", "new file", "deleted file",
                       "rename from", "rename to", "similarity index"]
        where line.hasPrefix(marker) {
            return .meta
        }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
