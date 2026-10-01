import SwiftUI

// MARK: - Drawing

/// Draws a parsed formula roughly like a math editor: italic letters,
/// stacked fractions, root signs and raised exponents.
struct MathRowView: View {
    let row: MathRow
    var size: CGFloat = 15

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { index, atom in
                MathAtomView(atom: atom, size: size, isPrefix: index == 0 || { if case .op = row[index - 1] { true } else { false } }())
            }
        }
        .fixedSize()
    }
}

private struct MathAtomView: View {
    let atom: MathAtom
    let size: CGFloat
    /// First in its row or right after an operator, so a − is a sign
    /// (−3) rather than a subtraction and gets no space around it.
    var isPrefix = false

    private func font(_ size: CGFloat, italic: Bool = false) -> Font {
        let font = Font.system(size: size, design: .serif)
        return italic ? font.italic() : font
    }

    var body: some View {
        switch atom {
        case .number(let text):
            Text(text).font(font(size))
        case .symbol(let text):
            Text(text).font(font(size, italic: true))
        case .function(let name):
            Text(name).font(font(size)).padding(.trailing, size * 0.15)
        case .text(let text):
            Text(text).font(font(size))
        case .unit(let unit):
            // Upright, a little apart from the number, as in Maple.
            Text(unit).font(font(size)).padding(.leading, size * 0.2)
        case .op(let op):
            let isSpaced = !["/", "!", "%"].contains(op) && !(isPrefix && (op == "−" || op == "+"))
            Text(op).font(font(size)).padding(.horizontal, isSpaced ? size * 0.22 : 0)
        case .fraction(let numerator, let denominator):
            VStack(spacing: size * 0.12) {
                MathRowView(row: numerator, size: size * 0.95)
                Rectangle().frame(height: max(1, size / 16))
                MathRowView(row: denominator, size: size * 0.95)
            }
            .fixedSize()
            .padding(.horizontal, size * 0.1)
        case .root(let radicand, let rootIndex):
            HStack(alignment: .bottom, spacing: 0) {
                if let rootIndex {
                    MathRowView(row: rootIndex, size: size * 0.55)
                        .padding(.bottom, size * 0.5)
                }
                Text("√").font(font(size * 1.15))
                MathRowView(row: radicand, size: size)
                    .padding(.top, size * 0.18)
                    .overlay(alignment: .top) {
                        Rectangle().frame(height: max(1, size / 16))
                    }
            }
            .fixedSize()
        case .fenced(let open, let inner, let close):
            let isTall = inner.contains { if case .fraction = $0 { true } else { false } }
            let bracketSize = isTall ? size * 1.9 : size
            HStack(spacing: 0) {
                if !open.isEmpty { Text(open).font(.system(size: bracketSize, weight: .ultraLight)) }
                MathRowView(row: inner, size: size)
                if !close.isEmpty { Text(close).font(.system(size: bracketSize, weight: .ultraLight)) }
            }
        case .scripts(let base, let sub, let sup):
            HStack(alignment: .center, spacing: size * 0.04) {
                MathAtomView(atom: base, size: size)
                VStack(alignment: .leading, spacing: 0) {
                    if let sup {
                        MathRowView(row: sup, size: size * 0.65)
                    }
                    if sup != nil && sub != nil { Spacer().frame(height: size * 0.3) }
                    if let sub {
                        MathRowView(row: sub, size: size * 0.65)
                    }
                }
                // A lone exponent sits high, a lone index sits low.
                .offset(y: sub == nil ? -size * 0.4 : (sup == nil ? size * 0.3 : 0))
            }
            .padding(.vertical, sub == nil && sup == nil ? 0 : size * 0.2)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        MathRowView(row: LatexParser.parse("\\frac{12}{R_1+R_2}\\cdot 10^{3} = 4{,}7"), size: 20)
        MathRowView(row: LatexParser.parse("\\sqrt{x^2+y^2} + \\sin^2 \\theta"), size: 20)
        MathRowView(row: LatexParser.parse("2\\pi \\left(\\frac{1}{3}\\right)"), size: 20)
        MathRowView(row: LatexParser.parse("1/(1/1+1/1) = 0,5"), size: 20)
    }
    .padding()
}
