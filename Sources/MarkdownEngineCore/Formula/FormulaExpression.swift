//
//  FormulaExpression.swift
//  MarkdownEngine
//
//  Excel-like formula syntax for table cells (vitepress-plugin-markdownformula
//  compatible): parses the text after `#` in `[label](#FORMULA)` into an
//  expression tree. Precedence, lowest first: comparison, `&`, `+ -`,
//  `* /`, `^`, postfix `%`, unary `-` / `+` (so `-2^2` is 4, as in Excel).
//

import Foundation

/// A cell address: zero-based row and column, optionally on a named sheet.
struct FormulaCellRef: Equatable, Sendable {
    var sheet: String?
    var row: Int
    var column: Int
}

indirect enum FormulaExpression: Equatable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case cell(FormulaCellRef)
    case range(FormulaCellRef, FormulaCellRef)
    case unary(String, FormulaExpression)
    case percent(FormulaExpression)
    case binary(String, FormulaExpression, FormulaExpression)
    case call(String, [FormulaExpression])
}

enum FormulaParser {

    /// The expression, or nil when `source` isn't a formula (bad syntax, or a
    /// bare name such as a heading anchor `intro`).
    static func parse(_ source: String) -> FormulaExpression? {
        guard let tokens = tokenize(source), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let expression = parser.comparison(), parser.atEnd else { return nil }
        return expression
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double)
        case string(String)
        case identifier(String)     // name, function, cell (`A1`, `$B$2`), TRUE / FALSE
        case sheet(String)          // `name!` or `'my sheet'!`
        case op(String)
        case lparen, rparen, comma, colon
    }

    static func tokenize(_ source: String) -> [Token]? {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0
        func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isNumber {
                        while k < chars.count, chars[k].isNumber { k += 1 }
                        j = k
                    }
                }
                guard let value = Double(String(chars[i..<j])) else { return nil }
                tokens.append(.number(value))
                i = j
                continue
            }
            if c == "\"" {
                var text = ""
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == "\"" {
                        if j + 1 < chars.count, chars[j + 1] == "\"" { text.append("\""); j += 2; continue }
                        closed = true
                        j += 1
                        break
                    }
                    text.append(chars[j]); j += 1
                }
                guard closed else { return nil }
                tokens.append(.string(text))
                i = j
                continue
            }
            if c == "'" {
                // 'quoted sheet'!
                guard let end = chars[(i + 1)...].firstIndex(of: "'"), end + 1 < chars.count, chars[end + 1] == "!" else { return nil }
                tokens.append(.sheet(String(chars[(i + 1)..<end])))
                i = end + 2
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." || chars[j] == "$" { j += 1 }
                let word = String(chars[i..<j])
                if j < chars.count, chars[j] == "!" {
                    tokens.append(.sheet(word))
                    i = j + 1
                } else {
                    tokens.append(.identifier(word))
                    i = j
                }
                continue
            }
            switch c {
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case ",", ";": tokens.append(.comma)
            case ":": tokens.append(.colon)
            case "<":
                if peek(1) == "=" { tokens.append(.op("<=")); i += 1 }
                else if peek(1) == ">" { tokens.append(.op("<>")); i += 1 }
                else { tokens.append(.op("<")) }
            case ">":
                if peek(1) == "=" { tokens.append(.op(">=")); i += 1 } else { tokens.append(.op(">")) }
            case "=", "+", "-", "*", "/", "^", "&", "%": tokens.append(.op(String(c)))
            default: return nil
            }
            i += 1
        }
        return tokens
    }

    /// `A1`, `$AB$12` → zero-based (row, column).
    static func cellAddress(_ word: String) -> (row: Int, column: Int)? {
        var letters = 0, column = 0, row = 0, digits = 0
        var chars = Substring(word)
        if chars.first == "$" { chars = chars.dropFirst() }
        while let c = chars.first, c.isASCII, c.isLetter {
            column = column * 26 + Int(c.uppercased().unicodeScalars.first!.value - 64)
            letters += 1
            chars = chars.dropFirst()
        }
        if chars.first == "$" { chars = chars.dropFirst() }
        while let c = chars.first, c.isASCII, c.isNumber {
            row = row * 10 + Int(String(c))!
            digits += 1
            chars = chars.dropFirst()
        }
        guard chars.isEmpty, (1...3).contains(letters), digits > 0, digits < 8, row >= 1 else { return nil }
        return (row - 1, column - 1)
    }

    // MARK: Recursive descent

    struct Parser {
        let tokens: [Token]
        var index = 0

        var atEnd: Bool { index == tokens.count }
        var current: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func take(_ op: String) -> Bool {
            if case .op(op)? = current { index += 1; return true }
            return false
        }

        mutating func comparison() -> FormulaExpression? {
            guard var left = concatenation() else { return nil }
            while case .op(let op)? = current, ["=", "<>", "<", "<=", ">", ">="].contains(op) {
                index += 1
                guard let right = concatenation() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func concatenation() -> FormulaExpression? {
            guard var left = additive() else { return nil }
            while take("&") {
                guard let right = additive() else { return nil }
                left = .binary("&", left, right)
            }
            return left
        }

        mutating func additive() -> FormulaExpression? {
            guard var left = multiplicative() else { return nil }
            while case .op(let op)? = current, op == "+" || op == "-" {
                index += 1
                guard let right = multiplicative() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func multiplicative() -> FormulaExpression? {
            guard var left = power() else { return nil }
            while case .op(let op)? = current, op == "*" || op == "/" {
                index += 1
                guard let right = power() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func power() -> FormulaExpression? {
            guard var left = postfix() else { return nil }
            while take("^") {
                guard let right = postfix() else { return nil }
                left = .binary("^", left, right)
            }
            return left
        }

        mutating func postfix() -> FormulaExpression? {
            guard var value = unary() else { return nil }
            while take("%") { value = .percent(value) }
            return value
        }

        mutating func unary() -> FormulaExpression? {
            if take("-") { return unary().map { .unary("-", $0) } }
            if take("+") { return unary() }
            return primary()
        }

        mutating func primary() -> FormulaExpression? {
            guard let token = current else { return nil }
            index += 1
            switch token {
            case .number(let n): return .number(n)
            case .string(let s): return .string(s)
            case .lparen:
                guard let inner = comparison(), current == .rparen else { return nil }
                index += 1
                return inner
            case .sheet(let sheet):
                guard case .identifier(let word)? = current, let a = FormulaParser.cellAddress(word) else { return nil }
                index += 1
                return reference(FormulaCellRef(sheet: sheet, row: a.row, column: a.column))
            case .identifier(let word):
                if current == .lparen {
                    index += 1
                    var args: [FormulaExpression] = []
                    if current == .rparen { index += 1; return .call(word.uppercased(), args) }
                    while true {
                        guard let arg = comparison() else { return nil }
                        args.append(arg)
                        if current == .comma { index += 1; continue }
                        if current == .rparen { index += 1; break }
                        return nil
                    }
                    return .call(word.uppercased(), args)
                }
                if word.uppercased() == "TRUE" { return .boolean(true) }
                if word.uppercased() == "FALSE" { return .boolean(false) }
                guard let a = FormulaParser.cellAddress(word) else { return nil }   // bare names aren't supported
                return reference(FormulaCellRef(sheet: nil, row: a.row, column: a.column))
            default:
                return nil
            }
        }

        /// A cell, or a range when `:` follows.
        mutating func reference(_ start: FormulaCellRef) -> FormulaExpression? {
            guard current == .colon else { return .cell(start) }
            index += 1
            var sheet = start.sheet
            if case .sheet(let s)? = current { sheet = s; index += 1 }
            guard case .identifier(let word)? = current, let a = FormulaParser.cellAddress(word) else { return nil }
            index += 1
            return .range(start, FormulaCellRef(sheet: sheet ?? start.sheet, row: a.row, column: a.column))
        }
    }
}
