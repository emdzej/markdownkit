//
//  FormulaFunctions.swift
//  MarkdownEngine
//
//  The spreadsheet functions formulas can call. As in Excel, text and
//  booleans inside ranges are skipped by the numeric aggregates, while
//  values passed directly are coerced (a direct "abc" is `#VALUE!`).
//

import Foundation

enum FormulaFunctions {

    static let names: Set<String> = [
        "SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "PRODUCT",
        "ROUND", "ROUNDUP", "ROUNDDOWN", "ABS", "SQRT", "POWER", "MOD", "INT",
        "IF", "AND", "OR", "NOT", "IFERROR",
        "COUNTIF", "SUMIF", "AVERAGEIF",
        "CONCAT", "CONCATENATE", "LEN", "UPPER", "LOWER", "TRIM", "LEFT", "RIGHT", "MID",
    ]

    /// One argument's values, and whether they came from a range.
    private struct Argument {
        var values: [FormulaValue]
        var fromRange: Bool
    }

    static func call(_ name: String, _ args: [FormulaExpression], sheet: Int, evaluator e: FormulaEvaluator) -> FormulaValue {
        // Lazy ones first: only the taken branch is evaluated.
        switch name {
        case "IF":
            guard (2...3).contains(args.count) else { return .error(.notAvailable) }
            switch FormulaEvaluator.toBool(e.value(args[0], sheet: sheet)) {
            case .failure(let err): return .error(err)
            case .success(let condition):
                if condition { return blankToZero(e.value(args[1], sheet: sheet)) }
                return args.count == 3 ? blankToZero(e.value(args[2], sheet: sheet)) : .boolean(false)
            }
        case "IFERROR":
            guard args.count == 2 else { return .error(.notAvailable) }
            let v = e.value(args[0], sheet: sheet)
            if case .error = v { return blankToZero(e.value(args[1], sheet: sheet)) }
            return v
        default:
            break
        }

        guard names.contains(name) else { return .error(.name) }
        let arguments: [Argument] = args.map { arg in
            switch e.evaluate(arg, sheet: sheet) {
            // A cell reference counts like a one-cell range (SUM(B2) skips text in B2).
            case .value(let v):
                if case .cell = arg { return Argument(values: [v], fromRange: true) }
                return Argument(values: [v], fromRange: false)
            case .range(let grid): return Argument(values: grid.flatMap { $0 }, fromRange: true)
            }
        }

        func numbers() -> Swift.Result<[Double], FormulaError> {
            var out: [Double] = []
            for arg in arguments {
                for v in arg.values {
                    if case .error(let err) = v { return .failure(err) }
                    if arg.fromRange {
                        if case .number(let n) = v { out.append(n) }
                    } else {
                        switch FormulaEvaluator.toNumber(v) {
                        case .success(let n): out.append(n)
                        case .failure(let err): return .failure(err)
                        }
                    }
                }
            }
            return .success(out)
        }
        func aggregate(_ f: ([Double]) -> FormulaValue) -> FormulaValue {
            switch numbers() {
            case .success(let ns): return f(ns)
            case .failure(let err): return .error(err)
            }
        }
        func scalarArgs(_ range: ClosedRange<Int>) -> [FormulaValue]? {
            guard range.contains(arguments.count) else { return nil }
            return arguments.map { $0.values.count == 1 ? $0.values[0] : .error(.value) }
        }
        func number(_ v: FormulaValue) -> Swift.Result<Double, FormulaError> { FormulaEvaluator.toNumber(v) }
        func math(_ count: ClosedRange<Int>, _ f: ([Double]) -> FormulaValue) -> FormulaValue {
            guard let vs = scalarArgs(count) else { return .error(.notAvailable) }
            var ns: [Double] = []
            for v in vs {
                switch number(v) {
                case .success(let n): ns.append(n)
                case .failure(let err): return .error(err)
                }
            }
            return f(ns)
        }
        func textArgs(_ count: ClosedRange<Int>, _ f: ([FormulaValue]) -> FormulaValue) -> FormulaValue {
            guard let vs = scalarArgs(count) else { return .error(.notAvailable) }
            if let err = vs.lazy.compactMap({ v -> FormulaError? in if case .error(let x) = v { return x }; return nil }).first { return .error(err) }
            return f(vs)
        }

        switch name {
        case "SUM": return aggregate { .number($0.reduce(0, +)) }
        case "PRODUCT": return aggregate { $0.isEmpty ? .number(0) : .number($0.reduce(1, *)) }
        case "AVERAGE": return aggregate { $0.isEmpty ? .error(.divisionByZero) : .number($0.reduce(0, +) / Double($0.count)) }
        case "MIN": return aggregate { .number($0.min() ?? 0) }
        case "MAX": return aggregate { .number($0.max() ?? 0) }
        case "COUNT":
            var count = 0
            for arg in arguments {
                for v in arg.values {
                    if case .number = v { count += 1 }
                    else if !arg.fromRange, case .success = number(v), !(v == .blank) { count += 1 }
                }
            }
            return .number(Double(count))
        case "COUNTA":
            return .number(Double(arguments.reduce(0) { $0 + $1.values.filter { $0 != .blank }.count }))
        case "ABS": return math(1...1) { .number(abs($0[0])) }
        case "SQRT": return math(1...1) { $0[0] < 0 ? .error(.number) : .number($0[0].squareRoot()) }
        case "POWER": return math(2...2) { let p = pow($0[0], $0[1]); return p.isFinite ? .number(p) : .error(.number) }
        case "MOD": return math(2...2) { $0[1] == 0 ? .error(.divisionByZero) : .number($0[0] - $0[1] * floor($0[0] / $0[1])) }
        case "INT": return math(1...1) { .number(floor($0[0])) }
        case "ROUND", "ROUNDUP", "ROUNDDOWN":
            return math(1...2) { ns in
                let digits = ns.count > 1 ? Int(ns[1].rounded(.towardZero)) : 0
                let factor = pow(10, Double(digits))
                let scaled = abs(ns[0]) * factor
                // Nudge for binary representation (2.675 → 2.68, like Excel).
                let nudged = (scaled * 1e9).rounded() / 1e9
                let r: Double = switch name {
                case "ROUNDUP": nudged.rounded(.up)
                case "ROUNDDOWN": nudged.rounded(.down)
                default: nudged.rounded(.toNearestOrAwayFromZero)
                }
                return .number((ns[0] < 0 ? -r : r) / factor)
            }
        case "AND", "OR":
            var bools: [Bool] = []
            for arg in arguments {
                for v in arg.values {
                    if case .error(let err) = v { return .error(err) }
                    if arg.fromRange {
                        switch v {
                        case .boolean(let b): bools.append(b)
                        case .number(let n): bools.append(n != 0)
                        default: continue
                        }
                    } else {
                        switch FormulaEvaluator.toBool(v) {
                        case .success(let b): bools.append(b)
                        case .failure(let err): return .error(err)
                        }
                    }
                }
            }
            guard !bools.isEmpty else { return .error(.value) }
            return .boolean(name == "AND" ? bools.allSatisfy { $0 } : bools.contains(true))
        case "NOT":
            guard let vs = scalarArgs(1...1) else { return .error(.notAvailable) }
            switch FormulaEvaluator.toBool(vs[0]) {
            case .success(let b): return .boolean(!b)
            case .failure(let err): return .error(err)
            }
        case "COUNTIF", "SUMIF", "AVERAGEIF":
            let maxArgs = name == "COUNTIF" ? 2 : 3
            guard (2...maxArgs).contains(arguments.count), arguments[1].values.count == 1 else { return .error(.notAvailable) }
            if case .error(let err) = arguments[1].values[0] { return .error(err) }
            let criterion = Criterion(arguments[1].values[0])
            let tested = arguments[0].values
            let summed = arguments.count == 3 ? arguments[2].values : tested
            var count = 0
            var sum = 0.0
            for (i, v) in tested.enumerated() where criterion.matches(v) {
                count += 1
                if name != "COUNTIF", i < summed.count {
                    if case .error(let err) = summed[i] { return .error(err) }
                    if case .number(let n) = summed[i] { sum += n } else if name == "AVERAGEIF" { count -= 1 }
                }
            }
            switch name {
            case "COUNTIF": return .number(Double(count))
            case "SUMIF": return .number(sum)
            default: return count == 0 ? .error(.divisionByZero) : .number(sum / Double(count))
            }
        case "CONCAT", "CONCATENATE":
            var out = ""
            for arg in arguments {
                for v in arg.values {
                    if case .error(let err) = v { return .error(err) }
                    out += FormulaEvaluator.text(v)
                }
            }
            return .string(out)
        case "LEN": return textArgs(1...1) { .number(Double(FormulaEvaluator.text($0[0]).count)) }
        case "UPPER": return textArgs(1...1) { .string(FormulaEvaluator.text($0[0]).uppercased()) }
        case "LOWER": return textArgs(1...1) { .string(FormulaEvaluator.text($0[0]).lowercased()) }
        case "TRIM":
            return textArgs(1...1) { .string(FormulaEvaluator.text($0[0]).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")) }
        case "LEFT", "RIGHT":
            return textArgs(1...2) { vs in
                let s = FormulaEvaluator.text(vs[0])
                var n = 1
                if vs.count > 1 {
                    guard case .success(let x) = number(vs[1]), x >= 0 else { return .error(.value) }
                    n = Int(x)
                }
                return .string(String(name == "LEFT" ? s.prefix(n) : s.suffix(n)))
            }
        case "MID":
            return textArgs(3...3) { vs in
                let s = FormulaEvaluator.text(vs[0])
                guard case .success(let start) = number(vs[1]), case .success(let length) = number(vs[2]),
                      start >= 1, length >= 0 else { return .error(.value) }
                let chars = Array(s)
                let from = min(chars.count, Int(start) - 1)
                let to = min(chars.count, from + Int(length))
                return .string(String(chars[from..<to]))
            }
        default:
            return .error(.name)
        }
    }

    private static func blankToZero(_ v: FormulaValue) -> FormulaValue {
        if case .blank = v { return .number(0) }
        return v
    }

    /// A COUNTIF-style criterion: `">3"`, `"<>x"`, `"=a*"`, `"apple"`, or a number.
    struct Criterion {
        let op: String
        let operand: FormulaValue

        init(_ value: FormulaValue) {
            guard case .string(let text) = value else { op = "="; operand = value; return }
            var o = "="
            var rest = Substring(text)
            for candidate in [">=", "<=", "<>", ">", "<", "="] where rest.hasPrefix(candidate) {
                o = candidate
                rest = rest.dropFirst(candidate.count)
                break
            }
            op = o
            let r = String(rest)
            if let n = FormulaValue.number(from: r) { operand = .number(n) }
            else if r.isEmpty { operand = .blank }
            else if r.uppercased() == "TRUE" { operand = .boolean(true) }
            else if r.uppercased() == "FALSE" { operand = .boolean(false) }
            else { operand = .string(r) }
        }

        func matches(_ value: FormulaValue) -> Bool {
            switch operand {
            case .blank:
                let isBlank = value == .blank || value == .string("")
                return op == "<>" ? !isBlank : (op == "=" ? isBlank : false)
            case .number(let n):
                // Numeric criteria only look at numbers (and numeric text).
                let v: Double
                switch value {
                case .number(let x): v = x
                case .string(let s): guard let x = FormulaValue.number(from: s) else { return op == "<>" }; v = x
                default: return op == "<>"
                }
                switch op {
                case "=": return v == n
                case "<>": return v != n
                case ">": return v > n
                case ">=": return v >= n
                case "<": return v < n
                default: return v <= n
                }
            case .string(let pattern):
                guard case .string(let s) = value else { return op == "<>" }
                switch op {
                case "=": return Self.wildcard(pattern, matches: s)
                case "<>": return !Self.wildcard(pattern, matches: s)
                default:
                    let c = FormulaEvaluator.compare(.string(s), .string(pattern))
                    switch op {
                    case ">": return c > 0
                    case ">=": return c >= 0
                    case "<": return c < 0
                    default: return c <= 0
                    }
                }
            case .boolean(let b):
                let equal = value == .boolean(b)
                return op == "<>" ? !equal : (op == "=" ? equal : false)
            case .error:
                return false
            }
        }

        /// Case-insensitive match with `*` (any run) and `?` (one character).
        static func wildcard(_ pattern: String, matches text: String) -> Bool {
            let p = Array(pattern.lowercased()), t = Array(text.lowercased())
            var dp = Array(repeating: Array(repeating: false, count: t.count + 1), count: p.count + 1)
            dp[0][0] = true
            for i in 1...max(p.count, 1) where i <= p.count {
                if p[i - 1] == "*" { dp[i][0] = dp[i - 1][0] }
            }
            guard !p.isEmpty else { return t.isEmpty }
            for i in 1...p.count {
                for j in stride(from: 1, through: t.count, by: 1) {
                    switch p[i - 1] {
                    case "*": dp[i][j] = dp[i - 1][j] || dp[i][j - 1]
                    case "?": dp[i][j] = dp[i - 1][j - 1]
                    default: dp[i][j] = dp[i - 1][j - 1] && p[i - 1] == t[j - 1]
                    }
                }
            }
            return dp[p.count][t.count]
        }
    }
}
