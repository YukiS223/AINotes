//
//  MathExpression.swift
//  AINotes
//
//  A small, deterministic arithmetic expression compiler used by the
//  native plot renderer. It deliberately does not use NSExpression,
//  JavaScript, or any other general-purpose evaluator.
//

import Foundation

nonisolated enum MathExpressionError: Error, Equatable, LocalizedError, Sendable {
    case emptyExpression
    case expressionTooLong(maximum: Int)
    case tooManyTokens(maximum: Int)
    case expressionTooComplex(maximum: Int)
    case unexpectedCharacter(Character, position: Int)
    case invalidNumber(String, position: Int)
    case unexpectedToken(String, position: Int)
    case expectedToken(String, position: Int)
    case unknownIdentifier(String, position: Int)
    case unknownFunction(String, position: Int)
    case functionRequiresParentheses(String, position: Int)
    case wrongArgumentCount(function: String, expected: String, actual: Int)
    case divisionByZero
    case domainError(function: String)
    case nonFiniteResult

    var errorDescription: String? {
        switch self {
        case .emptyExpression:
            return "The expression is empty."
        case .expressionTooLong(let maximum):
            return "The expression is too long (maximum \(maximum) characters)."
        case .tooManyTokens(let maximum):
            return "The expression contains too many tokens (maximum \(maximum))."
        case .expressionTooComplex(let maximum):
            return "The expression is too complex (maximum \(maximum) operations)."
        case .unexpectedCharacter(let character, let position):
            return "Unexpected character '\(character)' at position \(position)."
        case .invalidNumber(let number, let position):
            return "Invalid number '\(number)' at position \(position)."
        case .unexpectedToken(let token, let position):
            return "Unexpected token '\(token)' at position \(position)."
        case .expectedToken(let token, let position):
            return "Expected \(token) at position \(position)."
        case .unknownIdentifier(let identifier, let position):
            return "Unknown identifier '\(identifier)' at position \(position)."
        case .unknownFunction(let function, let position):
            return "Unknown function '\(function)' at position \(position)."
        case .functionRequiresParentheses(let function, let position):
            return "Function '\(function)' requires parentheses at position \(position)."
        case .wrongArgumentCount(let function, let expected, let actual):
            return "Function '\(function)' expects \(expected) argument(s), but received \(actual)."
        case .divisionByZero:
            return "Division by zero."
        case .domainError(let function):
            return "The input is outside the domain of '\(function)'."
        case .nonFiniteResult:
            return "The expression produced a non-finite result."
        }
    }
}

/// A compiled mathematical expression. Compilation is bounded, and evaluation
/// only has access to the three plot variables `x`, `y`, and `t`.
nonisolated struct MathExpression: Sendable {
    static let maximumSourceLength = 512
    static let maximumTokenCount = 512
    static let maximumNodeCount = 256

    let source: String
    private let root: Node

    init(_ source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MathExpressionError.emptyExpression }
        guard trimmed.count <= Self.maximumSourceLength else {
            throw MathExpressionError.expressionTooLong(maximum: Self.maximumSourceLength)
        }

        let tokens = try Lexer(source: trimmed).tokenize()
        var parser = Parser(tokens: tokens)
        self.root = try parser.parse()
        self.source = trimmed
    }

    static func compile(_ source: String) throws -> MathExpression {
        try MathExpression(source)
    }

    func evaluate(x: Double = 0, y: Double = 0, t: Double = 0) throws -> Double {
        let result = try root.evaluate(variables: Variables(x: x, y: y, t: t))
        guard result.isFinite else { throw MathExpressionError.nonFiniteResult }
        return result
    }

    /// Sampling-friendly evaluation. Syntax errors are still reported during
    /// compilation; isolated domain errors simply become gaps in a plot.
    func value(x: Double = 0, y: Double = 0, t: Double = 0) -> Double? {
        try? evaluate(x: x, y: y, t: t)
    }
}

// MARK: - Evaluation tree

nonisolated private extension MathExpression {
    nonisolated struct Variables: Sendable {
        let x: Double
        let y: Double
        let t: Double

        subscript(_ name: String) -> Double {
            switch name {
            case "x": return x
            case "y": return y
            default: return t
            }
        }
    }

    nonisolated indirect enum Node: Sendable {
        case number(Double)
        case variable(String)
        case unary(UnaryOperator, Node)
        case binary(BinaryOperator, Node, Node)
        case function(String, [Node])

        func evaluate(variables: Variables) throws -> Double {
            let result: Double
            switch self {
            case .number(let value):
                result = value

            case .variable(let name):
                result = variables[name]

            case .unary(let op, let child):
                let value = try child.evaluate(variables: variables)
                result = op == .minus ? -value : value

            case .binary(let op, let left, let right):
                let lhs = try left.evaluate(variables: variables)
                let rhs = try right.evaluate(variables: variables)
                switch op {
                case .add:
                    result = lhs + rhs
                case .subtract:
                    result = lhs - rhs
                case .multiply:
                    result = lhs * rhs
                case .divide:
                    guard rhs != 0 else { throw MathExpressionError.divisionByZero }
                    result = lhs / rhs
                case .power:
                    result = Foundation.pow(lhs, rhs)
                }

            case .function(let name, let arguments):
                let values = try arguments.map { try $0.evaluate(variables: variables) }
                result = try Self.evaluateFunction(name, values: values)
            }

            guard result.isFinite else { throw MathExpressionError.nonFiniteResult }
            return result
        }

        private static func evaluateFunction(_ name: String,
                                             values: [Double]) throws -> Double {
            switch name {
            case "sin":  return Foundation.sin(values[0])
            case "cos":  return Foundation.cos(values[0])
            case "tan":  return Foundation.tan(values[0])
            case "asin":
                guard (-1...1).contains(values[0]) else {
                    throw MathExpressionError.domainError(function: name)
                }
                return Foundation.asin(values[0])
            case "acos":
                guard (-1...1).contains(values[0]) else {
                    throw MathExpressionError.domainError(function: name)
                }
                return Foundation.acos(values[0])
            case "atan": return Foundation.atan(values[0])
            case "exp":  return Foundation.exp(values[0])
            case "log", "ln":
                guard values[0] > 0 else {
                    throw MathExpressionError.domainError(function: name)
                }
                return Foundation.log(values[0])
            case "sqrt":
                guard values[0] >= 0 else {
                    throw MathExpressionError.domainError(function: name)
                }
                return Foundation.sqrt(values[0])
            case "abs": return Swift.abs(values[0])
            case "min": return Swift.min(values[0], values[1])
            case "max": return Swift.max(values[0], values[1])
            default:
                // Parser validation makes this unreachable.
                throw MathExpressionError.unknownFunction(name, position: 0)
            }
        }
    }

    nonisolated enum UnaryOperator: Sendable {
        case plus
        case minus
    }

    nonisolated enum BinaryOperator: Sendable {
        case add
        case subtract
        case multiply
        case divide
        case power
    }
}

// MARK: - Lexer

nonisolated private extension MathExpression {
    nonisolated struct Token: Sendable {
        nonisolated enum Kind: Sendable {
            case number(Double)
            case identifier(String)
            case plus
            case minus
            case multiply
            case divide
            case power
            case leftParenthesis
            case rightParenthesis
            case comma
            case end
        }

        let kind: Kind
        let position: Int

        var displayName: String {
            switch kind {
            case .number(let value): return String(value)
            case .identifier(let value): return value
            case .plus: return "+"
            case .minus: return "-"
            case .multiply: return "*"
            case .divide: return "/"
            case .power: return "^"
            case .leftParenthesis: return "("
            case .rightParenthesis: return ")"
            case .comma: return ","
            case .end: return "end of expression"
            }
        }
    }

    nonisolated struct Lexer {
        let source: String

        private static let recognizedIdentifiers: Set<String> = [
            "x", "y", "t", "pi", "e",
            "sin", "cos", "tan", "asin", "acos", "atan",
            "exp", "log", "ln", "sqrt", "abs", "min", "max"
        ]

        func tokenize() throws -> [Token] {
            let characters = Array(source)
            var index = 0
            var result: [Token] = []

            func append(_ kind: Token.Kind, at position: Int) throws {
                guard result.count < MathExpression.maximumTokenCount else {
                    throw MathExpressionError.tooManyTokens(
                        maximum: MathExpression.maximumTokenCount
                    )
                }
                result.append(Token(kind: kind, position: position))
            }

            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace {
                    index += 1
                    continue
                }

                switch character {
                case "+": try append(.plus, at: index); index += 1
                case "-", "−": try append(.minus, at: index); index += 1
                case "*", "×", "·": try append(.multiply, at: index); index += 1
                case "/", "÷": try append(.divide, at: index); index += 1
                case "^": try append(.power, at: index); index += 1
                case "(": try append(.leftParenthesis, at: index); index += 1
                case ")": try append(.rightParenthesis, at: index); index += 1
                case ",": try append(.comma, at: index); index += 1
                default:
                    if character.isNumber || character == "." {
                        let start = index
                        var sawDigit = false
                        var sawDecimalPoint = false

                        while index < characters.count {
                            let current = characters[index]
                            if current.isNumber {
                                sawDigit = true
                                index += 1
                            } else if current == ".", !sawDecimalPoint {
                                sawDecimalPoint = true
                                index += 1
                            } else {
                                break
                            }
                        }

                        if index < characters.count,
                           (characters[index] == "e" || characters[index] == "E") {
                            let exponentStart = index
                            index += 1
                            if index < characters.count,
                               (characters[index] == "+" || characters[index] == "-") {
                                index += 1
                            }
                            let digitsStart = index
                            while index < characters.count, characters[index].isNumber {
                                index += 1
                            }
                            if digitsStart == index {
                                // Let `2e` mean implicit multiplication by Euler's
                                // constant rather than rejecting a useful expression.
                                index = exponentStart
                            }
                        }

                        let raw = String(characters[start..<index])
                        guard sawDigit, let value = Double(raw), value.isFinite else {
                            throw MathExpressionError.invalidNumber(raw, position: start)
                        }
                        try append(.number(value), at: start)
                    } else if character.isLetter || character == "_" || character == "π" {
                        let start = index
                        index += 1
                        while index < characters.count {
                            let current = characters[index]
                            guard current.isLetter || current.isNumber || current == "_" else {
                                break
                            }
                            index += 1
                        }
                        let raw = String(characters[start..<index]).lowercased()
                        let normalized = raw.replacingOccurrences(of: "π", with: "pi")
                        if Self.recognizedIdentifiers.contains(normalized) {
                            try append(.identifier(normalized), at: start)
                        } else if let factors = Self.symbolProductIdentifiers(raw),
                                  factors.count >= 2 {
                            // Conventional compact products: xy, ex, pix, πx.
                            // Unknown words remain one token so their error is
                            // clear instead of being partially reinterpreted.
                            for factor in factors {
                                try append(.identifier(factor.name),
                                           at: start + factor.offset)
                            }
                        } else {
                            try append(.identifier(normalized), at: start)
                        }
                    } else {
                        throw MathExpressionError.unexpectedCharacter(character,
                                                                       position: index)
                    }
                }
            }

            result.append(Token(kind: .end, position: characters.count))
            return result
        }

        private static func symbolProductIdentifiers(_ raw: String)
            -> [(name: String, offset: Int)]? {
            let characters = Array(raw)
            var index = 0
            var result: [(name: String, offset: Int)] = []
            while index < characters.count {
                if characters[index] == "π" {
                    result.append(("pi", index))
                    index += 1
                } else if index + 1 < characters.count,
                          characters[index] == "p", characters[index + 1] == "i" {
                    result.append(("pi", index))
                    index += 2
                } else {
                    let name = String(characters[index])
                    guard ["x", "y", "t", "e"].contains(name) else { return nil }
                    result.append((name, index))
                    index += 1
                }
            }
            return result
        }
    }
}

// MARK: - Recursive-descent parser

nonisolated private extension MathExpression {
    nonisolated struct Parser {
        private static let singleArgumentFunctions: Set<String> = [
            "sin", "cos", "tan", "asin", "acos", "atan",
            "exp", "log", "ln", "sqrt", "abs"
        ]
        private static let twoArgumentFunctions: Set<String> = ["min", "max"]

        let tokens: [Token]
        private var index = 0
        private var nodeCount = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func parse() throws -> Node {
            let result = try parseAddition()
            guard case .end = current.kind else {
                throw MathExpressionError.unexpectedToken(current.displayName,
                                                          position: current.position)
            }
            return result
        }

        private var current: Token { tokens[index] }

        private mutating func advance() {
            if index < tokens.count - 1 { index += 1 }
        }

        private mutating func makeNode(_ node: Node) throws -> Node {
            nodeCount += 1
            guard nodeCount <= MathExpression.maximumNodeCount else {
                throw MathExpressionError.expressionTooComplex(
                    maximum: MathExpression.maximumNodeCount
                )
            }
            return node
        }

        private mutating func parseAddition() throws -> Node {
            var result = try parseMultiplication()
            while true {
                if case .plus = current.kind {
                    advance()
                    result = try makeNode(.binary(.add, result, parseMultiplication()))
                } else if case .minus = current.kind {
                    advance()
                    result = try makeNode(.binary(.subtract, result, parseMultiplication()))
                } else {
                    return result
                }
            }
        }

        private mutating func parseMultiplication() throws -> Node {
            var result = try parseUnary()
            while true {
                if case .multiply = current.kind {
                    advance()
                    result = try makeNode(.binary(.multiply, result, parseUnary()))
                } else if case .divide = current.kind {
                    advance()
                    result = try makeNode(.binary(.divide, result, parseUnary()))
                } else if startsPrimary(current.kind) {
                    // Conventional implicit multiplication: 2x, 2pi,
                    // 3sin(x), and (x + 1)(x - 1).
                    result = try makeNode(.binary(.multiply, result, parseUnary()))
                } else {
                    return result
                }
            }
        }

        private func startsPrimary(_ kind: Token.Kind) -> Bool {
            switch kind {
            // Adjacent numeric literals are almost certainly a typo (`1 2`
            // or `1.2.3`), so implicit multiplication is limited to the
            // conventional identifier/parenthesis forms.
            case .identifier, .leftParenthesis: return true
            default: return false
            }
        }

        private mutating func parseUnary() throws -> Node {
            if case .plus = current.kind {
                advance()
                return try makeNode(.unary(.plus, parseUnary()))
            }
            if case .minus = current.kind {
                advance()
                return try makeNode(.unary(.minus, parseUnary()))
            }
            return try parsePower()
        }

        private mutating func parsePower() throws -> Node {
            let base = try parsePrimary()
            guard case .power = current.kind else { return base }
            advance()
            // The unary parse on the right makes exponentiation right
            // associative and supports negative exponents.
            return try makeNode(.binary(.power, base, parseUnary()))
        }

        private mutating func parsePrimary() throws -> Node {
            let token = current
            switch token.kind {
            case .number(let value):
                advance()
                return try makeNode(.number(value))

            case .identifier(let identifier):
                advance()
                if case .leftParenthesis = current.kind {
                    return try parseFunction(identifier, position: token.position)
                }
                switch identifier {
                case "x", "y", "t":
                    return try makeNode(.variable(identifier))
                case "pi":
                    return try makeNode(.number(.pi))
                case "e":
                    return try makeNode(.number(Foundation.exp(1)))
                default:
                    if Self.singleArgumentFunctions.contains(identifier)
                        || Self.twoArgumentFunctions.contains(identifier) {
                        throw MathExpressionError.functionRequiresParentheses(
                            identifier,
                            position: token.position
                        )
                    }
                    throw MathExpressionError.unknownIdentifier(identifier,
                                                                position: token.position)
                }

            case .leftParenthesis:
                advance()
                let expression = try parseAddition()
                guard case .rightParenthesis = current.kind else {
                    throw MathExpressionError.expectedToken("')'",
                                                            position: current.position)
                }
                advance()
                return expression

            default:
                throw MathExpressionError.unexpectedToken(token.displayName,
                                                          position: token.position)
            }
        }

        private mutating func parseFunction(_ name: String,
                                            position: Int) throws -> Node {
            guard Self.singleArgumentFunctions.contains(name)
                    || Self.twoArgumentFunctions.contains(name) else {
                throw MathExpressionError.unknownFunction(name, position: position)
            }

            advance() // left parenthesis
            var arguments: [Node] = []
            if case .rightParenthesis = current.kind {
                advance()
            } else {
                while true {
                    arguments.append(try parseAddition())
                    if case .comma = current.kind {
                        advance()
                        continue
                    }
                    guard case .rightParenthesis = current.kind else {
                        throw MathExpressionError.expectedToken("',' or ')'",
                                                                position: current.position)
                    }
                    advance()
                    break
                }
            }

            let expected = Self.twoArgumentFunctions.contains(name) ? 2 : 1
            guard arguments.count == expected else {
                throw MathExpressionError.wrongArgumentCount(
                    function: name,
                    expected: String(expected),
                    actual: arguments.count
                )
            }
            return try makeNode(.function(name, arguments))
        }
    }
}
