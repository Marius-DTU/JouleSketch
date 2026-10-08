#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The amplitudes and phases of voltages and currents at one frequency,
/// by the id of the voltage point or current arrow.
nonisolated struct PhasorValues {
    var frequency: Double
    var values: [UUID: Double] = [:]
    var phases: [UUID: Double] = [:]
}

/// Values the solver filled in, and what it couldn't work out.
nonisolated struct CircuitSolution {
    /// Computed values for components whose value is unknown.
    var componentValues: [UUID: Double] = [:]
    /// Computed voltages for voltage points whose value is unknown.
    var probeValues: [UUID: Double] = [:]
    /// Computed currents for current arrows whose value is unknown.
    var currentValues: [UUID: Double] = [:]
    /// The power absorbed by components with a power circle, by component id
    /// (P = U·I with U and I in the same direction; negative when delivered).
    var powerValues: [UUID: Double] = [:]
    /// Problems and missing information, for the "Beregning" report.
    var issues: [SolverIssue] = []
    /// `false` when the known values contradict each other.
    var isConsistent = true
    /// How many values were unknown, and how many of them were computed.
    var unknownCount = 0
    var solvedCount = 0
    /// Whether each diode conducts (`true`) or blocks (`false`).
    var diodeConducts: [UUID: Bool] = [:]
    /// Each diode's voltage Vd and current Id, from anode to cathode.
    var diodeValues: [UUID: (voltage: Double, current: Double)] = [:]
    /// The frequency in Hz when the circuit was solved with phasors (AC).
    var frequency: Double?
    /// In AC the phase in degrees of computed voltages and currents, by the
    /// id of the voltage point or current arrow. Their values are amplitudes.
    var phases: [UUID: Double] = [:]

    var isAC: Bool { frequency != nil }

    /// With a PWM generator the values above are averages, and this is the
    /// fundamental (first Fourier term), solved with phasors.
    var fundamental: PhasorValues?

    /// Parts with a signal generator and diodes, solved instant by instant
    /// over a period. Their values above are averages over the period; on
    /// the sheet `at(_:)` shows them as they are right now below
    /// `SignalTimeline.steadyFrequency`.
    var timelines: [SignalTimeline] = []
    /// The frequency of voltage points and currents that follow a signal
    /// generator with phasors (their values are amplitudes, or averages with
    /// the fundamental in `fundamental`), by id.
    var signalFrequency: [UUID: Double] = [:]
    /// The LEDs getting more than their rated current, with their (highest)
    /// current. They're marked on the sheet, also in study mode.
    var ledOvercurrent: [UUID: Double] = [:]

    /// The fundamental of a voltage point or current as text, to show after
    /// its average: "~ 0,4 V ∠ −80°". `nil` without PWM, and when the
    /// fundamental there is 0 (nothing of the signal gets through).
    func fundamentalText(_ id: UUID, unit: String) -> String? {
        guard let fundamental, let value = fundamental.values[id], abs(value) > 1e-9 else { return nil }
        return "~ " + SIValue.format(value, unit: unit, phase: fundamental.phases[id])
    }

    /// How brightly an LED is drawn at `time` (seconds), from 0 (off) to 1.
    /// In DC it follows its current, fully lit at the rated current. With a
    /// signal generator it blinks in step with the signal, or from
    /// `SignalTimeline.steadyFrequency` shines steadily at its average
    /// brightness over the period.
    func ledBrightness(_ id: UUID, at time: Double) -> Double {
        if let timeline = timelines.first(where: { $0.ids.contains(id) }) { return timeline.brightness(id, at: time) }
        guard diodeConducts[id] == true else { return 0 }
        return diodeValues[id].map { LEDModel.brightness(current: $0.current) } ?? 1
    }

    /// A computed voltage or current as shown after "=", the way `mode`
    /// says, at `time` (seconds). `nil` if it isn't known.
    func measurementText(_ id: UUID, mode: MeasureMode?, unit: String, at time: Double) -> String? {
        let mode = mode ?? .auto
        if mode == .auto {
            guard let value = probeValues[id] ?? currentValues[id] else { return nil }
            var text = SIValue.format(value, unit: unit, phase: phases[id])
            if let fundamental = fundamentalText(id, unit: unit) { text += "  " + fundamental }
            return text
        }
        guard let wave = measuredWave(id) else { return nil }
        switch mode {
        case .auto, .instant:
            // Too fast to follow: the RMS, which is what it looks like.
            if let frequency = wave.frequency, frequency >= SignalTimeline.steadyFrequency {
                return SIValue.format(wave.rms, unit: unit) + " " + MeasureMode.rms.suffix
            }
            // Rounding noise at a zero crossing is 0.
            let value = wave.value(at: time)
            let shown = abs(value) < 1e-9 * abs(wave.peak) ? 0 : value
            return SIValue.format(shown, unit: unit) + " " + mode.suffix
        case .average: return SIValue.format(wave.mean, unit: unit) + " " + mode.suffix
        case .rms: return SIValue.format(wave.rms, unit: unit) + " " + mode.suffix
        case .peak: return SIValue.format(wave.peak, unit: unit) + " " + mode.suffix
        }
    }

    /// How a computed voltage or current goes over a period.
    private func measuredWave(_ id: UUID) -> MeasuredWave? {
        if let timeline = timelines.first(where: { $0.ids.contains(id) }) {
            var pieces: [(start: Double, end: Double, value: Double)] = []
            for segment in timeline.segments {
                guard let value = segment.solution.probeValues[id] ?? segment.solution.currentValues[id] else { return nil }
                pieces.append((segment.start, segment.end, value))
            }
            return MeasuredWave(frequency: timeline.frequency, shape: .pieces(pieces))
        }
        guard let value = probeValues[id] ?? currentValues[id] else { return nil }
        if let fundamental, let amplitude = fundamental.values[id] {
            // A square wave: its average plus its fundamental (higher harmonics left out).
            return MeasuredWave(
                frequency: signalFrequency[id] ?? fundamental.frequency,
                shape: .sinusoid(offset: value, amplitude: amplitude, phase: fundamental.phases[id] ?? 0)
            )
        }
        if let frequency = signalFrequency[id] {
            return MeasuredWave(frequency: frequency, shape: .sinusoid(offset: 0, amplitude: value, phase: phases[id] ?? 0))
        }
        return MeasuredWave(frequency: nil, shape: .constant(value))
    }

    /// When the sheet next needs redrawing after `time` (seconds): when a
    /// timeline changes, or soon when a value is shown as it is right now
    /// (`continuous`).
    func nextRedraw(after time: Double, continuous: Bool) -> Double? {
        let change = nextChange(after: time)
        guard continuous else { return change }
        return min(change ?? .infinity, time + 1.0 / 30)
    }

    /// Whether the values or LEDs change visibly over time, so the sheet has
    /// to be redrawn as they do.
    var isAnimated: Bool { timelines.contains(where: \.isAnimated) }

    /// When the sheet next changes after `time` (seconds), for redrawing.
    func nextChange(after time: Double) -> Double? {
        timelines.compactMap { $0.nextChange(after: time) }.min()
    }

    /// The solution as it is at `time` (seconds), for drawing: in parts
    /// that change slowly enough to follow (below
    /// `SignalTimeline.steadyFrequency`) the values right now instead of
    /// their averages.
    func at(_ time: Double) -> CircuitSolution {
        var result = self
        for timeline in timelines where timeline.isLive {
            guard let instant = timeline.segment(at: time)?.solution else { continue }
            func replace<Value>(_ values: inout [UUID: Value], with new: [UUID: Value]) {
                for id in timeline.ids { values[id] = new[id] }
            }
            replace(&result.componentValues, with: instant.componentValues)
            replace(&result.probeValues, with: instant.probeValues)
            replace(&result.currentValues, with: instant.currentValues)
            replace(&result.powerValues, with: instant.powerValues)
            replace(&result.diodeConducts, with: instant.diodeConducts)
            replace(&result.diodeValues, with: instant.diodeValues)
        }
        return result
    }

    /// The solution without the values it found, for study mode. What's
    /// missing and whether everything can be computed is still there.
    var withoutValues: CircuitSolution {
        var solution = self
        solution.componentValues = [:]
        solution.probeValues = [:]
        solution.currentValues = [:]
        solution.powerValues = [:]
        solution.diodeConducts = [:]
        solution.diodeValues = [:]
        solution.phases = [:]
        solution.fundamental = nil
        solution.timelines = []
        solution.signalFrequency = [:]
        return solution
    }

    /// Whether every unknown value was computed and nothing is missing or contradictory.
    var isComplete: Bool {
        isConsistent && solvedCount == unknownCount && !issues.contains { $0.kind == .conflict || $0.kind == .missing }
    }

    /// Whether something works out but shouldn't be built that way, e.g. an
    /// LED that gets too much current.
    var hasWarnings: Bool { issues.contains { $0.kind == .warning } }
}

/// How a voltage or current goes over one period of a signal generator.
nonisolated struct MeasuredWave {
    enum Shape {
        /// It doesn't change (DC).
        case constant(Double)
        /// offset + amplitude · cos(2πft + phase°).
        case sinusoid(offset: Double, amplitude: Double, phase: Double)
        /// Constant in each piece of the period (fractions 0…1).
        case pieces([(start: Double, end: Double, value: Double)])
    }

    var frequency: Double?
    var shape: Shape

    /// The value at `time` (seconds).
    func value(at time: Double) -> Double {
        let periods = time * (frequency ?? 0)
        let x = periods - periods.rounded(.down)
        switch shape {
        case .constant(let value):
            return value
        case .sinusoid(let offset, let amplitude, let phase):
            return offset + amplitude * cos(2 * .pi * x + phase * .pi / 180)
        case .pieces(let pieces):
            return (pieces.first { x < $0.end } ?? pieces.last)?.value ?? 0
        }
    }

    /// The average over a period.
    var mean: Double {
        switch shape {
        case .constant(let value): value
        case .sinusoid(let offset, _, _): offset
        case .pieces(let pieces): pieces.reduce(0) { $0 + $1.value * ($1.end - $1.start) }
        }
    }

    /// The root mean square over a period.
    var rms: Double {
        switch shape {
        case .constant(let value): abs(value)
        case .sinusoid(let offset, let amplitude, _): sqrt(offset * offset + amplitude * amplitude / 2)
        case .pieces(let pieces): sqrt(pieces.reduce(0) { $0 + $1.value * $1.value * ($1.end - $1.start) })
        }
    }

    /// The value furthest from 0 during a period, with its sign.
    var peak: Double {
        switch shape {
        case .constant(let value): value
        case .sinusoid(let offset, let amplitude, _): offset < 0 ? offset - abs(amplitude) : offset + abs(amplitude)
        case .pieces(let pieces): pieces.map(\.value).max { abs($0) < abs($1) } ?? 0
        }
    }
}

/// A part of a circuit with a signal generator and diodes, solved instant
/// by instant over one period: the period is cut where a square wave
/// switches (and into 24 steps with a sine), and each piece is solved as DC
/// with the generators at their value in its middle. Capacitors and
/// inductors are DC in each instant (open and shorted).
nonisolated struct SignalTimeline {
    /// From this frequency (Hz) the sheet shows averages over the period and
    /// LEDs shine steadily, as bright as they are on average. Faster changes
    /// can't be shown on a 60 Hz screen and look steady to the eye anyway.
    static let steadyFrequency = 20.0

    /// A stretch of the period, from `start` to `end` (fractions 0…1), with
    /// the part's solution then and how bright each LED is (0…1, unlit ones
    /// left out).
    struct Segment {
        var start: Double
        var end: Double
        var solution: CircuitSolution
        var brightness: [UUID: Double]
    }

    var frequency: Double
    var segments: [Segment]
    /// The ids of the part's components, voltage points and currents.
    var ids: Set<UUID>
    /// Each LED's brightness averaged over the period (0…1).
    var averageBrightness: [UUID: Double]

    /// Whether the sheet follows the instants (slow enough to see).
    var isLive: Bool { frequency < Self.steadyFrequency }

    /// Whether something visibly changes over the period.
    var isAnimated: Bool { isLive && segments.count > 1 }

    /// The piece of the period at `time` (seconds).
    func segment(at time: Double) -> Segment? {
        let x = time * frequency - (time * frequency).rounded(.down)
        return segments.first { x < $0.end } ?? segments.last
    }

    /// How brightly an LED is drawn at `time` (seconds), from 0 to 1.
    func brightness(_ id: UUID, at time: Double) -> Double {
        guard isLive else { return averageBrightness[id] ?? 0 }
        return segment(at: time)?.brightness[id] ?? 0
    }

    /// When the next piece of the period begins after `time` (seconds).
    func nextChange(after time: Double) -> Double? {
        guard isAnimated else { return nil }
        let periods = time * frequency
        let whole = periods.rounded(.down)
        let x = periods - whole
        let next = segments.first(where: { $0.end > x + 1e-9 })?.end ?? 1
        return (whole + next) / frequency
    }
}

nonisolated struct SolverIssue: Identifiable, Error {
    enum Kind {
        /// The known values contradict each other.
        case conflict
        /// A value can't be computed yet.
        case missing
        /// Something the user should know, e.g. there's no ground.
        case notice
        /// The values can be worked out, but the circuit would break in real
        /// life, e.g. an LED with too much current.
        case warning
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String
}

/// Solves a circuit with Kirchhoff's laws and Ohm's law.
///
/// Every node voltage, every component current and every unknown component
/// value is a variable. The equations are Ohm's law for resistors, the source
/// equations, Kirchhoff's current law in each node, and every value the user
/// has entered. Unknown resistances make the system nonlinear, so it's solved
/// with Levenberg–Marquardt. A quantity counts as computed only if it's
/// uniquely determined, which is checked with the rank of the Jacobian.
///
/// Diodes either conduct, with their forward voltage across them (an LED
/// also has its internal resistance, see `LEDModel`), or block, with no
/// current. Starting with all of them conducting, the circuit is
/// solved and the diode that fits its state worst (a conducting diode with
/// current flowing backwards, or a blocking one with more than its forward
/// voltage across it) is switched, until every diode fits.
///
/// A circuit with a signal generator is solved with phasors at its
/// frequency: every voltage and current has a real and an imaginary part,
/// capacitors and inductors have their impedance, and the other sources are
/// phasors with phase 0. Without one it's DC, where a capacitor is open and
/// an inductor a short.
nonisolated enum CircuitSolver {
    /// `diodeGuess` is the diodes to try conducting first (all by default),
    /// e.g. the ones that conducted a moment before.
    static func solve(_ circuit: Circuit, diodeGuess: Set<UUID>? = nil) -> CircuitSolution {
        // Switches are wires or nothing; the editor resolves held-down buttons.
        // A generator at 0 Hz is DC.
        let zeroFrequency = circuit.components.filter(\.isZeroFrequency)
        if !zeroFrequency.isEmpty {
            var solution = solve(circuit.resolvingZeroFrequencyGenerators())
            solution.issues += zeroFrequency.map { generator in
                SolverIssue(
                    kind: .notice,
                    title: "\(generator.name) er sat til 0 Hz",
                    detail: "Ved 0 Hz ændrer signalet sig ikke, så \(generator.name) regnes som en jævnspændingskilde med den værdi, signalet starter på (for en sinus A · cos φ, for en firkant høj spænding)."
                )
            }
            return solution
        }
        // With a signal generator, the parts it isn't joined to stay DC: each
        // part is solved on its own.
        if circuit.isAC {
            let parts = circuit.resolvingSwitches().separateParts()
            if parts.count > 1 { return merged(parts.map { solve($0) }, hasGround: !circuit.grounds.isEmpty) }
        }
        let (circuit, lowSide) = resolvingLowSideOutputs(circuit.resolvingSwitches())
        if !lowSide.isEmpty {
            var solution = solve(circuit)
            solution.issues += lowSide.map(\.issue)
            return solution
        }
        // Phasors can't make a diode conduct one way only, so with diodes the
        // signal is followed instant by instant.
        if circuit.isAC, circuit.components.contains(where: { $0.kind.isDiode }),
           let solution = solveTimeDomain(circuit) {
            return solution
        }
        if circuit.usesFourier { return solveFourier(circuit) }
        if circuit.isAC { return solveAC(circuit) }
        let diodes = circuit.components.filter { $0.kind.isDiode }

        /// Solves with the given diodes conducting; also returns the diode
        /// that fits its state worst, if any.
        func attempt(_ conducting: Set<UUID>) -> (solution: CircuitSolution, worst: UUID?) {
            var model = Model(circuit: circuit, conducting: conducting)
            var solution = model.solve()
            for diode in diodes { solution.diodeConducts[diode.id] = conducting.contains(diode.id) }
            return (solution, model.worstDiodeViolation())
        }

        // Switch the worst-fitting diode until all fit.
        var conducting = diodeGuess.map { $0.intersection(diodes.map(\.id)) } ?? Set(diodes.map(\.id))
        var tried = Set<Set<UUID>>()
        var first: CircuitSolution?
        for _ in 0..<(4 * diodes.count + 1) {
            guard tried.insert(conducting).inserted else { break }
            let (solution, worst) = attempt(conducting)
            first = first ?? solution
            // Contradicting values may come from a wrong guess; search below.
            guard solution.isConsistent else { break }
            guard let worst else { return solution }
            if conducting.contains(worst) { conducting.remove(worst) } else { conducting.insert(worst) }
        }

        // Otherwise try every combination, with as many conducting as possible first.
        if diodes.count <= 8 {
            let masks = (0..<(1 << diodes.count)).sorted { $0.nonzeroBitCount < $1.nonzeroBitCount }
            for mask in masks {
                let state = Set(diodes.indices.filter { mask & (1 << $0) == 0 }.map { diodes[$0].id })
                guard tried.insert(state).inserted else { continue }
                let (solution, worst) = attempt(state)
                if solution.isConsistent, worst == nil { return solution }
            }
        }

        guard var solution = first else { return CircuitSolution() }
        if solution.isConsistent {
            solution.issues.append(SolverIssue(
                kind: .conflict,
                title: "Dioderne passer ikke sammen",
                detail: "Der er ingen kombination af ledende og spærrende dioder, der passer med resten af kredsløbet. Tjek dioderne og deres retning."
            ))
            solution.isConsistent = false
        }
        return solution
    }

    /// The solutions of separate parts of a circuit as one. A part without
    /// ground of its own doesn't report it when the circuit has one.
    private static func merged(_ parts: [CircuitSolution], hasGround: Bool) -> CircuitSolution {
        var result = CircuitSolution()
        var titles = Set<String>()
        for part in parts {
            result.componentValues.merge(part.componentValues) { a, _ in a }
            result.probeValues.merge(part.probeValues) { a, _ in a }
            result.currentValues.merge(part.currentValues) { a, _ in a }
            result.powerValues.merge(part.powerValues) { a, _ in a }
            result.diodeConducts.merge(part.diodeConducts) { a, _ in a }
            result.diodeValues.merge(part.diodeValues) { a, _ in a }
            result.ledOvercurrent.merge(part.ledOvercurrent) { a, _ in a }
            result.timelines += part.timelines
            result.signalFrequency.merge(part.signalFrequency) { a, _ in a }
            result.phases.merge(part.phases) { a, _ in a }
            result.isConsistent = result.isConsistent && part.isConsistent
            result.unknownCount += part.unknownCount
            result.solvedCount += part.solvedCount
            result.frequency = result.frequency ?? part.frequency
            if let fundamental = part.fundamental {
                var values = result.fundamental ?? PhasorValues(frequency: fundamental.frequency)
                values.values.merge(fundamental.values) { a, _ in a }
                values.phases.merge(fundamental.phases) { a, _ in a }
                result.fundamental = values
            }
            for issue in part.issues where titles.insert(issue.title).inserted {
                if hasGround, issue.title == "Der mangler et stel (0 V)" { continue }
                result.issues.append(issue)
            }
        }
        return result
    }

    /// A low-side output (LSO) as the square wave it gives: between 0 V
    /// (pulling down) and the voltage across it while it's open, found with
    /// it taken out of the circuit (DC: capacitors open, inductors shorted).
    /// With only resistors this is exact; with capacitors or inductors the
    /// fundamental is an approximation, since an open output carries no current.
    struct LowSideOutput {
        let name: String
        /// The voltage across the open output, + to −; `nil` if nothing sets it.
        let openVoltage: Double?

        var issue: SolverIssue {
            guard let openVoltage else {
                return SolverIssue(
                    kind: .missing,
                    title: "LSO-udgangen \(name) trækkes ikke op",
                    detail: "\(name) er sat til 0 V og virker som en low-side udgang (LSO), der kun kan trække ned. Der skal noget til at trække den op, når den er åben, fx en pull-up-modstand til forsyningen."
                )
            }
            return SolverIssue(
                kind: .notice,
                title: "\(name) er en low-side udgang (LSO)",
                detail: "\(name) er sat til 0 V, så den virker som en open-drain-udgang: åben (høj) i duty cyclen og trukket ned til 0 V resten af perioden. Åben er spændingen over den \(SIValue.format(openVoltage, unit: "V")), så den regnes som et firkantsignal mellem 0 V og \(SIValue.format(openVoltage, unit: "V")). Med kondensatorer eller spoler er grundtonen en tilnærmelse."
            )
        }
    }

    /// The circuit with each low-side output replaced by a square wave from
    /// 0 V to its open voltage, and what was found for each.
    static func resolvingLowSideOutputs(_ circuit: Circuit) -> (Circuit, [LowSideOutput]) {
        let outputs = circuit.components.filter(\.isLowSideOutput)
        guard !outputs.isEmpty else { return (circuit, []) }
        // Open: all low-side outputs taken out, the rest at its average.
        var open = circuit
        open.components.removeAll(where: \.isLowSideOutput)
        open = open.averageCircuit()
        open.probes = []
        open.currents = []
        open.components.indices.forEach { open.components[$0].showsPower = nil }
        var drops: [UUID: UUID] = [:]
        for output in outputs {
            let probe = Probe(position: output.end, name: "LSO_\(output.name)", negative: output.start)
            drops[output.id] = probe.id
            open.probes.append(probe)
        }
        let solution = solve(open)
        var result = circuit
        var found: [LowSideOutput] = []
        for output in outputs {
            // 0 V open is nothing pulling it up (and would make it an LSO again).
            let voltage = drops[output.id].flatMap { solution.probeValues[$0] }.flatMap { abs($0) > 1e-12 ? $0 : nil }
            found.append(LowSideOutput(name: output.name, openVoltage: voltage))
            if let index = result.components.firstIndex(where: { $0.id == output.id }) {
                // Unknown if nothing pulls it up.
                result.components[index].value = voltage
            }
        }
        return (result, found)
    }

    /// Solves a circuit with a non-sine signal generator (e.g. a square wave)
    /// in two parts: the averages (DC, each generator as its waveform's
    /// average) and the fundamental (phasors at the generator's frequency,
    /// the other sources off). The power is the sum of the two, leaving out
    /// the higher harmonics.
    private static func solveFourier(_ circuit: Circuit) -> CircuitSolution {
        var solution = solve(circuit.averageCircuit())
        // An unknown generator value was found as its average.
        for generator in circuit.components where generator.kind == .signalGenerator && generator.value == nil {
            guard let average = solution.componentValues[generator.id] else { continue }
            let perUnit = generator.signalWaveform.average(1, duty: generator.dutyFraction)
            solution.componentValues[generator.id] = perUnit != 0 ? average / perUnit : nil
        }
        let fundamentalCircuit = circuit.fundamentalCircuit(componentValues: solution.componentValues)
        let fundamental = solveAC(fundamentalCircuit)
        if let frequency = fundamental.frequency {
            var values = PhasorValues(frequency: frequency)
            for (id, value) in fundamental.probeValues { values.values[id] = value }
            for (id, value) in fundamental.currentValues { values.values[id] = value }
            values.phases = fundamental.phases
            solution.fundamental = values
            for id in values.values.keys { solution.signalFrequency[id] = frequency }
            for (id, power) in fundamental.powerValues {
                solution.powerValues[id] = solution.powerValues[id].map { $0 + power }
            }
        }
        // What's missing for the fundamental, unless the averages say it already.
        let titles = Set(solution.issues.map(\.title))
        for issue in fundamental.issues where issue.kind != .notice && !titles.contains(issue.title) {
            solution.issues.append(SolverIssue(kind: issue.kind, title: "Grundtone: \(issue.title)", detail: issue.detail))
        }
        solution.issues.append(SolverIssue(
            kind: .notice,
            title: "Signalet regnes som middelværdi og grundtone",
            detail: "Værdierne er middelværdier (fx firkant = D · højspænding, kondensatorer afbrudt og spoler kortsluttet). Efter ~ står grundtonen: amplitude og fase af signalets første Fourier-led (for en firkant (2A/π)·sin(πD)) ved generatorens frekvens. Effekten er middelværdiens plus grundtonens; de højere harmoniske er udeladt."
        ))
        return solution
    }

    /// Solves a circuit with signal generators and diodes instant by instant
    /// over a period (`SignalTimeline`). The values are averages over the
    /// period, with the instants in `timelines`. `nil` when a generator's
    /// value or the frequency is missing; then it's solved with phasors.
    private static func solveTimeDomain(_ circuit: Circuit) -> CircuitSolution? {
        let generators = circuit.components.filter { $0.kind == .signalGenerator }
        guard !generators.isEmpty, generators.allSatisfy({ $0.value != nil }),
              case .success(let frequency) = circuit.acFrequency() else { return nil }

        func fraction(_ x: Double) -> Double { x - x.rounded(.down) }
        var cuts: Set<Double> = [0, 1]
        for generator in generators {
            let shift = (generator.phase ?? 0) / 360
            switch generator.signalWaveform {
            case .sine:
                for step in 0..<24 { cuts.insert(Double(step) / 24) }
            case .square:
                cuts.insert(fraction(-shift))
                cuts.insert(fraction(generator.dutyFraction - shift))
            }
        }
        let sorted = cuts.sorted()
        let leds = circuit.components.filter { $0.kind == .led }

        // Pieces where the generators have the same values are solved once,
        // each starting from the diodes that conducted in the piece before.
        var solved: [[Double]: CircuitSolution] = [:]
        var segments: [SignalTimeline.Segment] = []
        var guess: Set<UUID>?
        for (start, end) in zip(sorted, sorted.dropFirst()) where end - start > 1e-9 {
            let middle = (start + end) / 2
            var instant = circuit
            var values: [Double] = []
            for index in instant.components.indices where instant.components[index].kind == .signalGenerator {
                let generator = instant.components[index]
                let value = generator.signalWaveform.value(
                    generator.value ?? 0, duty: generator.dutyFraction, at: middle + (generator.phase ?? 0) / 360
                )
                values.append(value)
                instant.components[index].kind = .voltageSource
                instant.components[index].value = value
            }
            let solution = solved[values] ?? solve(instant, diodeGuess: guess)
            solved[values] = solution
            guess = Set(solution.diodeConducts.filter(\.value).keys)
            var brightness: [UUID: Double] = [:]
            for led in leds {
                let value = solution.ledBrightness(led.id, at: 0)
                if value > 0 { brightness[led.id] = value }
            }
            segments.append(SignalTimeline.Segment(start: start, end: end, solution: solution, brightness: brightness))
        }
        guard let first = segments.first?.solution else { return nil }

        // Averages over the period, of what's known in every instant.
        func average(_ values: (CircuitSolution) -> [UUID: Double]) -> [UUID: Double] {
            var result = values(first)
            for segment in segments.dropFirst() {
                let these = values(segment.solution)
                result = result.filter { these[$0.key] != nil }
            }
            for id in result.keys {
                result[id] = segments.reduce(0) { $0 + (values($1.solution)[id] ?? 0) * ($1.end - $1.start) }
            }
            return result
        }
        var result = CircuitSolution()
        result.componentValues = average(\.componentValues)
        result.probeValues = average(\.probeValues)
        result.currentValues = average(\.currentValues)
        result.powerValues = average(\.powerValues)
        result.unknownCount = first.unknownCount
        result.solvedCount = segments.map(\.solution.solvedCount).min() ?? 0
        result.isConsistent = segments.allSatisfy(\.solution.isConsistent)
        var averageBrightness: [UUID: Double] = [:]
        for segment in segments {
            let length = segment.end - segment.start
            for (id, conducts) in segment.solution.diodeConducts where conducts { result.diodeConducts[id] = true }
            for (id, value) in segment.solution.diodeValues {
                let sum = result.diodeValues[id] ?? (0, 0)
                result.diodeValues[id] = (sum.voltage + value.voltage * length, sum.current + value.current * length)
            }
            for (id, value) in segment.brightness { averageBrightness[id, default: 0] += value * length }
            for (id, current) in segment.solution.ledOvercurrent {
                result.ledOvercurrent[id] = max(result.ledOvercurrent[id] ?? 0, current)
            }
        }
        for diode in circuit.components where diode.kind.isDiode && result.diodeConducts[diode.id] == nil {
            result.diodeConducts[diode.id] = false
        }

        // Each problem once; an LED's warning with its highest current.
        let names = Dictionary(circuit.components.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let overcurrentTitles = Set(result.ledOvercurrent.keys.compactMap { names[$0] }.map { LEDModel.overcurrentIssue(name: $0, current: 0).title })
        var titles = overcurrentTitles
        for segment in segments {
            for issue in segment.solution.issues where titles.insert(issue.title).inserted { result.issues.append(issue) }
        }
        for (id, current) in result.ledOvercurrent.sorted(by: { (names[$0.key] ?? "") < (names[$1.key] ?? "") }) {
            result.issues.append(LEDModel.overcurrentIssue(name: names[id] ?? "", current: current))
        }
        result.issues.append(SolverIssue(
            kind: .notice,
            title: "Signalet følges øjeblik for øjeblik",
            detail: "Med dioder og en signalgenerator regnes kredsløbet i hvert øjeblik af perioden med generatorens værdi lige da (kondensatorer afbrudt og spoler kortsluttet i hvert øjeblik). Under \(SIValue.format(SignalTimeline.steadyFrequency, unit: "Hz")) viser tegningen værdierne, som de er lige nu; derover og i editoren er de middelværdier over perioden."
        ))

        var ids = Set(circuit.components.map(\.id))
        ids.formUnion(circuit.probes.map(\.id))
        ids.formUnion(circuit.currents.map(\.id))
        result.timelines = [SignalTimeline(frequency: frequency, segments: segments, ids: ids, averageBrightness: averageBrightness)]
        return result
    }

    /// Solves a circuit with signal generators with phasors.
    private static func solveAC(_ circuit: Circuit) -> CircuitSolution {
        let frequency: Double
        switch circuit.acFrequency() {
        case .success(let value):
            frequency = value
        case .failure(let issue):
            var solution = CircuitSolution()
            solution.unknownCount = circuit.components.filter { $0.value == nil }.count
                + circuit.probes.filter { $0.value == nil }.count + circuit.currents.filter { $0.value == nil }.count
            solution.issues = [issue]
            solution.isConsistent = issue.kind != .conflict
            return solution
        }
        var model = Model(circuit: circuit, omega: 2 * .pi * frequency)
        var solution = model.solve()
        solution.frequency = frequency
        for id in Array(solution.probeValues.keys) + Array(solution.currentValues.keys) {
            solution.signalFrequency[id] = frequency
        }
        if circuit.components.contains(where: { $0.kind.isDiode }) {
            solution.issues.append(SolverIssue(
                kind: .notice,
                title: "Dioderne regnes som afbrudt",
                detail: "Med fasorer (AC) kan en diode ikke lede kun den ene vej, så dioderne fører ingen strøm i beregningen."
            ))
        }
        return solution
    }
}

/// The value of an equivalent resistance (Req), or why it can't be found.
nonisolated enum EquivalentResult: Equatable {
    /// The resistance, and the resistors carrying current between the two points.
    case value(Double, resistors: Set<UUID>)
    /// In AC with capacitors or inductors: the impedance, and the components
    /// carrying current between the two points.
    case impedance(Complex, resistors: Set<UUID>)
    /// One of the points isn't on the circuit.
    case notOnCircuit
    /// No path of resistors joins the two points.
    case notConnected
    /// These resistors have neither a known nor a computed value.
    case unknownValues([String])
    /// Controlled sources or diodes take part, and a control is missing or
    /// there's no single answer.
    case dependentSources([String])

    /// The resistors (and capacitors and inductors) making up the Req.
    var resistors: Set<UUID> {
        switch self {
        case .value(_, let resistors), .impedance(_, let resistors): resistors
        default: []
        }
    }

    /// Whether there's a resistance or impedance.
    var hasValue: Bool {
        switch self {
        case .value, .impedance: true
        default: false
        }
    }

    /// The value as text: "1,5 kΩ", or "188 Ω ∠ −58°" for an impedance.
    var formatted: String {
        switch self {
        case .value(let resistance, _): SIValue.format(resistance, unit: "Ω")
        case .impedance(let impedance, _): SIValue.format(impedance: impedance)
        default: SIValue.format(nil, unit: "Ω")
        }
    }

    /// A real impedance is a resistance.
    fileprivate static func of(_ impedance: Complex, resistors: Set<UUID>) -> EquivalentResult {
        impedance.isReal ? .value(impedance.re, resistors: resistors) : .impedance(impedance, resistors: resistors)
    }
}

nonisolated extension CircuitSolver {
    /// The resistance seen between two points of the circuit with the
    /// independent sources turned off: voltage sources become a short
    /// circuit and current sources an open circuit. A source connected right
    /// between the two points is removed instead. Uses the known and
    /// computed resistor values. Works by sending 1 A in at `a` and out at
    /// `b`; Req is then the voltage between them, and the resistors
    /// carrying some of that current are the ones Req is made of.
    ///
    /// In AC capacitors and inductors take part with their impedance, so the
    /// result is an impedance (Zeq). In DC a capacitor is open and an
    /// inductor a short.
    static func equivalentResistance(
        between pointA: GridPoint, and pointB: GridPoint, in circuit: Circuit, netlist: Netlist, solution: CircuitSolution
    ) -> EquivalentResult {
        guard let nodeA = netlist.node(at: pointA),
              let nodeB = netlist.node(at: pointB) else { return .notOnCircuit }
        let omega = solution.frequency.map { 2 * .pi * $0 }

        // Short circuits (voltage sources and 0 Ω) join their two nodes into one.
        var parent: [Int: Int] = [:]
        func find(_ n: Int) -> Int {
            var root = n
            while let next = parent[root], next != root { root = next }
            return root
        }
        func join(_ p: Int, _ q: Int) {
            let rootP = find(p), rootQ = find(q)
            if rootP != rootQ { parent[rootP] = rootQ }
        }
        func node(_ point: GridPoint) -> Int { netlist.nodeOf[point, default: -1] }

        /// Resistors, and in AC capacitors and inductors, with their impedance.
        var resistors: [(id: UUID, name: String, p: Int, q: Int, z: Complex?)] = []
        var dependent: [(name: String, p: Int, q: Int)] = []
        var voltageSources: [(p: Int, q: Int)] = []
        for component in circuit.components {
            let p = node(component.start), q = node(component.end)
            switch component.kind {
            case .resistor:
                let r = component.value ?? solution.componentValues[component.id]
                if r == 0 { join(p, q) }
                resistors.append((component.id, component.name, p, q, r.map { Complex($0) }))
            case .capacitor, .inductor:
                let value = component.value ?? solution.componentValues[component.id]
                if omega == nil {
                    // DC: a capacitor is open, an inductor a short.
                    if component.kind == .inductor { join(p, q) }
                } else if let value {
                    let z = component.kind.impedance(value, omega: omega)
                    if z.magnitude == 0 { join(p, q) }
                    if z.magnitude.isFinite { resistors.append((component.id, component.name, p, q, z)) }
                } else {
                    resistors.append((component.id, component.name, p, q, nil))
                }
            case .voltageSource, .signalGenerator: voltageSources.append((p, q))
            case .currentSource, .toggleSwitch, .pushButton: break
            case .vcvs, .ccvs, .vccs, .cccs, .diode, .led: dependent.append((component.name, p, q))
            }
        }
        // A source sitting right between the two points (also through 0 Ω
        // resistors) is the one Req is seen from, so it's taken out instead
        // of shorted. Decided before any source is shorted.
        let ends = Set([find(nodeA), find(nodeB)])
        let shorted = voltageSources.filter { Set([find($0.p), find($0.q)]) != ends }
        for source in shorted { join(source.p, source.q) }
        let a = find(nodeA)
        let b = find(nodeB)
        if a == b { return .value(0, resistors: []) }

        // Only what lies on some path between a and b matters; branches
        // hanging off a single node carry none of the test current. Those
        // are the edges in the same biconnected block as a virtual edge a–b.
        enum EdgeKind { case resistor(Int), dependent(Int), virtual }
        var edges: [(p: Int, q: Int, kind: EdgeKind)] = [(a, b, .virtual)]
        for (i, resistor) in resistors.enumerated() where find(resistor.p) != find(resistor.q) {
            edges.append((find(resistor.p), find(resistor.q), .resistor(i)))
        }
        for (i, source) in dependent.enumerated() where find(source.p) != find(source.q) {
            edges.append((find(source.p), find(source.q), .dependent(i)))
        }
        var adjacency: [Int: [(edge: Int, to: Int)]] = [:]
        for (i, edge) in edges.enumerated() {
            adjacency[edge.p, default: []].append((i, edge.q))
            adjacency[edge.q, default: []].append((i, edge.p))
        }
        // Tarjan's algorithm for biconnected blocks, keeping the block of edge 0.
        var discovered: [Int: Int] = [:]
        var low: [Int: Int] = [:]
        var edgeStack: [Int] = []
        var block = Set<Int>()
        func visit(_ u: Int, via parentEdge: Int?) {
            let order = discovered.count
            discovered[u] = order
            low[u] = order
            for (edge, v) in adjacency[u] ?? [] where edge != parentEdge {
                if let orderV = discovered[v] {
                    // A back edge (or a parallel edge to the parent).
                    if orderV < order {
                        edgeStack.append(edge)
                        low[u] = min(low[u] ?? order, orderV)
                    }
                } else {
                    edgeStack.append(edge)
                    visit(v, via: edge)
                    low[u] = min(low[u] ?? order, low[v] ?? order)
                    if (low[v] ?? order) >= order {
                        var found = Set<Int>()
                        while let popped = edgeStack.popLast() {
                            found.insert(popped)
                            if popped == edge { break }
                        }
                        if found.contains(0) { block = found }
                    }
                }
            }
        }
        visit(a, via: nil)

        var relevantResistors: [Int] = []
        var relevantDependent: [Int] = []
        for edge in block {
            switch edges[edge].kind {
            case .resistor(let i): relevantResistors.append(i)
            case .dependent(let i): relevantDependent.append(i)
            case .virtual: break
            }
        }
        guard !relevantResistors.isEmpty || !relevantDependent.isEmpty else { return .notConnected }
        let unknown = relevantResistors.sorted().map { resistors[$0] }.filter { $0.z == nil }
        guard unknown.isEmpty else { return .unknownValues(unknown.map(\.name)) }
        if !relevantDependent.isEmpty {
            // Controlled sources or diodes take part: Req = Voc / Isc, found
            // the same way with a 1 A test current and them left in.
            return testCurrentResistance(between: nodeA, and: nodeB, in: circuit, netlist: netlist, solution: solution, omega: omega)
                ?? .dependentSources(Array(Set(relevantDependent.map { dependent[$0].name })).sorted())
        }
        let relevant = relevantResistors.map { resistors[$0] }

        // Nodal analysis with b as reference: Y·v = 1 A into a.
        let blockNodes = Set(relevant.flatMap { [find($0.p), find($0.q)] })
        let nodes = blockNodes.subtracting([b]).sorted()
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        var admittance = [[Complex]](repeating: [Complex](repeating: .zero, count: nodes.count), count: nodes.count)
        for resistor in relevant {
            guard let z = resistor.z, z.magnitude > 0 else { continue }
            // Nodes missing from `index` are the reference b.
            let i = index[find(resistor.p)]
            let j = index[find(resistor.q)]
            guard i != j else { continue }
            let y = Complex.one / z
            if let i { admittance[i][i] += y }
            if let j { admittance[j][j] += y }
            if let i, let j {
                admittance[i][j] -= y
                admittance[j][i] -= y
            }
        }
        guard let ia = index[a] else { return .notConnected }
        var injected = [Complex](repeating: .zero, count: nodes.count)
        injected[ia] = .one
        guard let voltages = LinearAlgebra.solve(admittance, injected) else { return .notConnected }
        func voltage(_ n: Int) -> Complex { index[find(n)].map { voltages[$0] } ?? .zero }

        // Resistors carrying part of the 1 A test current.
        var used = Set<UUID>()
        for resistor in relevant {
            guard let z = resistor.z, z.magnitude > 0 else { continue }
            if ((voltage(resistor.p) - voltage(resistor.q)) / z).magnitude > 1e-9 { used.insert(resistor.id) }
        }
        // A 0 Ω resistor carries current if it joins parts where current flows.
        for resistor in resistors where resistor.z?.magnitude == 0 && blockNodes.contains(find(resistor.p)) {
            let touchesUsed = resistors.contains { other in
                used.contains(other.id) && [other.p, other.q].contains { find($0) == find(resistor.p) }
            }
            if touchesUsed { used.insert(resistor.id) }
        }
        return .of(voltages[ia], resistors: used)
    }

    /// Req with controlled sources and diodes, by modified nodal analysis:
    /// independent sources off, controlled sources on, diodes in their solved
    /// state without their threshold voltage (conducting is a short, or an
    /// LED's internal resistance; blocking is open), and 1 A sent in at `nodeA` and out at `nodeB`. Req is the
    /// voltage that gives. `nil` if a control is missing or there's no single
    /// solution. In AC (`omega`) capacitors and inductors have their
    /// impedance and diodes are open.
    private static func testCurrentResistance(
        between nodeA: Int, and nodeB: Int, in circuit: Circuit, netlist: Netlist, solution: CircuitSolution, omega: Double?
    ) -> EquivalentResult? {
        func node(_ point: GridPoint) -> Int { netlist.nodeOf[point, default: -1] }
        let ends = Set([nodeA, nodeB])
        func value(_ component: CircuitComponent) -> Double? { component.value ?? solution.componentValues[component.id] }
        /// A resistor's, capacitor's or inductor's impedance; `nil` if unknown.
        func impedance(_ component: CircuitComponent) -> Complex? {
            value(component).map { component.kind.impedance($0, omega: omega) }
        }

        // Only the piece of the circuit joined to the two points, through
        // components that aren't open: switched-off current sources, blocking
        // diodes, capacitors in DC and a voltage source right between the points are.
        func isOpen(_ component: CircuitComponent) -> Bool {
            switch component.kind {
            case .currentSource, .toggleSwitch, .pushButton: true
            case .voltageSource, .signalGenerator: Set([node(component.start), node(component.end)]) == ends
            case .diode, .led: omega != nil || solution.diodeConducts[component.id] != true
            case .capacitor: omega == nil || impedance(component)?.magnitude.isFinite != true
            default: false
            }
        }
        var neighbors: [Int: [Int]] = [:]
        for component in circuit.components where !isOpen(component) {
            let p = node(component.start), q = node(component.end)
            neighbors[p, default: []].append(q)
            neighbors[q, default: []].append(p)
        }
        var piece: Set<Int> = [nodeA]
        var queue = [nodeA]
        while let next = queue.popLast() {
            for neighbor in neighbors[next] ?? [] where !piece.contains(neighbor) {
                piece.insert(neighbor)
                queue.append(neighbor)
            }
        }
        guard piece.contains(nodeB) else { return .notConnected }
        let components = circuit.components.filter { piece.contains(node($0.start)) }

        // Unknowns: node voltages (nodeB is 0 V), the current of each branch
        // that sets a voltage, and each controlling current.
        var index: [Int: Int] = [:]
        for n in piece.sorted() where n != nodeB { index[n] = index.count }
        var count = index.count
        var branch: [UUID: Int] = [:]
        for component in components {
            let setsVoltage: Bool = switch component.kind {
            case .voltageSource, .signalGenerator:
                // A source right between the two points is taken out.
                Set([node(component.start), node(component.end)]) != ends
            case .vcvs, .ccvs: true
            case .resistor, .inductor: impedance(component)?.magnitude == 0
            case .diode: omega == nil && solution.diodeConducts[component.id] == true
            case .led, .currentSource, .vccs, .cccs, .capacitor, .toggleSwitch, .pushButton: false
            }
            if setsVoltage {
                branch[component.id] = count
                count += 1
            }
        }
        var controlCurrent: [UUID: (unknown: Int, coefficients: [UUID: Double])] = [:]
        for component in components where component.kind.isCurrentControlled {
            guard let arrow = circuit.sense(of: component.id, .current).flatMap({ circuit.currentArrow(for: $0) }),
                  let coefficients = netlist.componentCoefficients(for: arrow, in: circuit) else { return nil }
            controlCurrent[component.id] = (count, coefficients)
            count += 1
        }

        typealias Row = [Int: Complex]
        func voltage(_ n: Int) -> Row { index[n].map { [$0: .one] } ?? [:] }
        func difference(_ p: Int, _ q: Int) -> Row { voltage(p).merging(voltage(q).mapValues { -$0 }, uniquingKeysWith: +) }
        func scaled(_ row: Row, _ k: Complex) -> Row { row.mapValues { $0 * k } }
        func controlRow(_ component: CircuitComponent) -> Row? {
            if component.kind.isVoltageControlled {
                guard let plus = circuit.sense(of: component.id, .plus).flatMap({ netlist.nodeOf[$0.gridPoint] }),
                      let minus = circuit.sense(of: component.id, .minus).flatMap({ netlist.nodeOf[$0.gridPoint] }) else { return nil }
                return difference(plus, minus)
            }
            return controlCurrent[component.id].map { [$0.unknown: .one] }
        }
        /// A component's current from start to end, linear in the unknowns.
        func current(_ component: CircuitComponent) -> Row? {
            if let unknown = branch[component.id] { return [unknown: .one] }
            let p = node(component.start), q = node(component.end)
            switch component.kind {
            case .resistor, .capacitor, .inductor:
                guard let z = impedance(component), z.magnitude > 0, z.magnitude.isFinite else { return [:] }
                return scaled(difference(p, q), .one / z)
            case .vccs, .cccs:
                return controlRow(component).map { scaled($0, Complex(component.value ?? 0)) }
            case .led where omega == nil && solution.diodeConducts[component.id] == true:
                return scaled(difference(p, q), Complex(1 / LEDModel.resistance))
            default:
                // Switched-off and taken-out sources, blocking diodes.
                return [:]
            }
        }

        var matrix: [[Complex]] = []
        var vector: [Complex] = []
        func add(_ row: Row, _ constant: Complex) {
            var dense = [Complex](repeating: .zero, count: count)
            for (i, k) in row { dense[i] += k }
            matrix.append(dense)
            vector.append(constant)
        }
        // Kirchhoff's current law in every node but nodeB: out = the test current in.
        var outOf: [Int: Row] = [:]
        for component in components {
            guard let i = current(component) else { return nil }
            outOf[node(component.start), default: [:]].merge(i, uniquingKeysWith: +)
            outOf[node(component.end), default: [:]].merge(i.mapValues { -$0 }, uniquingKeysWith: +)
        }
        for n in index.keys.sorted() { add(outOf[n] ?? [:], n == nodeA ? .one : .zero) }
        // The branches that set a voltage.
        for component in components {
            guard branch[component.id] != nil else { continue }
            var row = difference(node(component.end), node(component.start))
            if component.kind == .vcvs || component.kind == .ccvs {
                guard let control = controlRow(component) else { return nil }
                row.merge(scaled(control, Complex(-(component.value ?? 0))), uniquingKeysWith: +)
            }
            add(row, .zero)
        }
        // The controlling currents.
        for (_, control) in controlCurrent {
            var row: Row = [control.unknown: .one]
            for component in components {
                guard let k = control.coefficients[component.id], k != 0, let i = current(component) else { continue }
                row.merge(scaled(i, Complex(-k)), uniquingKeysWith: +)
            }
            add(row, .zero)
        }
        guard let ia = index[nodeA], let x = LinearAlgebra.solve(matrix, vector) else { return nil }

        // The resistors carrying part of the test current.
        var used = Set<UUID>()
        for component in components where component.kind == .resistor || component.kind.isReactive {
            guard let i = current(component) else { continue }
            if i.reduce(Complex.zero, { $0 + $1.value * x[$1.key] }).magnitude > 1e-9 { used.insert(component.id) }
        }
        return .of(x[ia], resistors: used)
    }
}

nonisolated extension Circuit {
    /// The circuit split into the parts that aren't joined by wires or
    /// components, each with its own items. Grounds don't join parts: no
    /// current flows between them through ground, so each can be solved on
    /// its own (e.g. a part with a signal generator with phasors, the rest
    /// as DC). A controlled source stays with what controls it, and a voltage
    /// drop joins its two points. Items on no part go with the first.
    func separateParts() -> [Circuit] {
        var bare = self
        bare.grounds = []
        let netlist = Netlist(bare)
        var parent = Array(0..<netlist.nodeCount)
        func find(_ n: Int) -> Int {
            var n = n
            while parent[n] != n { n = parent[n] }
            return n
        }
        func join(_ a: Int?, _ b: Int?) {
            guard let a, let b else { return }
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[ra] = rb }
        }
        func node(_ point: GridPoint) -> Int? { netlist.node(at: point) }
        let componentByID = Dictionary(components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for component in components { join(node(component.start), node(component.end)) }
        for sense in senses {
            if let owner = componentByID[sense.ownerID] { join(node(sense.gridPoint), node(owner.start)) }
        }
        for probe in probes {
            if let negative = probe.negative { join(node(probe.position), node(negative)) }
        }

        // One part per group of components, in the order they come.
        var partOfRoot: [Int: Int] = [:]
        for component in components {
            guard let root = node(component.start).map(find), partOfRoot[root] == nil else { continue }
            partOfRoot[root] = partOfRoot.count
        }
        guard partOfRoot.count > 1 else { return [self] }
        var empty = self
        empty.components = []
        empty.wires = []
        empty.probes = []
        empty.currents = []
        empty.grounds = []
        empty.senses = []
        empty.meshMarkers = []
        var parts = Array(repeating: empty, count: partOfRoot.count)
        func part(_ point: GridPoint?) -> Int {
            point.flatMap(node).map(find).flatMap { partOfRoot[$0] } ?? 0
        }
        for component in components { parts[part(component.start)].components.append(component) }
        let wireByID = Dictionary(wires.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for wire in wires { parts[part(wire.start)].wires.append(wire) }
        for probe in probes { parts[part(probe.position)].probes.append(probe) }
        for arrow in currents { parts[part(wireByID[arrow.wireID]?.start)].currents.append(arrow) }
        for ground in grounds { parts[part(ground.position)].grounds.append(ground) }
        for sense in senses { parts[part(componentByID[sense.ownerID]?.start)].senses.append(sense) }
        parts[0].meshMarkers = meshMarkers
        return parts
    }

    /// The circuit with each conducting LED replaced by its model: a voltage
    /// source Vk (+ towards the anode, with the LED's id and name) in series
    /// with its internal resistance rd, joined at a grid point inside the LED
    /// (so the circuit stays planar for the mesh method), or one far off the
    /// sheet for an LED only one grid unit long. For the walkthrough and
    /// Maple, which work with sources and resistors. Also returns the
    /// resistors added, by LED id.
    func splittingLEDs(conducting: Set<UUID>) -> (circuit: Circuit, resistors: [UUID: CircuitComponent]) {
        var result = self
        var resistors: [UUID: CircuitComponent] = [:]
        for (index, led) in components.enumerated() where led.kind == .led && conducting.contains(led.id) {
            let dx = led.end.x - led.start.x, dy = led.end.y - led.start.y
            let length = max(abs(dx), abs(dy))
            let inner = length >= 2
                ? GridPoint(x: led.start.x + dx / length * (length / 2), y: led.start.y + dy / length * (length / 2))
                : GridPoint(x: -1_000_000 - index, y: -1_000_000)
            let resistor = CircuitComponent(
                kind: .resistor, start: led.start, end: inner, name: "rd_{\(led.name)}", value: LEDModel.resistance
            )
            result.components.removeAll { $0.id == led.id }
            // A voltage source has + at its end.
            result.components.append(CircuitComponent(
                id: led.id, kind: .voltageSource, start: led.end, end: inner, name: led.name, value: led.value
            ))
            result.components.append(resistor)
            resistors[led.id] = resistor
        }
        return (result, resistors)
    }
}

nonisolated extension Netlist {
    /// The node at a grid point: a connection point, a bend, or any point
    /// along a wire. `nil` if nothing is there.
    func node(at point: GridPoint) -> Int? {
        if let node = nodeOf[point] { return node }
        guard let edge = edges.first(where: { $0.wireID != nil && Circuit.point(point, isInteriorOf: $0.a, $0.b) }) else {
            return nil
        }
        return nodeOf[edge.a]
    }
}

// MARK: - Netlist

/// Groups connected points into nodes.
nonisolated struct Netlist {
    /// A piece of wire between two connection points (or a virtual link between ground symbols).
    struct Edge {
        var a: GridPoint
        var b: GridPoint
        var wireID: UUID?
    }

    private(set) var nodeOf: [GridPoint: Int] = [:]
    private(set) var nodeCount = 0
    /// All ground symbols form one node, the 0 V reference.
    private(set) var groundNode: Int?
    private(set) var edges: [Edge] = []

    init(_ circuit: Circuit) {
        var parent: [GridPoint: GridPoint] = [:]
        func find(_ point: GridPoint) -> GridPoint {
            var root = point
            while let next = parent[root], next != root { root = next }
            return root
        }
        func union(_ a: GridPoint, _ b: GridPoint) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        // Points where things can connect. Bends only matter within their own wire.
        var connectionPoints = Set<GridPoint>()
        for wire in circuit.wires {
            connectionPoints.insert(wire.start)
            connectionPoints.insert(wire.end)
        }
        for component in circuit.components {
            connectionPoints.insert(component.start)
            connectionPoints.insert(component.end)
        }
        connectionPoints.formUnion(circuit.grounds.map(\.position))
        connectionPoints.formUnion(circuit.probes.map(\.position))
        connectionPoints.formUnion(circuit.probes.compactMap(\.negative))
        // The + and − points of voltage-controlled sources connect where they're placed.
        connectionPoints.formUnion(circuit.senses.filter { $0.kind != .current }.map(\.gridPoint))
        for point in connectionPoints where parent[point] == nil {
            parent[point] = point
        }

        var edgeList: [Edge] = []
        for wire in circuit.wires {
            for (a, b) in wire.segments {
                var onSegment = [a, b]
                onSegment += connectionPoints.filter { Circuit.point($0, isInteriorOf: a, b) }
                onSegment.sort { ($0.x, $0.y) < ($1.x, $1.y) }
                for (p, q) in zip(onSegment, onSegment.dropFirst()) where p != q {
                    union(p, q)
                    edgeList.append(Edge(a: p, b: q, wireID: wire.id))
                }
            }
        }
        if let first = circuit.grounds.first?.position {
            for ground in circuit.grounds.dropFirst() {
                union(first, ground.position)
                edgeList.append(Edge(a: first, b: ground.position, wireID: nil))
            }
        }

        var indexOfRoot: [GridPoint: Int] = [:]
        var nodes: [GridPoint: Int] = [:]
        for point in parent.keys.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
            let root = find(point)
            if indexOfRoot[root] == nil { indexOfRoot[root] = indexOfRoot.count }
            nodes[point] = indexOfRoot[root]
        }
        nodeOf = nodes
        nodeCount = indexOfRoot.count
        edges = edgeList
        groundNode = circuit.grounds.first.flatMap { nodes[$0.position] }
    }
}

nonisolated extension Netlist {
    /// The current in a wire under a current arrow, as ±1 times the current of
    /// each component (flowing from its start to its end terminal). Cutting the
    /// wire piece under the arrow splits its node in two; the current through
    /// the piece equals what the components feed into the side the arrow
    /// comes from. `nil` if the wire is part of a loop of wires.
    ///
    /// Both sides of the wire give the same current (Kirchhoff's current law);
    /// `fromOtherSide` picks which side's components the result is written with.
    func componentCoefficients(for arrow: CurrentArrow, in circuit: Circuit, fromOtherSide: Bool = false) -> [UUID: Double]? {
        guard let placement = circuit.placement(of: arrow) else { return nil }
        let point = placement.point
        let direction = placement.direction
        func contains(_ edge: Edge, _ p: CGPoint) -> Bool {
            p.distance(toSegment: CGPoint(x: edge.a.x, y: edge.a.y), CGPoint(x: edge.b.x, y: edge.b.y)) < 1e-6
        }
        let ahead = CGPoint(x: point.x + direction.x * 0.01, y: point.y + direction.y * 0.01)
        let candidates = edges.indices.filter { edges[$0].wireID == arrow.wireID && contains(edges[$0], point) }
        guard let edgeIndex = candidates.first(where: { contains(edges[$0], ahead) }) ?? candidates.first else {
            return nil
        }
        let edge = edges[edgeIndex]

        // Everything reachable from one end without crossing the arrow's wire piece.
        var neighbors: [GridPoint: [GridPoint]] = [:]
        for (index, other) in edges.enumerated() where index != edgeIndex {
            neighbors[other.a, default: []].append(other.b)
            neighbors[other.b, default: []].append(other.a)
        }
        let origin = fromOtherSide ? edge.b : edge.a
        let far = fromOtherSide ? edge.a : edge.b
        var side: Set<GridPoint> = [origin]
        var queue = [origin]
        while let next = queue.popLast() {
            for neighbor in neighbors[next] ?? [] where !side.contains(neighbor) {
                side.insert(neighbor)
                queue.append(neighbor)
            }
        }
        // Reaching the other end means the wire is part of a loop of wires.
        if side.contains(far) { return nil }

        // What the components feed into the side leaves it through the wire,
        // i.e. flows from `origin` towards `far`.
        let alongEdge = direction.x * Double(far.x - origin.x) + direction.y * Double(far.y - origin.y)
        let sign: Double = alongEdge >= 0 ? 1 : -1
        var coefficients: [UUID: Double] = [:]
        for component in circuit.components {
            if side.contains(component.start) { coefficients[component.id, default: 0] -= sign }
            if side.contains(component.end) { coefficients[component.id, default: 0] += sign }
        }
        return coefficients.filter { $0.value != 0 }
    }
}

// MARK: - Equations

/// `Σ linear·x + Σ coefficient·x[a]·x[b] + Σ coefficient·e^x[a]·x[b] + constant = 0`
///
/// The exponential terms are for unknown resistances, which are solved as
/// R = e^u so they can only come out positive.
nonisolated struct Equation {
    var linear: [Int: Double] = [:]
    var bilinear: [(a: Int, b: Int, coefficient: Double)] = []
    var exponential: [(a: Int, b: Int, coefficient: Double)] = []
    var constant = 0.0
    /// Names of the items the equation comes from, to explain conflicts.
    var sources: [String]

    func value(_ x: [Double]) -> Double {
        var sum = constant
        for (index, coefficient) in linear { sum += coefficient * x[index] }
        for term in bilinear { sum += term.coefficient * x[term.a] * x[term.b] }
        for term in exponential { sum += term.coefficient * safeExp(x[term.a]) * x[term.b] }
        return sum
    }

    func gradient(_ x: [Double], count: Int) -> [Double] {
        var result = [Double](repeating: 0, count: count)
        for (index, coefficient) in linear { result[index] += coefficient }
        for term in bilinear {
            result[term.a] += term.coefficient * x[term.b]
            result[term.b] += term.coefficient * x[term.a]
        }
        for term in exponential {
            let e = safeExp(x[term.a])
            result[term.a] += term.coefficient * e * x[term.b]
            result[term.b] += term.coefficient * e
        }
        return result
    }

    /// The size of the terms, used to judge whether the residual is "zero".
    func magnitude(_ x: [Double]) -> Double {
        var sum = abs(constant)
        for (index, coefficient) in linear { sum += abs(coefficient * x[index]) }
        for term in bilinear { sum += abs(term.coefficient * x[term.a] * x[term.b]) }
        for term in exponential { sum += abs(term.coefficient * safeExp(x[term.a]) * x[term.b]) }
        return sum
    }
}

/// `e^x`, kept finite so the solver can't overflow.
nonisolated func safeExp(_ x: Double) -> Double {
    exp(min(max(x, -60), 60))
}

// MARK: - Model

nonisolated private struct Model {
    enum VariableKind {
        case voltage, current, parameter
        /// The logarithm of an unknown resistance (R = e^u), or of an unknown
        /// capacitor's or inductor's reactance in AC.
        case logResistance
    }

    /// A value the user can see but hasn't entered.
    struct Unknown {
        enum Target { case component(UUID), probe(UUID), current(UUID) }
        var name: String
        var target: Target
        /// The value as a linear function of the variables, or `nil` if it can't
        /// be expressed at all (a current arrow in a loop of wires). In AC the
        /// real part of the phasor.
        var expression: [Int: Double]?
        /// In AC the imaginary part of a voltage or current phasor.
        var imaginary: [Int: Double]? = nil
    }

    let circuit: Circuit
    let netlist: Netlist
    /// The diodes assumed to conduct; the others block.
    let conducting: Set<UUID>
    /// The angular frequency 2πf when the circuit is solved with phasors
    /// (AC), `nil` for DC. In AC every voltage and current has a real and an
    /// imaginary part, each with its own variable and equations.
    let omega: Double?
    var kinds: [VariableKind] = []
    var initial: [Double] = []
    /// Variables of the node voltages and component currents: the real part
    /// (index 0) and, in AC, the imaginary part (index 1).
    var voltageVariables: [[Int: Int]] = [[:], [:]]
    var currentVariables: [[UUID: Int]] = [[:], [:]]
    var parameterVariable: [UUID: Int] = [:]
    var equations: [Equation] = []
    var unknowns: [Unknown] = []
    var issues: [SolverIssue] = []

    /// The variables at the solution, set by `solve()`.
    private(set) var point: [Double] = []

    /// 0 for the real part, and 1 for the imaginary part in AC.
    private var parts: [Int] { omega == nil ? [0] : [0, 1] }

    init(circuit: Circuit, conducting: Set<UUID> = [], omega: Double? = nil) {
        self.circuit = circuit
        self.netlist = Netlist(circuit)
        self.conducting = conducting
        self.omega = omega
        buildVariables()
        buildEquations()
        buildUnknowns()
    }

    private mutating func addVariable(_ kind: VariableKind, initial value: Double) -> Int {
        kinds.append(kind)
        initial.append(value)
        return kinds.count - 1
    }

    /// The variable holding a component's current (real or imaginary part).
    private func currentVariable(_ id: UUID, part: Int = 0) -> Int? {
        currentVariables[part][id]
    }

    /// A voltage point's voltage, or a voltage drop's V(+) − V(−), as a linear
    /// function of the variables. A point on the ground node counts as 0 V.
    /// `nil` when one of a voltage drop's points isn't on the circuit.
    private func expression(for probe: Probe, part: Int = 0) -> [Int: Double]? {
        var expression: [Int: Double] = [:]
        if let variable = voltage(at: probe.position, part: part) { expression[variable, default: 0] += 1 }
        if let negative = probe.negative {
            guard netlist.nodeOf[probe.position] != nil, netlist.nodeOf[negative] != nil else { return nil }
            if let variable = voltage(at: negative, part: part) { expression[variable, default: 0] -= 1 }
        }
        return expression.filter { $0.value != 0 }
    }

    /// The variable holding a point's voltage, or `nil` for ground (always 0 V).
    private func voltage(at point: GridPoint, part: Int = 0) -> Int? {
        guard let node = netlist.nodeOf[point], node != netlist.groundNode else { return nil }
        return voltageVariables[part][node]
    }

    private mutating func buildVariables() {
        for part in parts {
            for node in 0..<netlist.nodeCount where node != netlist.groundNode {
                voltageVariables[part][node] = addVariable(.voltage, initial: 0)
            }
            for component in circuit.components {
                currentVariables[part][component.id] = addVariable(.current, initial: 0)
            }
        }
        for component in circuit.components where component.value == nil {
            let parameter: Int? = switch component.kind {
            case .resistor: addVariable(.logResistance, initial: log(1000))
            // Only the reactance in AC tells a capacitance or inductance.
            case .capacitor, .inductor: omega == nil ? nil : addVariable(.logResistance, initial: log(1000))
            case .voltageSource, .signalGenerator: addVariable(.parameter, initial: 1)
            case .currentSource: addVariable(.parameter, initial: 0.001)
            case .vcvs, .ccvs, .vccs, .cccs: addVariable(.parameter, initial: 1)
            // Diodes aren't modelled in AC.
            case .diode: omega == nil ? addVariable(.parameter, initial: 0.7) : nil
            case .led: omega == nil ? addVariable(.parameter, initial: 2) : nil
            // Switches are resolved into wires before solving.
            case .toggleSwitch, .pushButton: nil
            }
            if let parameter { parameterVariable[component.id] = parameter }
        }
    }

    private mutating func buildEquations() {
        for part in parts { buildEquations(part: part) }

        // Known voltages and currents. In AC the value is the amplitude:
        // re² + im² − value² = 0.
        for probe in circuit.probes {
            guard let value = probe.value, let expression = expression(for: probe) else { continue }
            equations.append(knownValueEquation(expression, self.expression(for: probe, part: 1), value: value, source: probe.name))
        }
        for arrow in circuit.currents {
            guard let value = arrow.value, let expression = expression(for: arrow) else { continue }
            equations.append(knownValueEquation(expression, self.expression(for: arrow, part: 1), value: value, source: arrow.name))
        }
    }

    /// `expression = value` in DC, `|expression| = value` in AC.
    private func knownValueEquation(_ real: [Int: Double], _ imaginary: [Int: Double]?, value: Double, source: String) -> Equation {
        guard omega != nil, let imaginary else {
            var equation = Equation(linear: real, sources: [source])
            equation.constant = -value
            return equation
        }
        var equation = Equation(sources: [source])
        for expression in [real, imaginary] {
            for (a, ka) in expression {
                for (b, kb) in expression { equation.bilinear.append((a, b, ka * kb)) }
            }
        }
        equation.constant = -value * value
        return equation
    }

    /// The equations of the components and Kirchhoff's current law, for the
    /// real part (0) or the imaginary part (1) of the voltages and currents.
    private mutating func buildEquations(part: Int) {
        var kcl: [Int: Equation] = [:]
        let isImaginary = part == 1

        for component in circuit.components {
            guard let current = currentVariable(component.id, part: part) else { continue }
            let start = voltage(at: component.start, part: part)
            let end = voltage(at: component.end, part: part)
            var equation = Equation(sources: [component.name])
            /// A source's value split into this part: E·cos φ or E·sin φ.
            let phase = isImaginary ? component.phaseFactor.im : component.phaseFactor.re
            func setValue(_ coefficient: Double) {
                if let value = component.value {
                    equation.constant = -value * phase * coefficient
                } else if let parameter = parameterVariable[component.id], phase != 0 {
                    equation.linear[parameter, default: 0] -= phase * coefficient
                }
            }

            switch component.kind {
            case .resistor:
                // v(start) − v(end) − R·i = 0
                if let start { equation.linear[start, default: 0] += 1 }
                if let end { equation.linear[end, default: 0] -= 1 }
                if let value = component.value {
                    equation.linear[current, default: 0] -= value
                } else if let parameter = parameterVariable[component.id] {
                    // R = e^u keeps an unknown resistance positive.
                    equation.exponential.append((parameter, current, -1))
                }
            case .capacitor, .inductor:
                if let omega {
                    // v = −jX·i for a capacitor (X = 1/(ωC)) and v = jX·i for an
                    // inductor (X = ωL). Split into parts:
                    //   capacitor: v_re − X·i_im = 0, v_im + X·i_re = 0
                    //   inductor:  v_re + X·i_im = 0, v_im − X·i_re = 0
                    if component.kind == .capacitor, component.value == 0 {
                        // No capacitance: open.
                        equation.linear[current] = 1
                        break
                    }
                    if let start { equation.linear[start, default: 0] += 1 }
                    if let end { equation.linear[end, default: 0] -= 1 }
                    guard let other = currentVariable(component.id, part: 1 - part) else { break }
                    let sign: Double = (component.kind == .capacitor) != isImaginary ? -1 : 1
                    if let value = component.value {
                        let reactance = component.kind == .capacitor ? 1 / (omega * value) : omega * value
                        equation.linear[other, default: 0] += sign * reactance
                    } else if let parameter = parameterVariable[component.id] {
                        // X = e^u keeps an unknown reactance positive.
                        equation.exponential.append((parameter, other, sign))
                    }
                } else if component.kind == .capacitor {
                    // In DC a capacitor carries no current: i = 0
                    equation.linear[current] = 1
                } else {
                    // In DC an inductor is a short: v(start) − v(end) = 0
                    if let start { equation.linear[start, default: 0] += 1 }
                    if let end { equation.linear[end, default: 0] -= 1 }
                }
            case .voltageSource, .signalGenerator:
                // v(+) − v(−) − E = 0, with + at the end terminal
                if let end { equation.linear[end, default: 0] += 1 }
                if let start { equation.linear[start, default: 0] -= 1 }
                setValue(1)
            case .currentSource:
                // i − J = 0, flowing from start to end through the source
                equation.linear[current] = 1
                setValue(1)
            case .toggleSwitch, .pushButton:
                // Resolved into wires before solving; here an open switch: i = 0
                equation.linear[current] = 1
            case .diode, .led:
                if omega == nil, conducting.contains(component.id) {
                    // v(anode) − v(cathode) − Vf = 0, with the anode at the start
                    // terminal; an LED has its internal resistance too: − rd·i
                    if let start { equation.linear[start, default: 0] += 1 }
                    if let end { equation.linear[end, default: 0] -= 1 }
                    if component.kind == .led { equation.linear[current, default: 0] -= LEDModel.resistance }
                    if let value = component.value {
                        equation.constant = -value
                    } else if let parameter = parameterVariable[component.id] {
                        equation.linear[parameter] = -1
                    }
                } else {
                    // A blocking diode carries no current: i = 0
                    equation.linear[current] = 1
                }
            case .vcvs, .ccvs, .vccs, .cccs:
                // v(+) − v(−) − gain·control = 0, or i − gain·control = 0
                guard let control = control(of: component, part: part) else {
                    if part == 0 {
                        issues.append(SolverIssue(
                            kind: .missing,
                            title: "\(component.name) mangler sin styring",
                            detail: component.kind.isVoltageControlled
                                ? "Træk + og − punkterne (Vs) for \(component.name) hen på de to steder i kredsløbet, spændingen skal måles imellem."
                                : "Træk Is-punktet for \(component.name) hen på den ledning, hvor den styrende strøm løber. Ledningen må ikke indgå i en løkke af ledninger."
                        ))
                    }
                    // Without its control the source adds no equation.
                    break
                }
                if component.kind.setsVoltage {
                    if let end { equation.linear[end, default: 0] += 1 }
                    if let start { equation.linear[start, default: 0] -= 1 }
                } else {
                    equation.linear[current, default: 0] += 1
                }
                if let gain = component.value {
                    for (variable, coefficient) in control {
                        equation.linear[variable, default: 0] -= gain * coefficient
                    }
                } else if let parameter = parameterVariable[component.id] {
                    for (variable, coefficient) in control {
                        equation.bilinear.append((parameter, variable, -coefficient))
                    }
                }
            }
            if component.kind.isDependent && control(of: component, part: part) == nil {
                // No equation for a controlled source without its control.
            } else {
                equations.append(equation)
            }

            // Kirchhoff's current law: the component's current leaves the node at
            // its start terminal and enters the node at its end terminal.
            if let node = netlist.nodeOf[component.start] {
                kcl[node, default: Equation(sources: [])].linear[current, default: 0] -= 1
                kcl[node]?.sources.append(component.name)
            }
            if let node = netlist.nodeOf[component.end] {
                kcl[node, default: Equation(sources: [])].linear[current, default: 0] += 1
                kcl[node]?.sources.append(component.name)
            }
        }
        equations += kcl.keys.sorted().compactMap { kcl[$0] }
    }

    private mutating func buildUnknowns() {
        for component in circuit.components where component.value == nil {
            if let parameter = parameterVariable[component.id] {
                unknowns.append(Unknown(name: component.name, target: .component(component.id), expression: [parameter: 1]))
            }
        }
        let isAC = omega != nil
        for probe in circuit.probes where probe.value == nil {
            guard let expression = expression(for: probe) else { continue }
            unknowns.append(Unknown(
                name: probe.name, target: .probe(probe.id), expression: expression,
                imaginary: isAC ? self.expression(for: probe, part: 1) : nil
            ))
        }
        for arrow in circuit.currents where arrow.value == nil {
            unknowns.append(Unknown(
                name: arrow.name, target: .current(arrow.id), expression: expression(for: arrow),
                imaginary: isAC ? expression(for: arrow, part: 1) : nil
            ))
        }
    }

    /// The controlling quantity of a controlled source as a linear function
    /// of the variables: the voltage between its + and − sense points (Vs),
    /// or the current in the wire under its Is marker. `nil` if the markers
    /// aren't placed on the circuit.
    private func control(of component: CircuitComponent, part: Int = 0) -> [Int: Double]? {
        if component.kind.isVoltageControlled {
            guard let plus = circuit.sense(of: component.id, .plus),
                  let minus = circuit.sense(of: component.id, .minus),
                  isOnCircuit(plus.gridPoint), isOnCircuit(minus.gridPoint) else { return nil }
            var result: [Int: Double] = [:]
            if let variable = voltage(at: plus.gridPoint, part: part) { result[variable, default: 0] += 1 }
            if let variable = voltage(at: minus.gridPoint, part: part) { result[variable, default: 0] -= 1 }
            return result
        }
        if component.kind.isCurrentControlled {
            guard let marker = circuit.sense(of: component.id, .current),
                  let arrow = circuit.currentArrow(for: marker) else { return nil }
            return expression(for: arrow, part: part)
        }
        return nil
    }

    /// Whether a point is part of a node that something is connected to.
    private func isOnCircuit(_ point: GridPoint) -> Bool {
        guard let node = netlist.nodeOf[point] else { return false }
        if node == netlist.groundNode { return true }
        return circuit.components.contains { netlist.nodeOf[$0.start] == node || netlist.nodeOf[$0.end] == node }
    }

    /// The current in a wire, as a sum of component currents.
    private func expression(for arrow: CurrentArrow, part: Int = 0) -> [Int: Double]? {
        guard let coefficients = netlist.componentCoefficients(for: arrow, in: circuit) else { return nil }
        var result: [Int: Double] = [:]
        for (id, coefficient) in coefficients {
            if let current = currentVariable(id, part: part) { result[current, default: 0] += coefficient }
        }
        return result
    }

    // MARK: Solving

    mutating func solve() -> CircuitSolution {
        var solution = CircuitSolution()
        solution.unknownCount = unknowns.count
        let count = kinds.count
        let x = count > 0 ? bestSolution() : []
        point = x

        // Are the known values consistent?
        let conflicting = equations.filter { abs($0.value(x)) > 1e-6 * $0.magnitude(x) + 1e-9 }
        let negativeResistors = circuit.components.filter { $0.kind == .resistor && ($0.value ?? 1) < 0 }
        solution.isConsistent = conflicting.isEmpty && negativeResistors.isEmpty
        for resistor in negativeResistors {
            issues.append(SolverIssue(
                kind: .conflict,
                title: "\(resistor.name) er negativ",
                detail: "En modstand kan ikke være negativ. Ret værdien af \(resistor.name)."
            ))
        }
        if !conflicting.isEmpty {
            let names = Array(Set(conflicting.flatMap(\.sources))).sorted()
            let hasUnknownResistors = circuit.components.contains { $0.kind == .resistor && $0.value == nil }
            let reason = hasUnknownResistors
                ? " Ingen positive værdier for de ukendte modstande kan give de kendte værdier – fx kan en spænding ikke blive højere end kilden uden en strømkilde."
                : ""
            issues.append(SolverIssue(
                kind: .conflict,
                title: "Værdierne passer ikke sammen",
                detail: "De kendte værdier modsiger hinanden, så intet kan beregnes.\(reason) Tjek værdierne ved: \(names.joined(separator: ", "))."
            ))
        }

        if netlist.groundNode == nil, !circuit.probes.isEmpty || !circuit.components.isEmpty {
            issues.append(SolverIssue(
                kind: .notice,
                title: "Der mangler et stel (0 V)",
                detail: "Spændinger i punkterne måles i forhold til stel. Sæt et stel-symbol (G) på det punkt, der skal være 0 V."
            ))
        }

        let rank = RankTester(equations: equations, x: x, kinds: kinds)
        func evaluate(_ expression: [Int: Double]) -> Double {
            expression.reduce(0) { $0 + $1.value * x[$1.key] }
        }
        // Values this much smaller than the circuit's largest voltage or
        // current are rounding noise from the solver, and shown as 0.
        let voltageScale = zip(x, kinds).filter { $0.1 == .voltage }.map { abs($0.0) }.max() ?? 0
        // A current counts as large next to the voltages over 1 kΩ.
        let currentScale = max(voltageScale / 1e3, zip(x, kinds).filter { $0.1 == .current }.map { abs($0.0) }.max() ?? 0)
        func cleaned(_ value: Double, scale: Double) -> Double { abs(value) <= 1e-9 * scale ? 0 : value }
        for unknown in unknowns {
            guard let expression = unknown.expression else {
                issues.append(SolverIssue(
                    kind: .missing,
                    title: "\(unknown.name) kan ikke beregnes",
                    detail: "Strømpilen sidder på en ledning i en løkke af ledninger, så strømmen kan fordele sig på flere måder. Flyt pilen til en ledning uden parallelforbindelse."
                ))
                continue
            }
            let isDetermined = rank.isDetermined(expression) && unknown.imaginary.map { rank.isDetermined($0) } != false
            if solution.isConsistent, isDetermined {
                var value = evaluate(expression)
                var phase: Double?
                let scale: Double = if case .current = unknown.target { currentScale } else { voltageScale }
                if let imaginary = unknown.imaginary {
                    // A phasor: its amplitude and phase.
                    let phasor = Complex(value, evaluate(imaginary))
                    let isZero = cleaned(phasor.magnitude, scale: scale) == 0
                    value = isZero ? 0 : phasor.magnitude
                    phase = isZero ? 0 : phasor.degrees
                } else if case .component = unknown.target {
                    // Component values keep their own size.
                } else {
                    value = cleaned(value, scale: scale)
                }
                // Unknown resistances (and reactances) are solved as their logarithm.
                if case .component(let id) = unknown.target, expression.count == 1,
                   let variable = expression.keys.first, kinds[variable] == .logResistance {
                    value = safeExp(x[variable])
                    if let omega, let kind = circuit.components.first(where: { $0.id == id })?.kind {
                        // From the reactance: C = 1/(ωX), L = X/ω.
                        if kind == .capacitor { value = 1 / (omega * value) }
                        if kind == .inductor { value /= omega }
                    }
                }
                switch unknown.target {
                case .component(let id): solution.componentValues[id] = value
                case .probe(let id):
                    solution.probeValues[id] = value
                    solution.phases[id] = phase
                case .current(let id):
                    solution.currentValues[id] = value
                    solution.phases[id] = phase
                }
                solution.solvedCount += 1
            } else if solution.isConsistent {
                // Which other unknown value would make this one computable?
                let helpers = unknowns.filter { other in
                    guard other.name != unknown.name, let helper = other.expression else { return false }
                    return rank.isDetermined(expression, given: helper)
                }.map(\.name)
                let detail = helpers.isEmpty
                    ? "Der mangler flere kendte værdier i den del af kredsløbet, eller den er ikke forbundet til resten."
                    : "Angiv én af disse værdier: \(helpers.joined(separator: ", "))."
                issues.append(SolverIssue(kind: .missing, title: "\(unknown.name) kan ikke beregnes endnu", detail: detail))
            }
        }

        // The power absorbed by each component with a power circle: the
        // voltage from start to end times the current from start to end.
        // It's known when both the voltage and the current are. In AC it's the
        // average power ½·Re(V·I*), with V and I as amplitudes.
        for component in circuit.components where component.isPowerShown {
            solution.unknownCount += 1
            var products: [(voltage: [Int: Double], current: Int)] = []
            for part in parts {
                guard let current = currentVariable(component.id, part: part) else { continue }
                var voltage: [Int: Double] = [:]
                if let start = self.voltage(at: component.start, part: part) { voltage[start, default: 0] += 1 }
                if let end = self.voltage(at: component.end, part: part) { voltage[end, default: 0] -= 1 }
                products.append((voltage.filter { $0.value != 0 }, current))
            }
            let isOnCircuit = netlist.nodeOf[component.start] != nil && netlist.nodeOf[component.end] != nil
            let isDetermined = !products.isEmpty && products.allSatisfy { rank.isDetermined($0.voltage) && rank.isDetermined([$0.current: 1]) }
            if solution.isConsistent, isOnCircuit, isDetermined {
                let power = products.reduce(0) { $0 + evaluate($1.voltage) * x[$1.current] }
                solution.powerValues[component.id] = cleaned(omega == nil ? power : power / 2, scale: voltageScale * currentScale)
                solution.solvedCount += 1
            } else if solution.isConsistent {
                issues.append(SolverIssue(
                    kind: .missing,
                    title: "\(component.powerName) kan ikke beregnes endnu",
                    detail: "Effekten i \(component.name) kræver både spændingen over og strømmen gennem \(component.name). Der mangler flere kendte værdier i den del af kredsløbet."
                ))
            }
        }

        // Each diode's current (anode to cathode) and voltage, for checking
        // its state like by hand.
        if solution.isConsistent, omega == nil {
            for component in circuit.components where component.kind.isDiode {
                guard let current = currentVariable(component.id) else { continue }
                // No voltage variable is the 0 V reference.
                let start = self.voltage(at: component.start).map { x[$0] } ?? 0
                let end = self.voltage(at: component.end).map { x[$0] } ?? 0
                solution.diodeValues[component.id] = (voltage: start - end, current: x[current])
                if component.kind == .led, x[current] > LEDModel.ratedCurrent * (1 + 1e-6) {
                    issues.append(LEDModel.overcurrentIssue(name: component.name, current: x[current]))
                    solution.ledOvercurrent[component.id] = x[current]
                }
            }
        }

        solution.issues = issues
        return solution
    }

    /// The diode whose assumed state fits the solution worst, or `nil` if all
    /// fit: a conducting diode must carry current forwards, and a blocking
    /// one can't have more than its forward voltage across it.
    func worstDiodeViolation() -> UUID? {
        guard omega == nil else { return nil }
        var worst: (id: UUID, amount: Double)?
        for component in circuit.components where component.kind.isDiode {
            let amount: Double
            if conducting.contains(component.id) {
                guard let current = currentVariable(component.id) else { continue }
                // Relative to 1 mA, so tiny numerical noise doesn't count.
                amount = -point[current] / 1e-3
            } else {
                let start = voltage(at: component.start).map { point[$0] } ?? 0
                let end = voltage(at: component.end).map { point[$0] } ?? 0
                let forward = component.value ?? parameterVariable[component.id].map { point[$0] } ?? 0
                amount = (start - end - forward) / max(abs(forward), 0.1)
            }
            if amount > 1e-6, amount > (worst?.amount ?? 0) { worst = (component.id, amount) }
        }
        return worst?.id
    }

    /// Whether every equation holds at `x`.
    private func satisfiesAll(_ x: [Double]) -> Bool {
        equations.allSatisfy { abs($0.value(x)) <= 1e-6 * $0.magnitude(x) + 1e-9 }
    }

    /// Runs the solver from several starting guesses for the unknown
    /// resistances, since with more than one of them a single start can get
    /// stuck. Returns the first solution that satisfies all equations, or the
    /// best one found.
    private func bestSolution() -> [Double] {
        // Without unknown resistances every equation is linear, and one
        // least-squares step from the start is the answer, when it's unique.
        if equations.allSatisfy({ $0.bilinear.isEmpty && $0.exponential.isEmpty }), let x = linearSolution() {
            return x
        }
        let logResistances = kinds.indices.filter { kinds[$0] == .logResistance }
        var starts = [initial]
        if !logResistances.isEmpty {
            let guesses: [Double] = [100, 10, 10_000, 1, 100_000]
            for guess in guesses {
                var start = initial
                for index in logResistances { start[index] = log(guess) }
                starts.append(start)
            }
            // Mixed guesses, so the unknown resistances can differ a lot.
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for _ in 0..<12 {
                var start = initial
                for index in logResistances {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let fraction = Double(seed >> 11) / Double(1 << 53)
                    start[index] = log(1) + fraction * (log(1_000_000) - log(1))
                }
                starts.append(start)
            }
        }

        var best: (x: [Double], cost: Double)?
        for start in starts {
            let result = levenbergMarquardt(from: start)
            if satisfiesAll(result.x) { return result.x }
            if result.cost < (best?.cost ?? .infinity) { best = result }
        }
        return best?.x ?? initial
    }

    /// The least-squares solution of linear equations (rows scaled like in
    /// `levenbergMarquardt`), or `nil` if it isn't unique; then some values
    /// are free, and the damped search keeps them near their start.
    private func linearSolution() -> [Double]? {
        let count = kinds.count
        var normal = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        var rhs = [Double](repeating: 0, count: count)
        for equation in equations {
            let gradient = equation.gradient(initial, count: count)
            let norm = sqrt(gradient.reduce(0) { $0 + $1 * $1 })
            let weight = norm > 1e-12 ? 1 / norm : 1
            let residual = equation.value(initial) * weight
            let nonzero = gradient.indices.filter { gradient[$0] != 0 }
            for i in nonzero {
                let gi = gradient[i] * weight
                rhs[i] -= gi * residual
                for j in nonzero { normal[i][j] += gi * gradient[j] * weight }
            }
        }
        guard let step = LinearAlgebra.solveRegular(normal, rhs) else { return nil }
        let x = zip(initial, step).map(+)
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Finds a point near `start` where all equations hold as well as possible.
    private func levenbergMarquardt(from start: [Double]) -> (x: [Double], cost: Double) {
        let count = kinds.count
        var x = start
        var lambda = 1e-3
        var finalCost = Double.infinity

        for _ in 0..<500 {
            // Rows are scaled to unit gradient so volts and amperes weigh alike.
            let gradients = equations.map { $0.gradient(x, count: count) }
            let weights = gradients.map { gradient -> Double in
                let norm = sqrt(gradient.reduce(0) { $0 + $1 * $1 })
                return norm > 1e-12 ? 1 / norm : 1
            }
            func cost(_ point: [Double]) -> Double {
                zip(equations, weights).reduce(0) { sum, pair in
                    let r = pair.0.value(point) * pair.1
                    return sum + r * r
                }
            }
            let currentCost = cost(x)
            finalCost = currentCost
            if currentCost < 1e-26 { break }

            var normal = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
            var rhs = [Double](repeating: 0, count: count)
            for (row, equation) in equations.enumerated() {
                let weight = weights[row]
                let residual = equation.value(x) * weight
                let gradient = gradients[row]
                for i in 0..<count where gradient[i] != 0 {
                    let gi = gradient[i] * weight
                    rhs[i] -= gi * residual
                    for j in 0..<count where gradient[j] != 0 {
                        normal[i][j] += gi * gradient[j] * weight
                    }
                }
            }

            var accepted = false
            for _ in 0..<12 {
                var damped = normal
                for i in 0..<count {
                    damped[i][i] += lambda * (normal[i][i] + 1e-9)
                }
                guard let step = LinearAlgebra.solve(damped, rhs) else { lambda *= 4; continue }
                let candidate = zip(x, step).map(+)
                if cost(candidate) < currentCost {
                    x = candidate
                    lambda = max(lambda / 3, 1e-12)
                    accepted = true
                    break
                }
                lambda *= 4
            }
            if !accepted { break }
        }
        return (x, finalCost)
    }
}

// MARK: - Rank tests

/// Decides whether a quantity is uniquely determined by the equations near
/// the solution: its gradient must lie in the row space of the Jacobian.
nonisolated private struct RankTester {
    let rows: [[Double]]
    let scales: [Double]
    let baseRank: Int

    init(equations: [Equation], x: [Double], kinds: [Model.VariableKind]) {
        let count = x.count
        // Scale columns to typical sizes so volts, amperes and ohms compare fairly.
        let voltageScale = max(1, zip(x, kinds).filter { $0.1 == .voltage }.map { abs($0.0) }.max() ?? 0)
        let currentScale = max(voltageScale / 1e6, zip(x, kinds).filter { $0.1 == .current }.map { abs($0.0) }.max() ?? 0)
        scales = zip(x, kinds).map { value, kind in
            switch kind {
            case .voltage: voltageScale
            case .current: currentScale
            case .parameter: max(abs(value), 1e-9)
            case .logResistance: 1
            }
        }
        let scales = scales
        rows = equations.map { equation in
            let gradient = equation.gradient(x, count: count)
            return RankTester.normalized(zip(gradient, scales).map(*))
        }
        baseRank = LinearAlgebra.rank(rows)
    }

    private static func normalized(_ row: [Double]) -> [Double] {
        let norm = sqrt(row.reduce(0) { $0 + $1 * $1 })
        return norm > 1e-300 ? row.map { $0 / norm } : row
    }

    private func row(_ expression: [Int: Double]) -> [Double] {
        var result = [Double](repeating: 0, count: scales.count)
        for (index, coefficient) in expression { result[index] = coefficient * scales[index] }
        return RankTester.normalized(result)
    }

    func isDetermined(_ expression: [Int: Double]) -> Bool {
        if expression.values.allSatisfy({ $0 == 0 }) { return true }
        return LinearAlgebra.rank(rows + [row(expression)]) == baseRank
    }

    /// Whether the quantity would be determined if `helper` were known too.
    func isDetermined(_ expression: [Int: Double], given helper: [Int: Double]) -> Bool {
        let withHelper = rows + [row(helper)]
        return LinearAlgebra.rank(withHelper + [row(expression)]) == LinearAlgebra.rank(withHelper)
    }
}

// MARK: - Linear algebra

nonisolated enum LinearAlgebra {
    /// Solves `A·x = b` with complex numbers by Gaussian elimination with
    /// partial pivoting.
    static func solve(_ matrix: [[Complex]], _ vector: [Complex]) -> [Complex]? {
        let n = vector.count
        var a = matrix
        var b = vector
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { a[$0][column].magnitude < a[$1][column].magnitude }),
                  a[pivot][column].magnitude > 1e-300 else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n where a[row][column] != .zero {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Complex](repeating: .zero, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }

    /// Solves `A·x = b` by Gaussian elimination with partial pivoting.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var a = matrix
        var b = vector
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-300 else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n where a[row][column] != 0 {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }

    /// Solves a square system, or `nil` if it's singular or nearly so (a
    /// pivot below 1e-11 of the largest), so free directions aren't given
    /// arbitrary huge values.
    static func solveRegular(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var a = matrix
        var b = vector
        let largest = matrix.flatMap { $0.map(abs) }.max() ?? 0
        guard largest > 0 else { return n == 0 ? [] : nil }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-11 * largest else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n where a[row][column] != 0 {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }

    /// Numerical rank by Gaussian elimination with full pivoting.
    static func rank(_ matrix: [[Double]], tolerance: Double = 1e-9) -> Int {
        var a = matrix
        let rows = a.count
        guard rows > 0 else { return 0 }
        let columns = a[0].count
        var rank = 0
        var usedColumns = Set<Int>()
        while rank < rows {
            var best = (row: -1, column: -1, value: tolerance)
            for row in rank..<rows {
                for column in 0..<columns where !usedColumns.contains(column) && abs(a[row][column]) > best.value {
                    best = (row, column, abs(a[row][column]))
                }
            }
            guard best.row >= 0 else { break }
            a.swapAt(rank, best.row)
            usedColumns.insert(best.column)
            let pivot = a[rank][best.column]
            for row in (rank + 1)..<rows where a[row][best.column] != 0 {
                let factor = a[row][best.column] / pivot
                for column in 0..<columns { a[row][column] -= factor * a[rank][column] }
            }
            rank += 1
        }
        return rank
    }
}
