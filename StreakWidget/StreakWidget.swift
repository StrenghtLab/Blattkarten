import WidgetKit
import SwiftUI

struct FlameEntry: TimelineEntry {
    let date: Date
    let pet: StreakPet
}

struct FlameTimeline: TimelineProvider {
    func placeholder(in context: Context) -> FlameEntry {
        FlameEntry(date: .now, pet: StreakPet(lastDay: .now, streak: 3, record: 3))
    }

    func getSnapshot(in context: Context, completion: @escaping (FlameEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : FlameEntry(date: .now, pet: StreakPet.widgetSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlameEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        let pet = StreakPet.widgetSnapshot()
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [FlameEntry(date: now, pet: pet)], policy: .after(midnight)))
    }
}

struct FlameWidgetView: View {
    let entry: FlameEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let streak = entry.pet.streak(at: entry.date)
        let details = VStack(alignment: family == .systemSmall ? .center : .leading, spacing: 3) {
            Text("\(streak) \(streak == 1 ? "Lerntag" : "Lerntage")").font(.headline.bold())
            Text("\(entry.pet.unlocked) von 365 Outfits").font(.caption2).opacity(0.82)
        }
        Group {
            if family == .systemSmall {
                VStack(spacing: 1) {
                    FlamePet(outfit: Outfit(entry.pet.outfit)).frame(height: 81)
                    details
                }
            } else {
                HStack(spacing: 14) {
                    FlamePet(outfit: Outfit(entry.pet.outfit)).frame(width: 105, height: 105)
                    details
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.23, green: 0.17, blue: 0.42), Color(red: 0.10, green: 0.10, blue: 0.23)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .widgetURL(URL(string: "blattkarten://lernflamme"))
    }
}

@main struct StreakWidgetBundle: WidgetBundle {
    var body: some Widget { StreakWidget() }
}

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StreakPet.widgetKind, provider: FlameTimeline()) { entry in
            FlameWidgetView(entry: entry)
        }
        .configurationDisplayName("Lernflamme")
        .description("Deine Lernflamme mit Streak und Outfit.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
