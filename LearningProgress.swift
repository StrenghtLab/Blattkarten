import Foundation

struct LearningProgress: Codable {
    let level: Int
    let dueAt: Date

    static func after(_ previous: LearningProgress?, understood: Bool, now: Date = .now) -> LearningProgress {
        guard understood else { return LearningProgress(level: 0, dueAt: now.addingTimeInterval(15 * 60)) }
        let intervals: [Int] = [1, 3, 7, 14, 30, 60]
        let level = min(max(0, previous?.level ?? 0), intervals.count - 1) + 1
        let days = intervals[level - 1]
        let due = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86_400)
        return LearningProgress(level: level, dueAt: due)
    }
}

extension Card {
    static func generated(question: String, answer: String) -> Card? {
        let prompt = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.hasSuffix("?"), (7...220).contains(prompt.count),
              !reply.isEmpty, reply.count <= 520,
              reply.range(of: #"^(?:\.{2,}|…|[-–—]+|_+|unbekannt|keine angabe|keine antwort(?: vorhanden)?)[.!]?$"#,
                          options: [.caseInsensitive, .regularExpression]) == nil,
              prompt.dropLast().caseInsensitiveCompare(reply) != .orderedSame else { return nil }
        let capitalizable = reply.range(of: #"^(ein(?:e[nmrs]?)?|der|die|das|den|dem|durch|in|an|auf|bei|mit|für|von|sie|er|es)\s"#,
                                           options: .regularExpression) != nil
        let cleanAnswer = capitalizable ? reply.prefix(1).uppercased() + reply.dropFirst() : reply
        return Card(question: prompt, answer: cleanAnswer)
    }

    func isDue(at time: Date) -> Bool { review?.dueAt ?? .distantPast <= time }

    func matches(_ query: String) -> Bool {
        let search = [question, answer, worksheet ?? ""].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { search.localizedStandardContains(String($0)) }
    }

    struct ContentKey: Hashable {
        let question: String
        let answer: String
    }

    var contentKey: ContentKey {
        func normalize(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        return ContentKey(question: normalize(question), answer: normalize(answer))
    }
}
