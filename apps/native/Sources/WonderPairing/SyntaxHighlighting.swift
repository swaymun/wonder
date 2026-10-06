import Foundation

/// A colour role for code shown in diffs. Views map roles to their palette.
public enum SyntaxRole: Sendable, Equatable {
    case keyword, string, comment, number, type, attribute
}

/// A run of one line's text; `role` is nil for plain text.
public struct SyntaxSpan: Sendable, Equatable {
    public let text: String
    public let role: SyntaxRole?
}

/// A small line tokenizer for common source languages, chosen by file
/// extension. It colours keywords, strings, comments, numbers, type names
/// and attributes; it does not parse. Block comments carry across lines
/// until `reset()`, which callers use at hunk boundaries.
public struct SyntaxHighlighter: Sendable {
    struct Language: Sendable {
        var keywords: Set<String> = []
        var caseInsensitive = false
        var lineComments: [String] = []
        var block: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        /// `'` delimits only short character literals (Rust lifetimes, C chars).
        var shortSingleQuote = false
        var capitalizedTypes = false
        var attributePrefixes: Set<Character> = []
        var markup = false
    }

    let language: Language
    private var inBlock = false

    public init?(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        guard let language = Self.language(name: name, ext: ext) else { return nil }
        self.language = language
    }

    public mutating func reset() { inBlock = false }

    public mutating func spans(_ line: String) -> [SyntaxSpan] {
        let chars = Array(line)
        var spans: [SyntaxSpan] = []
        var plain = ""
        func emit(_ text: String, _ role: SyntaxRole?) {
            guard !text.isEmpty else { return }
            if role == nil { plain += text; return }
            if !plain.isEmpty { spans.append(SyntaxSpan(text: plain, role: nil)); plain = "" }
            spans.append(SyntaxSpan(text: text, role: role))
        }
        func starts(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            return index + token.count <= chars.count && Array(chars[index..<index + token.count]) == token
        }
        func identifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        var i = 0
        var inTag = false
        var expectTagName = false
        while i < chars.count {
            if let block = language.block, inBlock || starts(block.open, at: i) {
                var j = inBlock ? i : i + block.open.count
                while j < chars.count && !starts(block.close, at: j) { j += 1 }
                inBlock = j >= chars.count
                if !inBlock { j += block.close.count }
                emit(String(chars[i..<j]), .comment); i = j; continue
            }
            let c = chars[i]
            if let comment = language.lineComments.first(where: { starts($0, at: i) }),
               comment != "#" || i == 0 || chars[i - 1].isWhitespace {
                emit(String(chars[i...]), .comment); break
            }
            if language.markup {
                if c == "<" {
                    inTag = true; expectTagName = true
                    var j = i + 1
                    if j < chars.count, chars[j] == "/" || chars[j] == "!" || chars[j] == "?" { j += 1 }
                    emit(String(chars[i..<j]), nil); i = j; continue
                }
                if c == ">" { inTag = false; emit(">", nil); i += 1; continue }
                if !inTag { emit(String(c), nil); i += 1; continue }
            }
            if language.quotes.contains(c) {
                if c == "'", language.shortSingleQuote {
                    let limit = min(chars.count, i + 4)
                    var j = i + 1
                    if j < limit, chars[j] == "\\" { j += 2 } else { j += 1 }
                    if j < limit, chars[j] == "'" {
                        emit(String(chars[i...j]), .string); i = j + 1; continue
                    }
                    emit("'", nil); i += 1; continue
                }
                var j = i + 1
                while j < chars.count && chars[j] != c {
                    j += chars[j] == "\\" ? 2 : 1
                }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), .string); i = j; continue
            }
            if c.isASCII, c.isNumber, i == 0 || !identifierChar(chars[i - 1]) {
                var j = i + 1
                while j < chars.count, chars[j].isHexDigit || "xXoObB_.".contains(chars[j]) {
                    if chars[j] == ".", j + 1 < chars.count, !chars[j + 1].isNumber { break }
                    j += 1
                }
                emit(String(chars[i..<j]), .number); i = j; continue
            }
            if language.attributePrefixes.contains(c),
               i + 1 < chars.count, chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, identifierChar(chars[j]) || chars[j] == "." { j += 1 }
                emit(String(chars[i..<j]), .attribute); i = j; continue
            }
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count, identifierChar(chars[j]) || (language.markup && (chars[j] == "-" || chars[j] == ":")) { j += 1 }
                let word = String(chars[i..<j])
                let role: SyntaxRole?
                if language.markup {
                    role = expectTagName ? .keyword : .attribute
                    expectTagName = false
                } else if language.keywords.contains(language.caseInsensitive ? word.lowercased() : word) {
                    role = .keyword
                } else if language.capitalizedTypes, c.isUppercase, word.contains(where: \.isLowercase) {
                    role = .type
                } else {
                    role = nil
                }
                emit(word, role); i = j; continue
            }
            emit(String(c), nil); i += 1
        }
        if !plain.isEmpty { spans.append(SyntaxSpan(text: plain, role: nil)) }
        return spans
    }

    // MARK: Languages

    private static func language(name: String, ext: String) -> Language? {
        let cBlock = (open: "/*", close: "*/")
        switch ext {
        case "swift":
            return Language(keywords: swift, lineComments: ["//"], block: cBlock, quotes: ["\""],
                            capitalizedTypes: true, attributePrefixes: ["@"])
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts":
            return Language(keywords: javascript, lineComments: ["//"], block: cBlock, quotes: ["\"", "'", "`"],
                            capitalizedTypes: true, attributePrefixes: ["@"])
        case "py", "pyi":
            return Language(keywords: python, lineComments: ["#"], capitalizedTypes: true, attributePrefixes: ["@"])
        case "go":
            return Language(keywords: go, lineComments: ["//"], block: cBlock, quotes: ["\"", "'", "`"],
                            shortSingleQuote: true, capitalizedTypes: true)
        case "rs":
            return Language(keywords: rust, lineComments: ["//"], block: cBlock,
                            shortSingleQuote: true, capitalizedTypes: true, attributePrefixes: ["#"])
        case "java", "kt", "kts", "scala", "groovy", "gradle":
            return Language(keywords: jvm, lineComments: ["//"], block: cBlock,
                            shortSingleQuote: true, capitalizedTypes: true, attributePrefixes: ["@"])
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm":
            return Language(keywords: cFamily, lineComments: ["//"], block: cBlock,
                            shortSingleQuote: true, capitalizedTypes: true, attributePrefixes: ["#", "@"])
        case "cs":
            return Language(keywords: csharp, lineComments: ["//"], block: cBlock,
                            shortSingleQuote: true, capitalizedTypes: true)
        case "dart":
            return Language(keywords: dart, lineComments: ["//"], block: cBlock, capitalizedTypes: true, attributePrefixes: ["@"])
        case "rb", "rake", "gemspec":
            return Language(keywords: ruby, lineComments: ["#"], capitalizedTypes: true)
        case "php":
            return Language(keywords: php, lineComments: ["//", "#"], block: cBlock, capitalizedTypes: true)
        case "sh", "bash", "zsh", "fish", "command":
            return Language(keywords: shell, lineComments: ["#"])
        case "sql":
            return Language(keywords: sql, caseInsensitive: true, lineComments: ["--"], block: cBlock)
        case "json", "jsonc", "json5":
            return Language(keywords: literals, lineComments: ext == "json" ? [] : ["//"], block: ext == "json" ? nil : cBlock,
                            quotes: ["\""])
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "env":
            return Language(keywords: literals.union(["yes", "no", "on", "off"]), lineComments: ["#", ";"].filter { $0 == "#" || ext == "ini" })
        case "css", "scss", "sass", "less":
            return Language(keywords: ["important", "media", "import", "keyframes"], lineComments: ext == "css" ? [] : ["//"],
                            block: cBlock, attributePrefixes: ["@"])
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard", "vue", "svelte":
            return Language(block: (open: "<!--", close: "-->"), markup: true)
        default:
            switch name {
            case "dockerfile", "makefile", "gemfile", "podfile", "brewfile", "fastfile", "appfile", "matchfile":
                return Language(keywords: shell.union(ruby), lineComments: ["#"], capitalizedTypes: name != "makefile")
            default:
                return nil
            }
        }
    }

    private static let literals: Set<String> = ["true", "false", "null", "nil", "none", "None", "True", "False"]
    private static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
        "indirect", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open",
        "operator", "override", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
        "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "weak", "where", "while", "willSet", "unowned", "consuming", "borrowing",
    ]
    private static let javascript: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
        "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let",
        "namespace", "new", "null", "of", "private", "protected", "public", "readonly", "return", "satisfies",
        "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
        "void", "while", "with", "yield", "number", "string", "boolean", "any", "unknown", "never",
    ]
    private static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
        "case", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while",
        "with", "yield",
    ]
    private static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return",
        "select", "struct", "switch", "true", "type", "var",
    ]
    private static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
        "Some", "None", "Ok", "Err",
    ]
    private static let jvm: Set<String> = [
        "abstract", "as", "break", "case", "catch", "class", "companion", "const", "continue", "data", "def",
        "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements",
        "import", "in", "interface", "internal", "is", "lateinit", "new", "null", "object", "open", "override",
        "package", "private", "protected", "public", "return", "sealed", "static", "super", "suspend", "switch",
        "synchronized", "this", "throw", "throws", "true", "try", "val", "var", "void", "when", "while",
        "int", "long", "boolean", "double", "float", "char", "byte", "short",
    ]
    private static let cFamily: Set<String> = [
        "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default",
        "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "goto",
        "if", "inline", "int", "long", "namespace", "new", "nullptr", "NULL", "nil", "operator", "private",
        "protected", "public", "return", "self", "short", "signed", "sizeof", "static", "struct", "switch",
        "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using",
        "virtual", "void", "volatile", "while", "YES", "NO", "id", "instancetype",
    ]
    private static let csharp: Set<String> = [
        "abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const",
        "continue", "default", "do", "double", "else", "enum", "false", "finally", "float", "for", "foreach",
        "get", "if", "in", "int", "interface", "internal", "is", "long", "namespace", "new", "null", "object",
        "out", "override", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed",
        "set", "static", "string", "struct", "switch", "this", "throw", "true", "try", "using", "var",
        "virtual", "void", "while",
    ]
    private static let dart: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "do", "else", "enum", "extends", "false", "final", "finally", "for", "if", "import", "in", "is", "late",
        "mixin", "new", "null", "required", "return", "static", "super", "switch", "this", "throw", "true",
        "try", "var", "void", "while", "with", "yield",
    ]
    private static let ruby: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure",
        "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "require", "rescue",
        "retry", "return", "self", "super", "then", "true", "unless", "until", "when", "while", "yield",
        "lane", "private_lane",
    ]
    private static let php: Set<String> = [
        "abstract", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo",
        "else", "elseif", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "if",
        "implements", "interface", "namespace", "new", "null", "private", "protected", "public", "return",
        "static", "switch", "throw", "trait", "true", "try", "use", "while",
    ]
    private static let shell: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local",
        "readonly", "return", "set", "then", "unset", "until", "while", "end", "begin", "and", "or", "not",
        "FROM", "RUN", "COPY", "ADD", "WORKDIR", "ENV", "ARG", "CMD", "ENTRYPOINT", "EXPOSE", "USER", "LABEL",
    ]
    private static let sql: Set<String> = [
        "add", "alter", "and", "as", "asc", "begin", "between", "by", "case", "commit", "create", "default",
        "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "group", "having",
        "if", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not",
        "null", "on", "or", "order", "outer", "primary", "references", "right", "select", "set", "table",
        "then", "transaction", "union", "unique", "update", "values", "view", "when", "where", "with",
        "integer", "text", "real", "blob", "varchar", "boolean",
    ]
}
