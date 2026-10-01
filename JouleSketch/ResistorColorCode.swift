import SwiftUI

// MARK: - E series

/// The IEC 60063 series of standard resistor values.
nonisolated enum ESeries: Int, CaseIterable, Identifiable {
    case e6 = 6, e12 = 12, e24 = 24, e48 = 48, e96 = 96, e192 = 192

    var id: Int { rawValue }
    var name: String { "E\(rawValue)" }

    /// Significant digits of the values: 2 up to E24, 3 from E48.
    var digits: Int { rawValue <= 24 ? 2 : 3 }

    /// The tolerance in percent.
    var tolerance: Double {
        switch self {
        case .e6: 20
        case .e12: 10
        case .e24: 5
        case .e48: 2
        case .e96: 1
        case .e192: 0.5
        }
    }

    /// The values of one decade, as whole numbers with `digits` digits.
    var mantissas: [Int] {
        switch self {
        case .e6: [10, 15, 22, 33, 47, 68]
        case .e12: [10, 12, 15, 18, 22, 27, 33, 39, 47, 56, 68, 82]
        case .e24: [10, 11, 12, 13, 15, 16, 18, 20, 22, 24, 27, 30, 33, 36, 39, 43, 47, 51, 56, 62, 68, 75, 82, 91]
        // E96 is every other E192 value, and E48 every other E96 value.
        case .e48: Self.e192Values.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        case .e96: Self.e192Values.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        case .e192: Self.e192Values
        }
    }

    private static let e192Values = [
        100, 101, 102, 104, 105, 106, 107, 109, 110, 111, 113, 114, 115, 117, 118, 120,
        121, 123, 124, 126, 127, 129, 130, 132, 133, 135, 137, 138, 140, 142, 143, 145,
        147, 149, 150, 152, 154, 156, 158, 160, 162, 164, 165, 167, 169, 172, 174, 176,
        178, 180, 182, 184, 187, 189, 191, 193, 196, 198, 200, 203, 205, 208, 210, 213,
        215, 218, 221, 223, 226, 229, 232, 234, 237, 240, 243, 246, 249, 252, 255, 258,
        261, 264, 267, 271, 274, 277, 280, 284, 287, 291, 294, 298, 301, 305, 309, 312,
        316, 320, 324, 328, 332, 336, 340, 344, 348, 352, 357, 361, 365, 370, 374, 379,
        383, 388, 392, 397, 402, 407, 412, 417, 422, 427, 432, 437, 442, 448, 453, 459,
        464, 470, 475, 481, 487, 493, 499, 505, 511, 517, 523, 530, 536, 542, 549, 556,
        562, 569, 576, 583, 590, 597, 604, 612, 619, 626, 634, 642, 649, 657, 665, 673,
        681, 690, 698, 706, 715, 723, 732, 741, 750, 759, 768, 777, 787, 796, 806, 816,
        825, 835, 845, 856, 866, 876, 887, 898, 909, 920, 931, 942, 953, 965, 976, 988,
    ]

    /// The standard value in this series nearest to `resistance` (in ohms),
    /// measured as a ratio, so 4,7 kΩ is as close to 4,3 kΩ as 470 Ω is to 430 Ω.
    func nearest(to resistance: Double) -> StandardResistor? {
        guard resistance > 0, resistance.isFinite else { return nil }
        let decade = Int(floor(log10(resistance)))
        var best: (resistor: StandardResistor, distance: Double)?
        for exponent in (decade - digits)...(decade - digits + 2) {
            for mantissa in mantissas {
                let candidate = StandardResistor(series: self, mantissa: mantissa, exponent: exponent)
                let distance = abs(log(candidate.value / resistance))
                if distance < (best?.distance ?? .infinity) { best = (candidate, distance) }
            }
        }
        return best?.resistor
    }

    /// The order series are preferred in when they share the nearest value:
    /// the everyday 5 % and 10 % resistors first, precision ones last.
    private static let preference: [ESeries] = [.e24, .e12, .e6, .e96, .e48, .e192]

    /// The nearest standard value in any series. When several series have
    /// the same value, the most common kind of resistor is used.
    static func nearest(to resistance: Double) -> StandardResistor? {
        let candidates = preference.compactMap { $0.nearest(to: resistance) }
        guard let bestDistance = candidates.map({ abs(log($0.value / resistance)) }).min() else { return nil }
        return candidates.first { abs(log($0.value / resistance)) - bestDistance < 1e-9 }
    }
}

/// A standard resistor value: `mantissa · 10^exponent` ohms.
nonisolated struct StandardResistor: Hashable {
    let series: ESeries
    /// The significant digits, e.g. 47 or 475.
    let mantissa: Int
    let exponent: Int

    var value: Double { Double(mantissa) * pow(10, Double(exponent)) }

    /// How much the value differs from `resistance`, in percent.
    func deviation(from resistance: Double) -> Double {
        (value - resistance) / resistance * 100
    }

    /// The series that contain exactly this value.
    var seriesContainingValue: [ESeries] {
        ESeries.allCases.filter { $0.nearest(to: value).map { abs($0.value - value) < value * 1e-9 } ?? false }
    }

    /// The color bands: the digits, the multiplier and, except for E6, the tolerance.
    /// `nil` if the multiplier can't be shown with a color (below 0,01 or above 10⁹).
    var bands: [ColorBand]? {
        guard let multiplier = ColorBand.multiplier(exponent) else { return nil }
        let digits = String(mantissa).compactMap(\.wholeNumberValue).compactMap(ColorBand.digit)
        return digits + [multiplier] + (ColorBand.tolerance(series.tolerance).map { [$0] } ?? [])
    }
}

// MARK: - Color bands

/// One colored ring on a resistor.
nonisolated enum ColorBand: CaseIterable {
    case black, brown, red, orange, yellow, green, blue, violet, grey, white, gold, silver

    static func digit(_ digit: Int) -> ColorBand? {
        (0...9).contains(digit) ? allCases[digit] : nil
    }

    static func multiplier(_ exponent: Int) -> ColorBand? {
        switch exponent {
        case -2: .silver
        case -1: .gold
        case 0...9: allCases[exponent]
        default: nil
        }
    }

    /// The tolerance ring; E6 (±20 %) has none.
    static func tolerance(_ percent: Double) -> ColorBand? {
        switch percent {
        case 10: .silver
        case 5: .gold
        case 2: .red
        case 1: .brown
        case 0.5: .green
        default: nil
        }
    }

    var name: String {
        switch self {
        case .black: "sort"
        case .brown: "brun"
        case .red: "rød"
        case .orange: "orange"
        case .yellow: "gul"
        case .green: "grøn"
        case .blue: "blå"
        case .violet: "violet"
        case .grey: "grå"
        case .white: "hvid"
        case .gold: "guld"
        case .silver: "sølv"
        }
    }

    var color: Color {
        switch self {
        case .black: Color(white: 0.08)
        case .brown: Color(red: 0.45, green: 0.25, blue: 0.1)
        case .red: Color(red: 0.85, green: 0.1, blue: 0.1)
        case .orange: Color(red: 1, green: 0.5, blue: 0)
        case .yellow: Color(red: 1, green: 0.88, blue: 0)
        case .green: Color(red: 0.1, green: 0.6, blue: 0.2)
        case .blue: Color(red: 0.1, green: 0.3, blue: 0.9)
        case .violet: Color(red: 0.55, green: 0.2, blue: 0.75)
        case .grey: Color(white: 0.55)
        case .white: Color(white: 0.97)
        case .gold: Color(red: 0.83, green: 0.66, blue: 0.22)
        case .silver: Color(white: 0.78)
        }
    }
}

// MARK: - Views

/// A drawing of a resistor with its color bands.
struct ResistorBandsView: View {
    let bands: [ColorBand]
    /// 5-band resistors (E48 and up) are usually blue, 4-band ones beige.
    var isPrecision = false

    var body: some View {
        Canvas { context, size in
            let bodyRect = CGRect(x: size.width * 0.12, y: 1, width: size.width * 0.76, height: size.height - 2)
            var leads = Path()
            leads.move(to: CGPoint(x: 0, y: size.height / 2))
            leads.addLine(to: CGPoint(x: bodyRect.minX, y: size.height / 2))
            leads.move(to: CGPoint(x: bodyRect.maxX, y: size.height / 2))
            leads.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(leads, with: .color(.gray), lineWidth: 2)

            let body = Path(roundedRect: bodyRect, cornerRadius: bodyRect.height * 0.35)
            let bodyColor = isPrecision ? Color(red: 0.55, green: 0.72, blue: 0.88) : Color(red: 0.9, green: 0.8, blue: 0.62)
            context.fill(body, with: .color(bodyColor))

            // The value bands sit together; the tolerance band stands apart at the right.
            let hasTolerance = bands.count == (isPrecision ? 5 : 4)
            let valueBands = hasTolerance ? bands.dropLast() : bands[...]
            let bandWidth = bodyRect.width * 0.08
            let spacing = bodyRect.width * 0.13
            var clipped = context
            clipped.clip(to: body)
            for (index, band) in valueBands.enumerated() {
                let x = bodyRect.minX + bodyRect.width * 0.14 + CGFloat(index) * spacing
                drawBand(band, in: CGRect(x: x, y: bodyRect.minY, width: bandWidth, height: bodyRect.height), context: clipped)
            }
            if hasTolerance, let tolerance = bands.last {
                let x = bodyRect.maxX - bodyRect.width * 0.14 - bandWidth
                drawBand(tolerance, in: CGRect(x: x, y: bodyRect.minY, width: bandWidth, height: bodyRect.height), context: clipped)
            }
            context.stroke(body, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
        }
        .frame(width: 110, height: 26)
        .accessibilityElement()
        .accessibilityLabel("Farvekode: \(bands.map(\.name).formatted(.list(type: .and).locale(Locale(identifier: "da"))))")
    }

    private func drawBand(_ band: ColorBand, in rect: CGRect, context: GraphicsContext) {
        context.fill(Path(rect), with: .color(band.color))
        // Light bands get an outline so they show on the body.
        if band == .white || band == .silver || band == .yellow {
            context.stroke(Path(rect), with: .color(.black.opacity(0.2)), lineWidth: 0.5)
        }
    }
}

/// The nearest standard values to a resistance and their color codes,
/// shown in a resistor's properties.
struct ResistorColorCodeView: View {
    let resistance: Double

    var body: some View {
        if let nearest = ESeries.nearest(to: resistance) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Nærmeste standardværdi") {
                    Text(SIValue.format(nearest.value, unit: "Ω"))
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    if let bands = nearest.bands {
                        ResistorBandsView(bands: bands, isPrecision: nearest.series.digits == 3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nearest.seriesContainingValue.map(\.name).formatted(.list(type: .and).locale(Locale(identifier: "da"))))
                        Text(detail(for: nearest))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if let bands = nearest.bands {
                    Text(bands.map(\.name).joined(separator: " – "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Alle E-rækker") {
                ForEach(ESeries.allCases) { series in
                    if let resistor = series.nearest(to: resistance) {
                        seriesRow(resistor)
                    }
                }
            }
        }
    }

    private func detail(for resistor: StandardResistor) -> String {
        let deviation = resistor.deviation(from: resistance)
        let tolerance = "±\(resistor.series.tolerance.formatted()) %"
        guard abs(deviation) >= 0.005 else { return "\(tolerance) · præcis" }
        return "\(tolerance) · afviger \(deviation.formatted(.number.precision(.fractionLength(0...2)).sign(strategy: .always()))) %"
    }

    private func seriesRow(_ resistor: StandardResistor) -> some View {
        HStack(spacing: 10) {
            Text(resistor.series.name)
                .font(.caption.weight(.semibold))
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(SIValue.format(resistor.value, unit: "Ω"))
                    .monospacedDigit()
                Text(detail(for: resistor))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let bands = resistor.bands {
                ResistorBandsView(bands: bands, isPrecision: resistor.series.digits == 3)
            }
        }
    }
}

#Preview {
    Form {
        Section("Modstand") {
            ResistorColorCodeView(resistance: 4630)
        }
        Section("Præcis E24") {
            ResistorColorCodeView(resistance: 4700)
        }
    }
    .formStyle(.grouped)
    .frame(width: 380, height: 640)
}
