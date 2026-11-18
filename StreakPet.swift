import SwiftUI
import WidgetKit

struct StreakPet: Codable {
    var lastDay: Date?
    var streak = 0
    var record = 0
    var answers = 0
    var worksheets = 0
    var outfit = 0

    var unlocked: Int { min(Outfit.count, 1 + record + answers / 5 + worksheets) }

    func streak(at now: Date = .now, calendar: Calendar = .current) -> Int {
        guard let lastDay else { return 0 }
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastDay),
                                          to: calendar.startOfDay(for: now)).day ?? 0
        return (0...1).contains(gap) ? streak : 0
    }

    mutating func activity(worksheet: Bool, at now: Date = .now, calendar: Calendar = .current) {
        if worksheet { worksheets += 1 } else { answers += 1 }
        let day = calendar.startOfDay(for: now)
        if let lastDay, calendar.isDate(lastDay, inSameDayAs: day) { return }
        if let lastDay, lastDay > day { return }
        streak = streak(at: now, calendar: calendar) + 1
        lastDay = day
        record = max(record, streak)
    }

    static let group = "group.de.blattkarten.mac.streak"
    static let widgetKind = "BlattkartenStreak"

    private static var snapshotURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("StreakPet.json")
    }

    func publish() {
        if let url = Self.snapshotURL, let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    static func widgetSnapshot() -> StreakPet {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let pet = try? JSONDecoder().decode(StreakPet.self, from: data) else { return StreakPet() }
        return pet
    }
}

struct Outfit {
    static let count = 365
    static let garments = ["Hoodie", "Schal", "Weste", "Cape", "Pullover", "Jacke", "Poncho", "Latzhose"]
    static let colors: [(String, Color)] = [
        ("Minze", Color(red: 0.40, green: 0.92, blue: 0.70)),
        ("Lavendel", Color(red: 0.64, green: 0.53, blue: 0.98)),
        ("Koralle", Color(red: 0.99, green: 0.43, blue: 0.41)),
        ("Himmelblau", Color(red: 0.31, green: 0.72, blue: 1)),
        ("Zitrone", Color(red: 0.98, green: 0.81, blue: 0.30)),
        ("Rosé", Color(red: 0.96, green: 0.52, blue: 0.78)),
        ("Türkis", Color(red: 0.25, green: 0.82, blue: 0.85)),
        ("Nachtblau", Color(red: 0.37, green: 0.43, blue: 0.77))
    ]
    static let accessories = ["Mütze", "Krone", "Schleife", "Kappe", "Stern", "Kopfhörer"]
    let index: Int
    var garment: Int { index % Self.garments.count }
    var color: Int { (index / Self.garments.count) % Self.colors.count }
    var accessory: Int { (index / (Self.garments.count * Self.colors.count) + index) % Self.accessories.count }
    var shade: Color { Self.colors[color].1 }
    var name: String { "\(Self.garments[garment]) · \(Self.colors[color].0) · \(Self.accessories[accessory])" }

    init(_ index: Int) { self.index = min(max(0, index), Self.count - 1) }
}

struct FlamePet: View {
    let outfit: Outfit

    var body: some View {
        Canvas { context, size in
            let art = FlameDrawing(context: context, size: size)
            art.draw(outfit: outfit)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Flamme im Outfit \(outfit.name)")
    }
}

private struct FlameDrawing {
    let context: GraphicsContext
    let scale: CGFloat
    let origin: CGPoint

    private let ink = Color(red: 0.21, green: 0.09, blue: 0.25)
    private let butter = Color(red: 1.0, green: 0.92, blue: 0.57)
    private let ember = Color(red: 1.0, green: 0.37, blue: 0.24)
    private let orange = Color(red: 1.0, green: 0.56, blue: 0.23)
    private let gold = Color(red: 1.0, green: 0.76, blue: 0.32)

    init(context: GraphicsContext, size: CGSize) {
        self.context = context
        scale = min(size.width, size.height) / 120
        origin = CGPoint(x: (size.width - 120 * scale) / 2, y: (size.height - 120 * scale) / 2)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(origin: p(x, y), size: CGSize(width: w * scale, height: h * scale))
    }

    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
        context.fill(Path(ellipseIn: r(x, y, w, h)), with: .color(color))
    }

    private func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat, _ color: Color) {
        let path = Path(roundedRect: r(x, y, w, h), cornerRadius: radius * scale)
        context.fill(path, with: .color(color))
    }

    private func stroke(_ path: Path, _ color: Color, width: CGFloat) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round))
    }

    private func curve(_ start: CGPoint, _ end: CGPoint, _ control: CGPoint, _ color: Color, width: CGFloat) {
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        stroke(path, color, width: width)
    }

    private func fill(_ path: Path, _ colors: [Color], from start: CGPoint, to end: CGPoint) {
        context.fill(path, with: .linearGradient(Gradient(colors: colors), startPoint: start, endPoint: end))
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    func draw(outfit: Outfit) {
        let haze = Path(ellipseIn: r(6, 8, 108, 105))
        context.fill(haze, with: .radialGradient(Gradient(colors: [orange.opacity(0.33), .clear]),
                                                center: p(60, 65), startRadius: 8 * scale, endRadius: 52 * scale))
        ellipse(29, 108, 62, 6, ink.opacity(0.29))
        drawSpark(x: 20, y: 44, size: 4, color: gold)
        drawSpark(x: 101, y: 51, size: 5, color: butter)
        ellipse(94, 30, 3, 4, orange.opacity(0.8))
        ellipse(17, 59, 3, 3, ember.opacity(0.85))

        let shell = silhouette()
        fill(shell, [butter, gold, orange, ember], from: p(36, 24), to: p(92, 103))
        stroke(shell, ember.opacity(0.72), width: 0.8)
        drawCore()
        drawFace()
        drawClothes(outfit)
        drawAccessory(outfit)
    }

    private func silhouette() -> Path {
        var path = Path()
        path.move(to: p(69, 6))
        path.addCurve(to: p(51, 35), control1: p(65, 18), control2: p(50, 24))
        path.addCurve(to: p(45, 49), control1: p(52, 41), control2: p(48, 46))
        path.addCurve(to: p(35, 35), control1: p(39, 49), control2: p(33, 42))
        path.addCurve(to: p(22, 67), control1: p(23, 43), control2: p(20, 56))
        path.addCurve(to: p(26, 91), control1: p(18, 75), control2: p(20, 85))
        path.addCurve(to: p(59, 106), control1: p(32, 102), control2: p(45, 106))
        path.addCurve(to: p(94, 91), control1: p(75, 106), control2: p(88, 102))
        path.addCurve(to: p(98, 60), control1: p(101, 81), control2: p(102, 70))
        path.addCurve(to: p(89, 47), control1: p(96, 55), control2: p(93, 50))
        path.addCurve(to: p(85, 58), control1: p(91, 51), control2: p(90, 55))
        path.addCurve(to: p(77, 37), control1: p(85, 49), control2: p(81, 43))
        path.addCurve(to: p(69, 6), control1: p(70, 27), control2: p(62, 22))
        path.closeSubpath()
        return path
    }

    private func drawCore() {
        var core = Path()
        core.move(to: p(65, 29))
        core.addCurve(to: p(76, 54), control1: p(65, 40), control2: p(77, 44))
        core.addCurve(to: p(80, 62), control1: p(75, 60), control2: p(77, 61))
        core.addCurve(to: p(88, 78), control1: p(83, 60), control2: p(90, 73))
        core.addCurve(to: p(62, 102), control1: p(86, 93), control2: p(75, 101))
        core.addCurve(to: p(32, 86), control1: p(48, 103), control2: p(37, 97))
        core.addCurve(to: p(41, 62), control1: p(30, 79), control2: p(32, 68))
        core.addCurve(to: p(50, 57), control1: p(43, 66), control2: p(50, 63))
        core.addCurve(to: p(65, 29), control1: p(48, 45), control2: p(61, 40))
        core.closeSubpath()
        fill(core, [.white.opacity(0.58), butter, gold.opacity(0.74)], from: p(51, 36), to: p(68, 99))
        curve(p(30, 70), p(35, 53), p(30, 59), .white.opacity(0.43), width: 2.0)
        curve(p(58, 37), p(65, 21), p(62, 29), .white.opacity(0.61), width: 1.4)
    }

    private func drawFace() {
        curve(p(43, 62), p(52, 60), p(47, 57), ink.opacity(0.55), width: 1.25)
        curve(p(66, 60), p(75, 62), p(71, 56), ink.opacity(0.55), width: 1.25)
        ellipse(44, 64, 11, 14, ink)
        ellipse(65, 64, 12, 14, ink)
        ellipse(45.5, 65.5, 4, 4, .white)
        ellipse(67, 65.5, 4.3, 4.3, .white)
        ellipse(50, 73, 2, 2, Color.pink.opacity(0.72))
        ellipse(72.5, 73, 2.1, 2.1, Color.pink.opacity(0.72))
        ellipse(35.5, 76, 9, 4, ember.opacity(0.5))
        ellipse(77.5, 76, 9, 4, ember.opacity(0.5))
        ellipse(38, 75.8, 2, 1.3, .white.opacity(0.95))
        ellipse(80, 75.8, 2, 1.3, .white.opacity(0.95))
        var smile = Path()
        smile.move(to: p(55, 77))
        smile.addQuadCurve(to: p(66, 77), control: p(60.5, 79.5))
        smile.addQuadCurve(to: p(55, 77), control: p(60.5, 88))
        smile.closeSubpath()
        context.fill(smile, with: .color(ink))
        ellipse(59, 81.3, 3.5, 1.2, Color(red: 1, green: 0.43, blue: 0.52))
    }

    private func drawClothes(_ outfit: Outfit) {
        let base = outfit.shade
        let seam = ink.opacity(0.37)
        let glint = Color.white.opacity(0.54)
        let path: Path
        switch outfit.garment {
        case 1: path = polygon([p(31, 86), p(88, 86), p(91, 93), p(78, 94), p(82, 105), p(72, 104), p(68, 95), p(34, 94)])
        case 2: path = polygon([p(36, 88), p(51, 88), p(61, 96), p(72, 88), p(85, 88), p(88, 99), p(78, 105), p(44, 105)])
        case 3: path = polygon([p(44, 85), p(77, 85), p(91, 101), p(76, 107), p(41, 106), p(31, 102)])
        case 4: path = Path(roundedRect: r(32, 86, 56, 19), cornerRadius: 8 * scale)
        case 5: path = Path(roundedRect: r(33, 86, 54, 19), cornerRadius: 7.5 * scale)
        case 6: path = polygon([p(44, 85), p(77, 85), p(92, 100), p(61, 108), p(29, 100)])
        case 7: path = polygon([p(40, 103), p(44, 90), p(44, 86), p(49, 86), p(51, 91), p(70, 91), p(73, 86), p(78, 86), p(79, 92), p(83, 103), p(74, 108), p(49, 108)])
        default: path = Path(roundedRect: r(33, 87, 55, 19), cornerRadius: 8 * scale)
        }
        fill(path, [base, base, ink.opacity(0.76)], from: p(38, 82), to: p(87, 115))
        stroke(path, seam, width: 0.9)

        switch outfit.garment {
        case 1:
            for y in [89.0, 92.0] { curve(p(38, y), p(83, y), p(60, y + 2), glint, width: 0.65) }
        case 2:
            curve(p(61, 96), p(61, 104), p(61, 100), seam, width: 1)
            ellipse(66, 98, 2.5, 2.5, glint)
        case 3:
            ellipse(58, 86, 5, 5, butter)
            curve(p(47, 91), p(42, 101), p(44, 95), glint, width: 0.7)
        case 4:
            for y in [92.0, 96.0, 100.0] { curve(p(39, y), p(81, y), p(60, y + 1), glint, width: 0.85) }
        case 5:
            curve(p(61, 87), p(61, 104), p(61, 96), seam, width: 1.4)
            pill(59, 91, 4, 2.5, 0.8, butter)
        case 6:
            curve(p(45, 91), p(76, 91), p(60, 96), butter.opacity(0.76), width: 1)
            curve(p(38, 97), p(83, 97), p(60, 106), glint, width: 0.8)
        case 7:
            ellipse(48, 91, 3, 3, butter)
            ellipse(72, 91, 3, 3, butter)
            pill(54, 97, 14, 6, 2, seam)
        default:
            let pocket = polygon([p(54, 97), p(68, 97), p(73, 102), p(49, 102)])
            context.fill(pocket, with: .color(seam))
            curve(p(53, 89), p(54, 94), p(54, 91), glint, width: 1)
            curve(p(68, 89), p(67, 94), p(68, 91), glint, width: 1)
        }
    }

    private func drawAccessory(_ outfit: Outfit) {
        let accent = outfit.shade
        let glow = Color.white.opacity(0.65)
        switch outfit.accessory {
        case 1:
            let crown = polygon([p(44, 49), p(41, 36), p(51, 42), p(59, 33), p(65, 42), p(74, 37), p(72, 50)])
            fill(crown, [butter, accent], from: p(45, 36), to: p(70, 52))
            stroke(crown, ink.opacity(0.26), width: 0.8)
            ellipse(54, 45, 3.5, 3.5, .white)
        case 2:
            let bow = polygon([p(46, 43), p(33, 37), p(35, 50), p(47, 48), p(58, 52), p(60, 38)])
            fill(bow, [glow, accent], from: p(34, 36), to: p(56, 52))
            ellipse(44, 42, 7, 7, accent)
            ellipse(45, 43, 2, 2, glow)
        case 3:
            pill(46, 37, 29, 12, 6, accent)
            pill(60, 46, 26, 4.5, 2, accent)
            curve(p(49, 41), p(68, 39), p(57, 37), glow, width: 1)
        case 4:
            drawSpark(x: 57, y: 43, size: 10, color: butter)
            drawSpark(x: 65, y: 48, size: 3.5, color: accent)
        case 5:
            curve(p(38, 65), p(84, 65), p(62, 34), accent, width: 4.5)
            pill(33, 61, 9, 13, 3, accent)
            pill(80, 61, 9, 13, 3, accent)
            pill(34, 63, 2.2, 7, 1, glow)
        default:
            var cap = Path()
            cap.move(to: p(39, 47))
            cap.addCurve(to: p(68, 42), control1: p(37, 33), control2: p(59, 29))
            cap.addQuadCurve(to: p(72, 48), control: p(72, 45))
            cap.addQuadCurve(to: p(40, 51), control: p(56, 46))
            cap.closeSubpath()
            fill(cap, [accent.opacity(0.88), accent, ink.opacity(0.72)], from: p(40, 33), to: p(69, 58))
            stroke(cap, ink.opacity(0.25), width: 0.8)
            curve(p(41, 48), p(69, 45), p(53, 43), glow, width: 1.05)
            ellipse(50, 31, 7, 6, butter)
        }
    }

    private func drawSpark(x: CGFloat, y: CGFloat, size: CGFloat, color: Color) {
        let star = polygon([p(x, y-size), p(x+size*0.22, y-size*0.22), p(x+size, y),
                            p(x+size*0.22, y+size*0.22), p(x, y+size), p(x-size*0.22, y+size*0.22),
                            p(x-size, y), p(x-size*0.22, y-size*0.22)])
        context.fill(star, with: .color(color))
    }
}
