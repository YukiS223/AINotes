import UIKit
import CoreText

/// A small, dependency-free TeX-style renderer for note annotations.
///
/// `measure` and `image` deliberately share the same parser and layout pass.
/// This keeps labels positioned identically in SwiftUI overlays and exported
/// snapshots, including formulas with compound limits such as
/// `\int_0^{2\pi}`.
public enum MathLabelRenderer {
    /// Returns the tightly trimmed point size of a rendered formula.
    public static func measure(latex: String, fontSize: CGFloat) -> CGSize {
        preparedLayout(latex: latex, fontSize: fontSize).size
    }

    /// Renders a tightly trimmed, transparent formula image.
    ///
    /// - Parameters:
    ///   - latex: A practical TeX subset. Malformed or unknown commands are
    ///     rendered visibly when possible instead of failing.
    ///   - color: The foreground color for glyphs and rules.
    ///   - fontSize: The base point size.
    ///   - scale: Image pixels per point. Invalid values fall back to 1.
    public static func image(latex: String,
                             color: UIColor,
                             fontSize: CGFloat,
                             scale: CGFloat = 1) -> UIImage {
        let prepared = preparedLayout(latex: latex, fontSize: fontSize)
        guard prepared.size.width > 0, prepared.size.height > 0 else {
            return UIImage()
        }

        let requestedScale = scale.isFinite && scale > 0 ? scale : 1
        // A malformed or machine-generated label should never request an
        // enormous bitmap. Preserve its point size while lowering only the
        // backing scale when necessary.
        let longestSide = max(prepared.size.width, prepared.size.height)
        let safeScale = min(requestedScale, max(0.25, 8_192 / longestSide))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = safeScale

        return UIGraphicsImageRenderer(size: prepared.size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.translateBy(x: prepared.translation.x,
                                y: prepared.translation.y)
            for command in prepared.commands {
                command.draw(in: context, color: color)
            }
        }
    }
}

// MARK: - Parsed representation

private extension MathLabelRenderer {
    enum FontFace {
        case mathItalic
        case roman
        case bold
    }

    enum SymbolClass {
        case ordinary
        case binary
        case relation
        case punctuation

        var sidePadding: CGFloat {
            switch self {
            case .ordinary: return 0
            case .binary: return 0.16
            case .relation: return 0.22
            case .punctuation: return 0.07
            }
        }
    }

    enum LargeOperatorKind {
        case integral(String)
        case stacked(String)

        var glyph: String {
            switch self {
            case .integral(let glyph), .stacked(let glyph): return glyph
            }
        }

        var usesStackedLimits: Bool {
            if case .stacked = self { return true }
            return false
        }
    }

    enum AccentKind {
        case bar
        case overline
        case hat
        case vector
        case dot
    }

    indirect enum MathNode {
        case row([MathNode])
        case text(String, FontFace)
        case symbol(String, SymbolClass)
        case space(CGFloat)
        case fraction(MathNode, MathNode)
        case radical(MathNode, index: MathNode?)
        case scripts(base: MathNode, subscriptNode: MathNode?, superscriptNode: MathNode?)
        case largeOperator(LargeOperatorKind)
        case delimited(left: String, body: MathNode, right: String)
        case styled(FontFace, MathNode)
        case accent(AccentKind, MathNode)
    }

    struct Parser {
        private var characters: [Character]
        private var index = 0
        private var depth = 0
        private let maximumDepth = 64

        init(_ latex: String) {
            // Labels are normally short. This cap keeps corrupt persisted or
            // model-generated input from causing excessive layout work.
            characters = Array(latex.prefix(4_096))
        }

        mutating func parse() -> MathNode {
            parseRow(until: nil, stoppingAtRight: false)
        }

        private var isAtEnd: Bool { index >= characters.count }

        private var current: Character? {
            isAtEnd ? nil : characters[index]
        }

        private mutating func advance() -> Character? {
            guard !isAtEnd else { return nil }
            let character = characters[index]
            index += 1
            return character
        }

        private func matches(_ string: String) -> Bool {
            let candidate = Array(string)
            guard index + candidate.count <= characters.count else { return false }
            return Array(characters[index ..< index + candidate.count]) == candidate
        }

        private mutating func consume(_ string: String) {
            index = min(characters.count, index + string.count)
        }

        private func upcomingCommandIs(_ expected: String) -> Bool {
            guard current == "\\" else { return false }
            var cursor = index + 1
            var name = ""
            while cursor < characters.count, characters[cursor].isLetter {
                name.append(characters[cursor])
                cursor += 1
            }
            return name == expected
        }

        private mutating func parseRow(until closingCharacter: Character?,
                                       stoppingAtRight: Bool) -> MathNode {
            guard depth < maximumDepth else {
                return .text(consumeRemainder(until: closingCharacter), .roman)
            }
            depth += 1
            defer { depth -= 1 }

            var nodes: [MathNode] = []
            while !isAtEnd {
                if let closingCharacter, current == closingCharacter { break }
                if stoppingAtRight, upcomingCommandIs("right") { break }

                guard var atom = parseAtom() else { continue }
                var subscriptNode: MathNode?
                var superscriptNode: MathNode?

                while prepareForPossibleScript() {
                    let marker = advance()
                    let argument = parseScriptArgument()
                    if marker == "_" {
                        subscriptNode = argument
                    } else {
                        superscriptNode = argument
                    }
                }

                if subscriptNode != nil || superscriptNode != nil {
                    atom = .scripts(base: atom,
                                    subscriptNode: subscriptNode,
                                    superscriptNode: superscriptNode)
                }
                nodes.append(atom)
            }
            return collapsedRow(nodes)
        }

        /// TeX ignores whitespace between an atom, `\limits`, and its
        /// scripts. Preserve that whitespace when no script follows.
        private mutating func prepareForPossibleScript() -> Bool {
            let checkpoint = index
            while current?.isWhitespace == true { _ = advance() }

            if upcomingCommandIs("limits") || upcomingCommandIs("nolimits") {
                _ = advance()
                while current?.isLetter == true { _ = advance() }
                while current?.isWhitespace == true { _ = advance() }
            }

            guard current == "_" || current == "^" else {
                index = checkpoint
                return false
            }
            return true
        }

        private mutating func parseAtom() -> MathNode? {
            guard let character = current else { return nil }

            if character == "{" {
                _ = advance()
                let group = parseRow(until: "}", stoppingAtRight: false)
                if current == "}" { _ = advance() }
                return group
            }

            if character == "}" {
                // A stray closing brace is kept visible rather than causing
                // the parser to stall forever.
                _ = advance()
                return .text("}", .roman)
            }

            if character == "\\" {
                return parseCommand()
            }

            if character.isWhitespace {
                while current?.isWhitespace == true { _ = advance() }
                return .space(0.25)
            }

            if matches("<->") {
                consume("<->")
                return .symbol("↔", .relation)
            }
            if matches("<=") {
                consume("<=")
                return .symbol("≤", .relation)
            }
            if matches(">=") {
                consume(">=")
                return .symbol("≥", .relation)
            }
            if matches("!=") {
                consume("!=")
                return .symbol("≠", .relation)
            }
            if matches("->") {
                consume("->")
                return .symbol("→", .relation)
            }
            if matches("...") {
                consume("...")
                return .symbol("…", .punctuation)
            }

            if let symbolClass = Self.symbolClass(for: character) {
                _ = advance()
                return .symbol(String(character), symbolClass)
            }

            let face = Self.defaultFace(for: character)
            var run = ""
            while let candidate = current,
                  !Self.isSyntax(candidate),
                  Self.symbolClass(for: candidate) == nil,
                  Self.defaultFace(for: candidate) == face {
                run.append(candidate)
                _ = advance()
            }
            if run.isEmpty {
                _ = advance()
                return .text(String(character), face)
            }
            return .text(run, face)
        }

        private mutating func parseScriptArgument() -> MathNode {
            guard !isAtEnd else { return .row([]) }
            if current == "{" {
                _ = advance()
                let group = parseRow(until: "}", stoppingAtRight: false)
                if current == "}" { _ = advance() }
                return group
            }
            return parseAtom() ?? .row([])
        }

        private mutating func parseRequiredArgument() -> MathNode {
            parseScriptArgument()
        }

        private mutating func parseCommand() -> MathNode {
            _ = advance() // backslash
            guard let character = current else { return .text("\\", .roman) }

            let command: String
            if character.isLetter {
                var name = ""
                while let candidate = current, candidate.isLetter {
                    name.append(candidate)
                    _ = advance()
                }
                command = name
            } else {
                command = String(advance() ?? character)
            }

            switch command {
            case "frac", "dfrac", "tfrac":
                return .fraction(parseRequiredArgument(), parseRequiredArgument())

            case "sqrt":
                var rootIndex: MathNode?
                if current == "[" {
                    _ = advance()
                    rootIndex = parseRow(until: "]", stoppingAtRight: false)
                    if current == "]" { _ = advance() }
                }
                return .radical(parseRequiredArgument(), index: rootIndex)

            case "int": return .largeOperator(.integral("∫"))
            case "iint": return .largeOperator(.integral("∬"))
            case "iiint": return .largeOperator(.integral("∭"))
            case "oint": return .largeOperator(.integral("∮"))
            case "sum": return .largeOperator(.stacked("∑"))
            case "prod": return .largeOperator(.stacked("∏"))
            case "coprod": return .largeOperator(.stacked("∐"))
            case "bigcup": return .largeOperator(.stacked("⋃"))
            case "bigcap": return .largeOperator(.stacked("⋂"))

            case "left":
                let left = parseDelimiter()
                let body = parseRow(until: nil, stoppingAtRight: true)
                var right = ""
                if upcomingCommandIs("right") {
                    _ = advance()
                    while current?.isLetter == true { _ = advance() }
                    right = parseDelimiter()
                }
                return .delimited(left: left, body: body, right: right)

            case "right":
                return .symbol(parseDelimiter(), .ordinary)

            case "mathrm", "textrm", "operatorname", "text":
                return .styled(.roman, parseRequiredArgument())
            case "mathbf", "boldsymbol":
                return .styled(.bold, parseRequiredArgument())
            case "mathit":
                return .styled(.mathItalic, parseRequiredArgument())

            case "bar": return .accent(.bar, parseRequiredArgument())
            case "overline": return .accent(.overline, parseRequiredArgument())
            case "hat", "widehat": return .accent(.hat, parseRequiredArgument())
            case "vec": return .accent(.vector, parseRequiredArgument())
            case "dot": return .accent(.dot, parseRequiredArgument())

            case ",": return .space(0.16)
            case ":": return .space(0.22)
            case ";": return .space(0.28)
            case "!": return .space(-0.12)
            case " ": return .space(0.33)
            case "quad": return .space(1)
            case "qquad": return .space(2)
            case "enspace": return .space(0.5)
            case "thinspace": return .space(0.16)
            case "\n", "\\": return .space(0.5)

            case "sin", "cos", "tan", "sec", "csc", "cot",
                 "sinh", "cosh", "tanh", "log", "ln", "exp",
                 "lim", "min", "max", "det", "gcd", "mod":
                return .text(command, .roman)

            case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle":
                return .row([])

            case "{": return .text("{", .roman)
            case "}": return .text("}", .roman)
            case "_": return .text("_", .roman)
            case "^": return .text("^", .roman)
            case "%": return .text("%", .roman)
            case "#": return .text("#", .roman)
            case "&": return .text("&", .roman)

            default:
                if let greek = Self.greek[command] {
                    return .text(greek.glyph, greek.face)
                }
                if let mapped = Self.commandSymbols[command] {
                    return .symbol(mapped.glyph, mapped.symbolClass)
                }
                if let delimiter = Self.delimiters[command] {
                    return .symbol(delimiter, .ordinary)
                }
                // Unknown commands remain readable and measurable.
                return .text(command.isEmpty ? "\\" : command, .roman)
            }
        }

        private mutating func parseDelimiter() -> String {
            while current?.isWhitespace == true { _ = advance() }
            guard !isAtEnd else { return "" }

            if current == "\\" {
                _ = advance()
                var command = ""
                if current?.isLetter == true {
                    while let character = current, character.isLetter {
                        command.append(character)
                        _ = advance()
                    }
                } else if let character = advance() {
                    command = String(character)
                }
                return Self.delimiters[command] ?? command
            }

            return String(advance() ?? ".") == "." ? "" : String(characters[index - 1])
        }

        private mutating func consumeRemainder(until closing: Character?) -> String {
            var output = ""
            while let character = current, character != closing {
                output.append(character)
                _ = advance()
            }
            return output
        }

        private func collapsedRow(_ nodes: [MathNode]) -> MathNode {
            if nodes.count == 1 { return nodes[0] }
            return .row(nodes)
        }

        private static func isSyntax(_ character: Character) -> Bool {
            character == "\\" || character == "{" || character == "}"
                || character == "^" || character == "_" || character.isWhitespace
        }

        private static func defaultFace(for character: Character) -> FontFace {
            character.isLetter ? .mathItalic : .roman
        }

        private static func symbolClass(for character: Character) -> SymbolClass? {
            switch character {
            case "+", "−", "-", "*", "×", "÷", "·", "/", "±", "∓",
                 "∪", "∩", "∧", "∨":
                return .binary
            case "=", "<", ">", "≤", "≥", "≠", "≈", "≡", "∈", "∉",
                 "⊂", "⊆", "⊃", "⊇", "→", "←", "↔", "⇒", "⇐", "⇔":
                return .relation
            case ",", ";", ":":
                return .punctuation
            default:
                return nil
            }
        }

        private static let greek: [String: (glyph: String, face: FontFace)] = [
            "alpha": ("α", .mathItalic), "beta": ("β", .mathItalic),
            "gamma": ("γ", .mathItalic), "delta": ("δ", .mathItalic),
            "epsilon": ("ϵ", .mathItalic), "varepsilon": ("ε", .mathItalic),
            "zeta": ("ζ", .mathItalic), "eta": ("η", .mathItalic),
            "theta": ("θ", .mathItalic), "vartheta": ("ϑ", .mathItalic),
            "iota": ("ι", .mathItalic), "kappa": ("κ", .mathItalic),
            "lambda": ("λ", .mathItalic), "mu": ("μ", .mathItalic),
            "nu": ("ν", .mathItalic), "xi": ("ξ", .mathItalic),
            "omicron": ("ο", .mathItalic), "pi": ("π", .mathItalic),
            "varpi": ("ϖ", .mathItalic), "rho": ("ρ", .mathItalic),
            "varrho": ("ϱ", .mathItalic), "sigma": ("σ", .mathItalic),
            "varsigma": ("ς", .mathItalic), "tau": ("τ", .mathItalic),
            "upsilon": ("υ", .mathItalic), "phi": ("ϕ", .mathItalic),
            "varphi": ("φ", .mathItalic), "chi": ("χ", .mathItalic),
            "psi": ("ψ", .mathItalic), "omega": ("ω", .mathItalic),
            "Gamma": ("Γ", .roman), "Delta": ("Δ", .roman),
            "Theta": ("Θ", .roman), "Lambda": ("Λ", .roman),
            "Xi": ("Ξ", .roman), "Pi": ("Π", .roman),
            "Sigma": ("Σ", .roman), "Upsilon": ("Υ", .roman),
            "Phi": ("Φ", .roman), "Psi": ("Ψ", .roman),
            "Omega": ("Ω", .roman)
        ]

        private static let commandSymbols: [String: (glyph: String, symbolClass: SymbolClass)] = [
            "le": ("≤", .relation), "leq": ("≤", .relation),
            "ge": ("≥", .relation), "geq": ("≥", .relation),
            "ne": ("≠", .relation), "neq": ("≠", .relation),
            "approx": ("≈", .relation), "sim": ("∼", .relation),
            "simeq": ("≃", .relation), "equiv": ("≡", .relation),
            "propto": ("∝", .relation), "in": ("∈", .relation),
            "notin": ("∉", .relation), "ni": ("∋", .relation),
            "subset": ("⊂", .relation), "subseteq": ("⊆", .relation),
            "supset": ("⊃", .relation), "supseteq": ("⊇", .relation),
            "perp": ("⟂", .relation), "parallel": ("∥", .relation),
            "to": ("→", .relation), "rightarrow": ("→", .relation),
            "leftarrow": ("←", .relation), "leftrightarrow": ("↔", .relation),
            "Rightarrow": ("⇒", .relation), "Leftarrow": ("⇐", .relation),
            "Leftrightarrow": ("⇔", .relation), "iff": ("⇔", .relation),
            "times": ("×", .binary), "cdot": ("·", .binary),
            "div": ("÷", .binary), "pm": ("±", .binary),
            "mp": ("∓", .binary), "cup": ("∪", .binary),
            "cap": ("∩", .binary), "wedge": ("∧", .binary),
            "land": ("∧", .binary), "vee": ("∨", .binary),
            "lor": ("∨", .binary), "oplus": ("⊕", .binary),
            "otimes": ("⊗", .binary), "setminus": ("∖", .binary),
            "infty": ("∞", .ordinary), "partial": ("∂", .ordinary),
            "nabla": ("∇", .ordinary), "forall": ("∀", .ordinary),
            "exists": ("∃", .ordinary), "neg": ("¬", .ordinary),
            "emptyset": ("∅", .ordinary), "angle": ("∠", .ordinary),
            "degree": ("°", .ordinary), "prime": ("′", .ordinary),
            "ell": ("ℓ", .ordinary), "Re": ("ℜ", .ordinary),
            "Im": ("ℑ", .ordinary), "aleph": ("ℵ", .ordinary),
            "ldots": ("…", .punctuation), "cdots": ("⋯", .punctuation),
            "vdots": ("⋮", .punctuation), "ddots": ("⋱", .punctuation)
        ]

        private static let delimiters: [String: String] = [
            "(": "(", ")": ")", "[": "[", "]": "]",
            "{": "{", "}": "}", "lbrace": "{", "rbrace": "}",
            "langle": "⟨", "rangle": "⟩", "vert": "|", "mid": "|",
            "Vert": "‖", "|": "‖", "lfloor": "⌊", "rfloor": "⌋",
            "lceil": "⌈", "rceil": "⌉", ".": ""
        ]
    }
}

// MARK: - Layout

private extension MathLabelRenderer {
    struct LayoutContext {
        var fontSize: CGFloat
        var forcedFace: FontFace?

        func scaled(by factor: CGFloat) -> LayoutContext {
            LayoutContext(fontSize: max(3, fontSize * factor),
                          forcedFace: forcedFace)
        }

        func forcing(_ face: FontFace) -> LayoutContext {
            LayoutContext(fontSize: fontSize, forcedFace: face)
        }
    }

    struct Box {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var commands: [DrawCommand]

        static let empty = Box(width: 0, ascent: 0, descent: 0, commands: [])
    }

    struct Placement {
        var box: Box
        var x: CGFloat
        var y: CGFloat
    }

    struct PreparedLayout {
        var size: CGSize
        var translation: CGPoint
        var commands: [DrawCommand]
    }

    enum DrawCommand {
        case glyph(text: String, font: UIFont, baseline: CGPoint)
        case rule(CGRect)
        case stroke(points: [CGPoint], width: CGFloat)

        func offsetBy(dx: CGFloat, dy: CGFloat) -> DrawCommand {
            switch self {
            case .glyph(let text, let font, let baseline):
                return .glyph(text: text,
                              font: font,
                              baseline: CGPoint(x: baseline.x + dx, y: baseline.y + dy))
            case .rule(let rect):
                return .rule(rect.offsetBy(dx: dx, dy: dy))
            case .stroke(let points, let width):
                return .stroke(points: points.map {
                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                }, width: width)
            }
        }

        var inkBounds: CGRect {
            switch self {
            case .glyph(let text, let font, let baseline):
                let line = Self.line(text: text, font: font, color: .black)
                var bounds = CTLineGetImageBounds(line, nil)
                if bounds.isNull || bounds.isEmpty {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    var leading: CGFloat = 0
                    let width = CGFloat(CTLineGetTypographicBounds(
                        line, &ascent, &descent, &leading
                    ))
                    bounds = CGRect(x: 0, y: -descent,
                                    width: width, height: ascent + descent)
                }
                return CGRect(
                    x: baseline.x + bounds.minX,
                    y: baseline.y - bounds.maxY,
                    width: bounds.width,
                    height: bounds.height
                )

            case .rule(let rect):
                return rect

            case .stroke(let points, let width):
                guard let first = points.first else { return .null }
                var minX = first.x
                var maxX = first.x
                var minY = first.y
                var maxY = first.y
                for point in points.dropFirst() {
                    minX = min(minX, point.x)
                    maxX = max(maxX, point.x)
                    minY = min(minY, point.y)
                    maxY = max(maxY, point.y)
                }
                return CGRect(x: minX, y: minY,
                              width: maxX - minX, height: maxY - minY)
                    .insetBy(dx: -width / 2, dy: -width / 2)
            }
        }

        func draw(in context: CGContext, color: UIColor) {
            switch self {
            case .glyph(let text, let font, let baseline):
                let line = Self.line(text: text, font: font, color: color)
                context.saveGState()
                context.translateBy(x: baseline.x, y: baseline.y)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()

            case .rule(let rect):
                context.setFillColor(color.cgColor)
                context.fill(rect)

            case .stroke(let points, let width):
                guard let first = points.first else { return }
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.beginPath()
                context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
        }

        static func line(text: String,
                         font: UIFont,
                         color: UIColor) -> CTLine {
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]
            )
            return CTLineCreateWithAttributedString(attributed)
        }
    }

    static func preparedLayout(latex: String, fontSize: CGFloat) -> PreparedLayout {
        let safeFontSize = fontSize.isFinite ? min(512, max(4, fontSize)) : 16
        var parser = Parser(normalizedLatex(latex))
        let node = parser.parse()
        let context = LayoutContext(fontSize: safeFontSize, forcedFace: nil)
        var box = layout(node, context: context)

        if box.commands.isEmpty && !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Final safety net for any future parser edge case.
            box = glyphBox(latex, face: .roman, context: context)
        }

        var inkBounds = CGRect.null
        for command in box.commands {
            let bounds = command.inkBounds
            guard bounds.width.isFinite, bounds.height.isFinite,
                  !bounds.isNull, !bounds.isInfinite else { continue }
            inkBounds = inkBounds.union(bounds)
        }

        guard !inkBounds.isNull, !inkBounds.isEmpty else {
            return PreparedLayout(size: .zero, translation: .zero,
                                  commands: box.commands)
        }

        let padding: CGFloat = 1
        let size = CGSize(width: ceil(inkBounds.width + padding * 2),
                          height: ceil(inkBounds.height + padding * 2))
        return PreparedLayout(
            size: size,
            translation: CGPoint(x: padding - inkBounds.minX,
                                 y: padding - inkBounds.minY),
            commands: box.commands
        )
    }

    static func normalizedLatex(_ latex: String) -> String {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        if trimmed.hasPrefix("$"), trimmed.hasSuffix("$"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        if trimmed.hasPrefix("\\("), trimmed.hasSuffix("\\)"), trimmed.count >= 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count >= 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        return latex
    }

    static func layout(_ node: MathNode, context: LayoutContext) -> Box {
        switch node {
        case .row(let nodes):
            var placements: [Placement] = []
            var x: CGFloat = 0
            for node in nodes {
                let child = layout(node, context: context)
                placements.append(Placement(box: child, x: x, y: 0))
                x += child.width
            }
            return assemble(placements, width: max(0, x))

        case .text(let text, let face):
            return glyphBox(text, face: context.forcedFace ?? face, context: context)

        case .symbol(let symbol, let symbolClass):
            let glyph = glyphBox(symbol, face: context.forcedFace ?? .roman,
                                 context: context)
            let padding = context.fontSize * symbolClass.sidePadding
            return assemble([Placement(box: glyph, x: padding, y: 0)],
                            width: glyph.width + padding * 2)

        case .space(let em):
            return Box(width: context.fontSize * em, ascent: 0,
                       descent: 0, commands: [])

        case .fraction(let numerator, let denominator):
            return fractionBox(numerator: numerator, denominator: denominator,
                               context: context)

        case .radical(let radicand, let index):
            return radicalBox(radicand: radicand, index: index, context: context)

        case .scripts(let base, let subscriptNode, let superscriptNode):
            return scriptsBox(base: base, subscriptNode: subscriptNode,
                              superscriptNode: superscriptNode, context: context)

        case .largeOperator(let kind):
            let scale: CGFloat = kind.usesStackedLimits ? 1.25 : 1.42
            return glyphBox(kind.glyph, face: .roman,
                            context: context.scaled(by: scale))

        case .delimited(let left, let body, let right):
            return delimiterBox(left: left, body: body, right: right,
                                context: context)

        case .styled(let face, let child):
            return layout(child, context: context.forcing(face))

        case .accent(let kind, let child):
            return accentBox(kind: kind, child: child, context: context)
        }
    }

    static func glyphBox(_ text: String,
                         face: FontFace,
                         context: LayoutContext) -> Box {
        guard !text.isEmpty else { return .empty }
        let font = font(face: face, size: context.fontSize)
        let line = DrawCommand.line(text: text, font: font, color: .black)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return Box(width: max(0, width), ascent: max(0, ascent),
                   descent: max(0, descent),
                   commands: [.glyph(text: text, font: font, baseline: .zero)])
    }

    static func font(face: FontFace, size: CGFloat) -> UIFont {
        switch face {
        case .roman:
            return UIFont.systemFont(ofSize: size)
        case .bold:
            return UIFont.boldSystemFont(ofSize: size)
        case .mathItalic:
            let base = UIFont.systemFont(ofSize: size)
            guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else {
                return base
            }
            return UIFont(descriptor: descriptor, size: size)
        }
    }

    static func fractionBox(numerator: MathNode,
                            denominator: MathNode,
                            context: LayoutContext) -> Box {
        let childContext = context.scaled(by: 0.84)
        let top = layout(numerator, context: childContext)
        let bottom = layout(denominator, context: childContext)
        let horizontalPadding = context.fontSize * 0.12
        let width = max(top.width, bottom.width) + horizontalPadding * 2
        let ruleThickness = max(0.8, context.fontSize * 0.052)
        let gap = max(1, context.fontSize * 0.10)
        let axis = -context.fontSize * 0.22
        let topBaseline = axis - ruleThickness / 2 - gap - top.descent
        let bottomBaseline = axis + ruleThickness / 2 + gap + bottom.ascent
        let placements = [
            Placement(box: top, x: (width - top.width) / 2, y: topBaseline),
            Placement(box: bottom, x: (width - bottom.width) / 2, y: bottomBaseline)
        ]
        var box = assemble(placements, width: width)
        box.commands.append(.rule(CGRect(x: 0, y: axis - ruleThickness / 2,
                                         width: width, height: ruleThickness)))
        box.ascent = max(box.ascent, -(axis - ruleThickness / 2))
        box.descent = max(box.descent, axis + ruleThickness / 2)
        return box
    }

    static func scriptsBox(base node: MathNode,
                           subscriptNode: MathNode?,
                           superscriptNode: MathNode?,
                           context: LayoutContext) -> Box {
        let base = layout(node, context: context)
        let scriptContext = context.scaled(by: 0.66)
        let subscriptBox = subscriptNode.map { layout($0, context: scriptContext) }
        let superscriptBox = superscriptNode.map { layout($0, context: scriptContext) }

        if case .largeOperator(let kind) = node, kind.usesStackedLimits {
            return stackedScriptsBox(base: base, subscriptBox: subscriptBox,
                                     superscriptBox: superscriptBox, context: context)
        }

        let scriptX = base.width + context.fontSize * 0.045
        var superscriptY: CGFloat?
        var subscriptY: CGFloat?

        if let superscriptBox {
            superscriptY = -max(base.ascent * 0.56,
                                context.fontSize * 0.34 + superscriptBox.descent)
        }
        if let subscriptBox {
            subscriptY = max(context.fontSize * 0.30,
                             base.descent * 0.55 + subscriptBox.ascent * 0.58)
        }

        if let superscriptBox, let subscriptBox,
           var upperY = superscriptY, var lowerY = subscriptY {
            let bottomOfUpper = upperY + superscriptBox.descent
            let topOfLower = lowerY - subscriptBox.ascent
            let minimumGap = context.fontSize * 0.08
            if topOfLower - bottomOfUpper < minimumGap {
                let correction = (minimumGap - (topOfLower - bottomOfUpper)) / 2
                upperY -= correction
                lowerY += correction
                superscriptY = upperY
                subscriptY = lowerY
            }
        }

        var placements = [Placement(box: base, x: 0, y: 0)]
        if let superscriptBox, let superscriptY {
            placements.append(Placement(box: superscriptBox, x: scriptX, y: superscriptY))
        }
        if let subscriptBox, let subscriptY {
            placements.append(Placement(box: subscriptBox, x: scriptX, y: subscriptY))
        }
        let scriptWidth = max(superscriptBox?.width ?? 0, subscriptBox?.width ?? 0)
        return assemble(placements, width: scriptX + scriptWidth)
    }

    static func stackedScriptsBox(base: Box,
                                  subscriptBox: Box?,
                                  superscriptBox: Box?,
                                  context: LayoutContext) -> Box {
        let width = max(base.width, subscriptBox?.width ?? 0,
                        superscriptBox?.width ?? 0)
        let gap = context.fontSize * 0.10
        var placements = [
            Placement(box: base, x: (width - base.width) / 2, y: 0)
        ]
        if let superscriptBox {
            let y = -base.ascent - gap - superscriptBox.descent
            placements.append(Placement(box: superscriptBox,
                                        x: (width - superscriptBox.width) / 2, y: y))
        }
        if let subscriptBox {
            let y = base.descent + gap + subscriptBox.ascent
            placements.append(Placement(box: subscriptBox,
                                        x: (width - subscriptBox.width) / 2, y: y))
        }
        return assemble(placements, width: width)
    }

    static func radicalBox(radicand: MathNode,
                           index: MathNode?,
                           context: LayoutContext) -> Box {
        let inner = layout(radicand, context: context)
        let desiredRootHeight = max(context.fontSize * 1.08,
                                    (inner.ascent + inner.descent) * 1.08)
        let rootContext = context.scaled(by: desiredRootHeight / context.fontSize)
        let root = glyphBox("√", face: .roman, context: rootContext)
        let indexBox = index.map { layout($0, context: context.scaled(by: 0.48)) }
        let indexLead = (indexBox?.width ?? 0) * 0.62
        let innerX = indexLead + root.width * 0.76
        let rootY = inner.descent - root.descent
        let overbarY = -inner.ascent - max(0.8, context.fontSize * 0.06)
        let ruleThickness = max(0.75, context.fontSize * 0.045)
        let trailing = context.fontSize * 0.08
        let width = innerX + inner.width + trailing

        var placements = [
            Placement(box: root, x: indexLead, y: rootY),
            Placement(box: inner, x: innerX, y: 0)
        ]
        if let indexBox {
            let y = -inner.ascent + indexBox.descent + context.fontSize * 0.08
            placements.append(Placement(box: indexBox, x: 0, y: y))
        }

        var box = assemble(placements, width: width)
        box.commands.append(.rule(CGRect(
            x: innerX - context.fontSize * 0.04,
            y: overbarY - ruleThickness,
            width: inner.width + trailing + context.fontSize * 0.04,
            height: ruleThickness
        )))
        box.ascent = max(box.ascent, -overbarY + ruleThickness)
        return box
    }

    static func delimiterBox(left: String,
                             body: MathNode,
                             right: String,
                             context: LayoutContext) -> Box {
        let inner = layout(body, context: context)
        let innerHeight = max(context.fontSize, inner.ascent + inner.descent)
        let delimiterScale = min(3, max(1, innerHeight / (context.fontSize * 0.86)))
        let delimiterContext = context.scaled(by: delimiterScale)
        let leftBox = glyphBox(left, face: .roman, context: delimiterContext)
        let rightBox = glyphBox(right, face: .roman, context: delimiterContext)
        let desiredCenter = (inner.descent - inner.ascent) / 2
        let leftCenter = (leftBox.descent - leftBox.ascent) / 2
        let rightCenter = (rightBox.descent - rightBox.ascent) / 2
        let gap = context.fontSize * 0.06
        let leftAdvance = left.isEmpty ? 0 : leftBox.width + gap
        let rightGap = right.isEmpty ? 0 : gap
        let width = leftAdvance + inner.width + rightGap + rightBox.width
        return assemble([
            Placement(box: leftBox, x: 0, y: desiredCenter - leftCenter),
            Placement(box: inner, x: leftAdvance, y: 0),
            Placement(box: rightBox, x: leftAdvance + inner.width + rightGap,
                      y: desiredCenter - rightCenter)
        ], width: width)
    }

    static func accentBox(kind: AccentKind,
                          child: MathNode,
                          context: LayoutContext) -> Box {
        let inner = layout(child, context: context)
        let gap = max(0.8, context.fontSize * 0.07)
        let lineWidth = max(0.75, context.fontSize * 0.045)
        let y = -inner.ascent - gap
        var box = inner

        switch kind {
        case .bar:
            let inset = inner.width * 0.14
            box.commands.append(.stroke(points: [
                CGPoint(x: inset, y: y), CGPoint(x: inner.width - inset, y: y)
            ], width: lineWidth))
            box.ascent = max(box.ascent, -y + lineWidth / 2)

        case .overline:
            box.commands.append(.stroke(points: [
                CGPoint(x: 0, y: y), CGPoint(x: inner.width, y: y)
            ], width: lineWidth))
            box.ascent = max(box.ascent, -y + lineWidth / 2)

        case .hat:
            let height = context.fontSize * 0.15
            box.commands.append(.stroke(points: [
                CGPoint(x: inner.width * 0.12, y: y),
                CGPoint(x: inner.width * 0.5, y: y - height),
                CGPoint(x: inner.width * 0.88, y: y)
            ], width: lineWidth))
            box.ascent = max(box.ascent, -y + height + lineWidth / 2)

        case .vector:
            let start = CGPoint(x: inner.width * 0.08, y: y)
            let end = CGPoint(x: inner.width * 0.92, y: y)
            let arrow = context.fontSize * 0.12
            box.commands.append(.stroke(points: [start, end], width: lineWidth))
            box.commands.append(.stroke(points: [
                CGPoint(x: end.x - arrow, y: end.y - arrow * 0.65),
                end,
                CGPoint(x: end.x - arrow, y: end.y + arrow * 0.65)
            ], width: lineWidth))
            box.ascent = max(box.ascent, -y + arrow + lineWidth / 2)

        case .dot:
            let dot = glyphBox("·", face: .roman, context: context.scaled(by: 0.72))
            let dotY = y - dot.descent
            return assemble([
                Placement(box: inner, x: 0, y: 0),
                Placement(box: dot, x: (inner.width - dot.width) / 2, y: dotY)
            ], width: inner.width)
        }
        return box
    }

    static func assemble(_ placements: [Placement], width: CGFloat) -> Box {
        var commands: [DrawCommand] = []
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        for placement in placements {
            top = min(top, placement.y - placement.box.ascent)
            bottom = max(bottom, placement.y + placement.box.descent)
            commands.append(contentsOf: placement.box.commands.map {
                $0.offsetBy(dx: placement.x, dy: placement.y)
            })
        }
        return Box(width: max(0, width), ascent: max(0, -top),
                   descent: max(0, bottom), commands: commands)
    }
}
