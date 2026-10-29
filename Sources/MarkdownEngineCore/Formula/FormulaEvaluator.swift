//
//  FormulaEvaluator.swift
//  MarkdownEngine
//
//  Evaluates formula expressions over a workbook of sheets (one per
//  markdown table). Formula cells can reference other formula cells;
//  cycles evaluate to `#CYCLE!`. Values and errors follow Excel /
//  HyperFormula closely enough for the markdown-formula use case.
//

import Foundation

enum FormulaError: String, Error, Sendable {
    case divisionByZero = "#DIV/0!"
    case reference = "#REF!"
    case name = "#NAME?"
    case value = "#VALUE!"
    case cycle = "#CYCLE!"
    case notAvailable = "#N/A"
    case number = "#NUM!"
    case syntax = "#ERROR!"
}

enum FormulaValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case blank
    case error(FormulaError)

    /// A literal cell's content: numbers (also `50%`), TRUE / FALSE, text; empty is blank.
    init(literal raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { self = .blank; return }
        if let n = FormulaValue.number(from: text) { self = .number(n); return }
        switch text.uppercased() {
        case "TRUE": self = .boolean(true)
        case "FALSE": self = .boolean(false)
        default: self = .string(text)
        }
    }

    static func number(from text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.first != "+" || t.count > 1 else { return nil }
        if t.hasSuffix("%"), let n = Double(t.dropLast().trimmingCharacters(in: .whitespaces)), n.isFinite { return n / 100 }
        // Double("nan") / "inf" parse; they aren't numbers here.
        guard t.allSatisfy({ $0.isNumber || "+-.eE".contains($0) }), let n = Double(t), n.isFinite else { return nil }
        return n
    }
}

/// The parsed tables of one document.
struct FormulaWorkbook {
    enum Content {
        case literal(FormulaValue)
        /// nil when the formula didn't parse.
        case formula(FormulaExpression?)
    }

    struct Sheet {
        var name: String
        var cells: [[Content]]
    }

    var sheets: [Sheet]

    func sheetIndex(named name: String) -> Int? {
        sheets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

final class FormulaEvaluator {
    let workbook: FormulaWorkbook
    let precisionRounding: Int
    private var cache: [Key: FormulaValue] = [:]
    private var inProgress: Set<Key> = []

    private struct Key: Hashable { let sheet, row, column: Int }

    init(workbook: FormulaWorkbook, precisionRounding: Int = 4) {
        self.workbook = workbook
        self.precisionRounding = precisionRounding
    }

    /// The value of a cell, rounded as HyperFormula rounds its output.
    func displayValue(sheet: Int, row: Int, column: Int) -> FormulaValue {
        let value = cellValue(sheet: sheet, row: row, column: column)
        if case .number(let n) = value { return .number(Self.round(n, precision: precisionRounding)) }
        return value
    }

    func cellValue(sheet: Int, row: Int, column: Int) -> FormulaValue {
        let key = Key(sheet: sheet, row: row, column: column)
        if let cached = cache[key] { return cached }
        guard sheet < workbook.sheets.count, row >= 0, column >= 0,
              row < workbook.sheets[sheet].cells.count, column < workbook.sheets[sheet].cells[row].count
        else { return .blank }  // outside the table: an empty cell, as in a spreadsheet
        let value: FormulaValue
        switch workbook.sheets[sheet].cells[row][column] {
        case .literal(let v):
            value = v
        case .formula(let expression):
            guard let expression else { value = .error(.syntax); break }
            if inProgress.contains(key) { return .error(.cycle) }
            inProgress.insert(key)
            var result = scalar(evaluate(expression, sheet: sheet))
            inProgress.remove(key)
            if case .blank = result { result = .number(0) }
            value = result
        }
        cache[key] = value
        return value
    }

    /// `HyperFormula`'s `cellValueRounding`: `precision + 1` significant digits.
    static func round(_ value: Double, precision: Int) -> Double {
        guard value != 0, value.isFinite else { return value }
        let magnitude = floor(log10(abs(value)))
        let places = pow(10, Double(precision) - magnitude)
        let rounded = (abs(value) * places).rounded() / places
        return value < 0 ? -rounded : rounded
    }

    // MARK: Evaluation

    /// A value or, for ranges, a grid of values.
    enum Result {
        case value(FormulaValue)
        case range([[FormulaValue]])
    }

    func scalar(_ result: Result) -> FormulaValue {
        switch result {
        case .value(let v): return v
        case .range(let grid):
            // A single-cell range is that cell; larger ones can't be one value.
            if grid.count == 1, grid[0].count == 1 { return grid[0][0] }
            return .error(.value)
        }
    }

    func value(_ expression: FormulaExpression, sheet: Int) -> FormulaValue {
        scalar(evaluate(expression, sheet: sheet))
    }

    func evaluate(_ expression: FormulaExpression, sheet: Int) -> Result {
        switch expression {
        case .number(let n): return .value(.number(n))
        case .string(let s): return .value(.string(s))
        case .boolean(let b): return .value(.boolean(b))
        case .cell(let ref):
            guard let s = resolveSheet(ref.sheet, from: sheet) else { return .value(.error(.reference)) }
            return .value(cellValue(sheet: s, row: ref.row, column: ref.column))
        case .range(let a, let b):
            guard let s = resolveSheet(a.sheet, from: sheet),
                  resolveSheet(b.sheet, from: sheet) == s else { return .value(.error(.reference)) }
            let rows = min(a.row, b.row)...max(a.row, b.row)
            let columns = min(a.column, b.column)...max(a.column, b.column)
            guard rows.count * columns.count <= 100_000 else { return .value(.error(.reference)) }
            return .range(rows.map { r in columns.map { c in cellValue(sheet: s, row: r, column: c) } })
        case .unary(_, let operand):
            switch Self.toNumber(value(operand, sheet: sheet)) {
            case .success(let n): return .value(.number(-n))
            case .failure(let e): return .value(.error(e))
            }
        case .percent(let operand):
            switch Self.toNumber(value(operand, sheet: sheet)) {
            case .success(let n): return .value(.number(n / 100))
            case .failure(let e): return .value(.error(e))
            }
        case .binary(let op, let l, let r):
            return .value(binary(op, value(l, sheet: sheet), value(r, sheet: sheet)))
        case .call(let name, let args):
            return .value(FormulaFunctions.call(name, args, sheet: sheet, evaluator: self))
        }
    }

    private func resolveSheet(_ name: String?, from sheet: Int) -> Int? {
        guard let name else { return sheet }
        return workbook.sheetIndex(named: name)
    }

    private func binary(_ op: String, _ l: FormulaValue, _ r: FormulaValue) -> FormulaValue {
        if case .error(let e) = l { return .error(e) }
        if case .error(let e) = r { return .error(e) }
        switch op {
        case "&":
            return .string(Self.text(l) + Self.text(r))
        case "=", "<>", "<", "<=", ">", ">=":
            let order = Self.compare(l, r)
            switch op {
            case "=": return .boolean(order == 0)
            case "<>": return .boolean(order != 0)
            case "<": return .boolean(order < 0)
            case "<=": return .boolean(order <= 0)
            case ">": return .boolean(order > 0)
            default: return .boolean(order >= 0)
            }
        default:
            let a = Self.toNumber(l), b = Self.toNumber(r)
            guard case .success(let x) = a else { if case .failure(let e) = a { return .error(e) }; return .error(.value) }
            guard case .success(let y) = b else { if case .failure(let e) = b { return .error(e) }; return .error(.value) }
            switch op {
            case "+": return .number(x + y)
            case "-": return .number(x - y)
            case "*": return .number(x * y)
            case "/": return y == 0 ? .error(.divisionByZero) : .number(x / y)
            case "^":
                let p = pow(x, y)
                return p.isFinite ? .number(p) : .error(.number)
            default: return .error(.value)
            }
        }
    }



    // MARK: Coercion

    /// A value as a number: blank is 0, booleans 1 / 0, numeric text its number.
    static func toNumber(_ v: FormulaValue) -> Swift.Result<Double, FormulaError> {
        switch v {
        case .number(let n): return .success(n)
        case .boolean(let b): return .success(b ? 1 : 0)
        case .blank: return .success(0)
        case .string(let s):
            if let n = FormulaValue.number(from: s) { return .success(n) }
            return .failure(.value)
        case .error(let e): return .failure(e)
        }
    }

    static func toBool(_ v: FormulaValue) -> Swift.Result<Bool, FormulaError> {
        switch v {
        case .boolean(let b): return .success(b)
        case .number(let n): return .success(n != 0)
        case .blank: return .success(false)
        case .string(let s):
            switch s.uppercased() {
            case "TRUE": return .success(true)
            case "FALSE": return .success(false)
            default: return .failure(.value)
            }
        case .error(let e): return .failure(e)
        }
    }

    /// A value as text, as `&` and the text functions see it.
    static func text(_ v: FormulaValue) -> String {
        switch v {
        case .number(let n): return format(n)
        case .string(let s): return s
        case .boolean(let b): return b ? "TRUE" : "FALSE"
        case .blank: return ""
        case .error(let e): return e.rawValue
        }
    }

    /// Excel ordering: numbers < text < booleans; text compares case-insensitively.
    static func compare(_ l: FormulaValue, _ r: FormulaValue) -> Int {
        func rank(_ v: FormulaValue) -> Int {
            switch v {
            case .number, .blank: return 0
            case .string: return 1
            case .boolean: return 2
            case .error: return 3
            }
        }
        // Blank compares as 0 with numbers and "" with text.
        var l = l, r = r
        if case .blank = l { if case .string = r { l = .string("") } else { l = .number(0) } }
        if case .blank = r { if case .string = l { r = .string("") } else { r = .number(0) } }
        if case .blank = l { l = .number(0) }
        let (a, b) = (rank(l), rank(r))
        if a != b { return a < b ? -1 : 1 }
        switch (l, r) {
        case (.number(let x), .number(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.string(let x), .string(let y)):
            let c = x.compare(y, options: [.caseInsensitive])
            return c == .orderedAscending ? -1 : (c == .orderedDescending ? 1 : 0)
        case (.boolean(let x), .boolean(let y)): return x == y ? 0 : (!x ? -1 : 1)
        default: return 0
        }
    }

    /// JavaScript's `String(number)`: shortest round-trip digits, no exponent between 1e-7 and 1e21.
    static func format(_ n: Double) -> String {
        if n == 0 { return "0" }
        if n == n.rounded(), abs(n) < 1e21 { return String(format: "%.0f", n) }
        let description = "\(n)"
        guard description.contains("e"), abs(n) >= 1e-7, abs(n) < 1e21 else {
            return description.replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: "e+0", with: "e+")
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 20
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 17
        return formatter.string(from: NSNumber(value: n)) ?? description
    }
}
