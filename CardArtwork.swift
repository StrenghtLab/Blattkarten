import SwiftUI

enum CardArtwork {
    case neuron, synapse, brain, impulse, cell, movement, parabola, molecule
    case series, parallel, ammeter, voltmeter, comparison, water, formula, currentFormula, resistanceFormula, currentUnit, voltageUnit, resistanceUnit, conversion, currentConversion, resistanceConversion, unit, concept

    init(_ card: Card) {
        let text = card.question.lowercased()
        let topic = text + " " + card.answer.lowercased()
        if text.contains("synapse") { self = .synapse }
        else if text.contains("aktionspotenzial") { self = .impulse }
        else if text.contains("neuron") || text.contains("myelinscheide") { self = .neuron }
        else if text.contains("nervensystem") || text.contains("gehirn") { self = .brain }
        else if text.contains("wassermodell") || text.contains("wasserrad") { self = .water }
        else if text.contains("amperemeter") { self = .ammeter }
        else if text.contains("voltmeter") { self = .voltmeter }
        else if text.contains("ohmsch") || text.contains("widerstand steigt") {
            if card.answer.hasPrefix("I =") { self = .currentFormula }
            else if card.answer.hasPrefix("R =") { self = .resistanceFormula }
            else { self = .formula }
        }
        else if text.contains("milliampere") && text.contains("um?") && text.contains("kiloohm") { self = .conversion }
        else if text.contains("milliampere") && text.contains("um?") { self = .currentConversion }
        else if text.contains("kiloohm") && text.contains("um?") { self = .resistanceConversion }
        else if text.contains("welche einheit") || text.contains("welcher einheit") {
            if text.contains("stromstärke") { self = .currentUnit }
            else if text.contains("spannung") { self = .voltageUnit }
            else if text.contains("widerstand") { self = .resistanceUnit }
            else { self = .unit }
        }
        else if text.contains("reihen-") && text.contains("parallel") { self = .comparison }
        else if text.contains("parallel") { self = .parallel }
        else if text.contains("reihenschaltung") { self = .series }
        else if topic.contains("zellkern") || topic.contains("zellmembran") || topic.contains("mitochondri") { self = .cell }
        else if text.contains("geschwindigkeit") || text.contains("beschleunigung") { self = .movement }
        else if topic.contains("parabel") || (topic.contains("quadratisch") && topic.contains("funktion")) { self = .parabola }
        else if topic.contains("wassermolekül") { self = .molecule }
        else { self = .concept }
    }

    var caption: String? {
        switch self {
        case .cell: "Zelle im Querschnitt"
        case .movement: "Geschwindigkeitsvektoren"
        case .parabola: "Beispiel einer Parabel"
        case .molecule: "Wassermolekül"
        case .neuron: "Nervenzelle"
        case .synapse: "Synapse"
        case .series: "Reihenschaltung"
        case .parallel: "Parallelschaltung"
        default: nil
        }
    }

}

struct CardIllustration: View {
    let artwork: CardArtwork
    var reveal = true

    var body: some View {
        if [.neuron, .synapse, .brain, .impulse].contains(artwork) {
            neuroSketch
        } else if [.cell, .movement, .parabola, .molecule].contains(artwork) {
            topicSketch
        } else if artwork == .comparison {
            HStack(spacing: 8) {
                circuit(.series)
                circuit(.parallel)
            }
        } else if let units {
            VStack(spacing: 4) {
                ForEach(units.indices, id: \.self) { index in
                    HStack(spacing: 9) {
                        unitTile(units[index].0)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                        unitTile(units[index].1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if artwork == .water {
            water
        } else if [.series, .parallel, .ammeter, .voltmeter].contains(artwork) {
            circuit(artwork)
        } else {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                if reveal, let formula {
                    Text(formula).font(.system(.headline, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var topicSketch: some View {
        Canvas { context, size in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
            func line(_ points: [CGPoint]) {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            let teal = Color(red: 0.05, green: 0.42, blue: 0.35)
            let violet = Color(red: 0.37, green: 0.24, blue: 0.71)
            let blue = Color(red: 0.10, green: 0.38, blue: 0.63)
            let coral = Color(red: 0.69, green: 0.23, blue: 0.32)
            func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, color: Color) {
                let shape = Path(ellipseIn: CGRect(origin: p(x, y), size: CGSize(width: w * size.width, height: h * size.height)))
                context.fill(shape, with: .color(color.opacity(0.16)))
                context.stroke(shape, with: .color(color), lineWidth: 1.6)
            }
            func label(_ title: String, at point: CGPoint, color: Color) {
                guard size.width >= 78 else { return }
                var text = context.resolve(Text(title).font(.system(size: size.width > 120 ? 10 : 7, weight: .semibold)))
                text.shading = .color(color)
                context.draw(text, at: point)
            }
            switch artwork {
            case .cell:
                oval(0.08, 0.09, 0.72, 0.82, color: teal)
                oval(0.31, 0.23, 0.27, 0.51, color: violet)
                oval(0.21, 0.41, 0.09, 0.13, color: teal)
                oval(0.62, 0.56, 0.11, 0.12, color: teal)
                line([p(0.54, 0.31), p(0.68, 0.18), p(0.80, 0.18)])
                label("Kern", at: p(0.88, 0.18), color: violet)
            case .movement:
                line([p(0.20, 0.73), p(0.50, 0.73), p(0.42, 0.59)])
                line([p(0.50, 0.73), p(0.42, 0.87)])
                line([p(0.20, 0.30), p(0.77, 0.30), p(0.69, 0.16)])
                line([p(0.77, 0.30), p(0.69, 0.44)])
                label("v₁", at: p(0.58, 0.73), color: teal)
                label("v₂", at: p(0.86, 0.30), color: teal)
            case .parabola:
                line([p(0.15, 0.79), p(0.86, 0.79)])
                line([p(0.50, 0.91), p(0.50, 0.11)])
                var path = Path()
                path.move(to: p(0.23, 0.17))
                path.addQuadCurve(to: p(0.77, 0.17), control: p(0.50, 1.41))
                context.stroke(path, with: .color(violet), lineWidth: 2.2)
                label("x", at: p(0.91, 0.79), color: violet)
                label("y", at: p(0.56, 0.10), color: violet)
            case .molecule:
                line([p(0.34, 0.55), p(0.44, 0.35)])
                line([p(0.56, 0.35), p(0.66, 0.55)])
                oval(0.38, 0.06, 0.24, 0.44, color: coral)
                oval(0.22, 0.48, 0.19, 0.36, color: blue)
                oval(0.59, 0.48, 0.19, 0.36, color: blue)
                label("O", at: p(0.50, 0.28), color: coral)
                label("H", at: p(0.315, 0.66), color: blue)
                label("H", at: p(0.685, 0.66), color: blue)
            default: break
            }
        }
        .aspectRatio(1.65, contentMode: .fit)
    }

    private var neuroSketch: some View {
        Canvas { context, size in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
            func line(_ points: [CGPoint]) {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                let center = p(x, y)
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .foreground)
            }
            switch artwork {
            case .neuron:
                dot(0.35, 0.5, size.height * 0.13)
                line([p(0.35, 0.5), p(0.18, 0.17), p(0.07, 0.24)])
                line([p(0.35, 0.5), p(0.16, 0.57), p(0.06, 0.43)])
                line([p(0.35, 0.5), p(0.16, 0.83), p(0.08, 0.77)])
                line([p(0.35, 0.5), p(0.78, 0.5), p(0.91, 0.23)])
                line([p(0.78, 0.5), p(0.91, 0.77)])
            case .synapse:
                line([p(0.25, 0.19), p(0.36, 0.35), p(0.64, 0.35), p(0.75, 0.19)])
                line([p(0.25, 0.81), p(0.36, 0.65), p(0.64, 0.65), p(0.75, 0.81)])
                for x in [0.4, 0.5, 0.6] { dot(x, 0.5, 2) }
            case .brain:
                let rect = CGRect(x: size.width * 0.19, y: size.height * 0.12, width: size.width * 0.62, height: size.height * 0.76)
                context.stroke(Path(roundedRect: rect, cornerRadius: size.height * 0.23), with: .foreground, lineWidth: 2)
                line([p(0.5, 0.15), p(0.48, 0.36), p(0.52, 0.62), p(0.5, 0.86)])
                line([p(0.24, 0.44), p(0.34, 0.36), p(0.4, 0.50)])
                line([p(0.6, 0.55), p(0.67, 0.40), p(0.76, 0.45)])
            default:
                line([p(0.12, 0.70), p(0.32, 0.70), p(0.48, 0.15), p(0.62, 0.81), p(0.76, 0.70), p(0.9, 0.70)])
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
    }

    private var units: [(String, String)]? {
        switch artwork {
        case .currentUnit: [("I", "A")]
        case .voltageUnit: [("U", "V")]
        case .resistanceUnit: [("R", "Ω")]
        case .conversion: [("1.000 mA", "1 A"), ("1 kΩ", "1.000 Ω")]
        case .currentConversion: [("1.000 mA", "1 A")]
        case .resistanceConversion: [("1 kΩ", "1.000 Ω")]
        default: nil
        }
    }

    private func unitTile(_ text: String) -> some View {
        Text(text)
            .font(.system(size: artwork == .conversion ? 9 : 16, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, artwork == .conversion ? 2 : 4)
            .background(.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private var formula: String? {
        switch artwork {
        case .formula: "U = R · I"
        case .currentFormula: "I = U / R"
        case .resistanceFormula: "R = U / I"
        default: nil
        }
    }

    private var symbol: String {
        switch artwork {
        case .water: "water.waves"
        case .formula, .currentFormula, .resistanceFormula: "function"
        case .unit: "ruler"
        default: "book.closed"
        }
    }

    private var water: some View {
        Canvas { context, size in
            let unit = size.height / 56
            let center = CGPoint(x: size.width * 0.62, y: size.height * 0.53)
            var channel = Path()
            channel.move(to: CGPoint(x: size.width * 0.12, y: size.height * 0.23))
            channel.addLine(to: CGPoint(x: size.width * 0.40, y: size.height * 0.23))
            channel.addQuadCurve(to: CGPoint(x: size.width * 0.47, y: size.height * 0.54),
                                 control: CGPoint(x: size.width * 0.47, y: size.height * 0.23))
            channel.addLine(to: CGPoint(x: center.x - 15 * unit, y: center.y))
            channel.move(to: CGPoint(x: size.width * 0.17, y: size.height * 0.84))
            channel.addLine(to: CGPoint(x: size.width * 0.90, y: size.height * 0.84))
            context.stroke(channel, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            let radius = 14 * unit
            let wheel = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: wheel), with: .foreground, lineWidth: 1.5)
            for index in 0..<8 {
                let angle = Double(index) * .pi / 4
                var spoke = Path()
                spoke.move(to: center)
                spoke.addLine(to: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
                context.stroke(spoke, with: .foreground, lineWidth: 1)
            }
        }
        .aspectRatio(2.5, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func circuit(_ kind: CardArtwork) -> some View {
        Canvas { context, size in
            let sx = size.width / 132
            let sy = size.height / 76
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            func wire(_ points: [CGPoint]) {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            }
            func resistor(_ x: CGFloat, _ y: CGFloat) {
                let rect = CGRect(x: x * sx, y: (y - 5) * sy, width: 23 * sx, height: 10 * sy)
                context.stroke(Path(roundedRect: rect, cornerRadius: 1.5), with: .foreground, lineWidth: 1.35)
            }
            func meter(_ x: CGFloat, _ y: CGFloat, _ label: String) {
                let center = point(x, y)
                let radius = min(8 * sx, 9 * sy)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .foreground, lineWidth: 1.35)
                context.draw(Text(label).font(.system(size: max(5, radius * 1.25), weight: .bold)), at: center)
            }
            func dot(_ x: CGFloat, _ y: CGFloat) {
                let p = point(x, y)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.7, y: p.y - 1.7, width: 3.4, height: 3.4)), with: .foreground)
            }

            wire([point(16,31), point(16,18), point(kind == .ammeter ? 36 : 53,18)])
            if kind == .series {
                wire([point(16,43), point(16,62), point(53,62)])
                resistor(53,62)
                wire([point(76,62), point(116,62), point(116,18), point(76,18)])
            } else {
                wire([point(16,43), point(16,62), point(116,62), point(116,18), point(76,18)])
            }
            wire([point(7,31), point(25,31)])
            wire([point(11,43), point(21,43)])
            resistor(53,18)

            switch kind {
            case .ammeter:
                meter(44.5,18,"A")
            case .voltmeter, .parallel:
                wire([point(43,18), point(43,37), point(kind == .voltmeter ? 57 : 53,37)])
                wire([point(76,37), point(86,37), point(86,18)])
                dot(43,18)
                dot(86,18)
                if kind == .parallel { resistor(53,37) }
                else {
                    meter(65,37,"V")
                    wire([point(74,37), point(76,37)])
                }
            default:
                break
            }
        }
        .aspectRatio(132.0 / 76.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
