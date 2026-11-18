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
            let scale = min(size.width, size.height) / 120
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (size.width - 120 * scale) / 2 + x * scale,
                        y: (size.height - 120 * scale) / 2 + y * scale)
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(origin: pt(x,y), size: CGSize(width: w * scale, height: h * scale))
            }
            func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                context.fill(Path(ellipseIn: rect(x,y,w,h)), with: .color(color))
            }
            func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: Color) {
                context.fill(Path(roundedRect: rect(x,y,w,h), cornerRadius: r * scale), with: .color(color))
            }
            func polygon(_ points: [CGPoint], _ color: Color) {
                var path = Path()
                path.addLines(points)
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            let ink = Color(red: 0.20, green: 0.12, blue: 0.29)
            let cloth = outfit.shade
            oval(27,105,66,7,.black.opacity(0.22))
            var flame = Path()
            flame.move(to: pt(63,11))
            flame.addCurve(to: pt(90,50), control1: pt(57,29), control2: pt(89,25))
            flame.addQuadCurve(to: pt(96,39), control: pt(96,47))
            flame.addCurve(to: pt(101,79), control1: pt(109,54), control2: pt(107,69))
            flame.addCurve(to: pt(62,104), control1: pt(95,96), control2: pt(81,105))
            flame.addCurve(to: pt(20,79), control1: pt(42,104), control2: pt(27,98))
            flame.addCurve(to: pt(33,42), control1: pt(13,64), control2: pt(25,50))
            flame.addQuadCurve(to: pt(36,55), control: pt(31,49))
            flame.addCurve(to: pt(63,11), control1: pt(40,39), control2: pt(60,35))
            flame.closeSubpath()
            context.fill(flame, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.34, blue: 0.22), Color(red: 1, green: 0.78, blue: 0.24)]),
                startPoint: pt(60,18), endPoint: pt(60,102)))
            oval(35,58,51,43,Color(red: 1, green: 0.83, blue: 0.39).opacity(0.85))

            switch outfit.garment {
            case 1:
                rounded(32,82,57,10,5,cloth)
                rounded(71,86,11,18,4,cloth)
            case 2:
                polygon([pt(32,82),pt(49,81),pt(62,94),pt(73,81),pt(91,83),pt(86,103),pt(36,103)],cloth)
            case 3:
                polygon([pt(38,80),pt(81,80),pt(99,103),pt(22,103)],cloth)
                oval(57,82,7,7,.white.opacity(0.75))
            case 4:
                rounded(32,83,59,20,6,cloth)
                rounded(39,95,45,4,2,.white.opacity(0.35))
            case 5:
                rounded(34,82,56,22,6,cloth)
                rounded(60,84,2,19,1,ink.opacity(0.55))
                oval(54,88,3,3,.white)
            case 6:
                polygon([pt(39,80),pt(83,80),pt(98,98),pt(62,106),pt(25,99)],cloth)
                rounded(45,94,33,3,1,.white.opacity(0.5))
            case 7:
                rounded(40,89,42,16,5,cloth)
                rounded(42,81,6,15,2,cloth)
                rounded(74,81,6,15,2,cloth)
                oval(45,90,3,3,.white)
                oval(75,90,3,3,.white)
            default:
                rounded(33,82,56,21,8,cloth)
                rounded(48,90,25,8,4,ink.opacity(0.25))
            }

            oval(47,64,8,11,ink)
            oval(69,64,8,11,ink)
            oval(49,66,2.5,3,.white)
            oval(71,66,2.5,3,.white)
            oval(38,74,8,4,Color.pink.opacity(0.65))
            oval(80,74,8,4,Color.pink.opacity(0.65))
            var mouth = Path()
            mouth.move(to: pt(57,76))
            mouth.addQuadCurve(to: pt(65,76), control: pt(61,83))
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))

            switch outfit.accessory {
            case 1:
                polygon([pt(46,42),pt(43,29),pt(52,34),pt(61,23),pt(69,34),pt(79,29),pt(76,42)],cloth)
                oval(59,34,5,5,.white.opacity(0.8))
            case 2:
                polygon([pt(51,37),pt(40,28),pt(40,45),pt(51,41),pt(64,46),pt(63,28)],cloth)
                oval(48,34,7,7,ink.opacity(0.4))
            case 3:
                rounded(46,31,31,13,7,cloth)
                rounded(61,41,24,5,2,cloth)
            case 4:
                polygon([pt(63,22),pt(67,32),pt(78,33),pt(69,40),pt(72,51),pt(63,45),
                         pt(54,51),pt(56,40),pt(48,33),pt(59,32)],cloth)
            case 5:
                var band = Path()
                band.move(to: pt(35,63))
                band.addQuadCurve(to: pt(90,63), control: pt(61,26))
                context.stroke(band, with: .color(cloth), lineWidth: 5 * scale)
                rounded(31,58,10,15,4,cloth)
                rounded(85,58,10,15,4,cloth)
            default:
                rounded(46,31,33,13,7,cloth)
                rounded(43,38,38,7,3,cloth)
                oval(59,26,8,8,.white.opacity(0.85))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Flamme im Outfit \(outfit.name)")
    }
}
