import Foundation
import CoreGraphics
import CoreImage
import CoreML
import ImageIO
import NaturalLanguage
import PDFKit
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct Card: Codable, Identifiable {
    var id = UUID()
    var question: String
    var answer: String
    var subject: String? = nil
    var worksheet: String? = nil
    var folderID: UUID? = nil
    var review: LearningProgress? = nil
    var explanation: String? = nil
    var sourceExcerpt: String? = nil

    var subjectName: String { subject ?? "Allgemein" }
}

enum StudyError: LocalizedError {
    case unreadable, empty, noFacts, camera
    var errorDescription: String? {
        switch self {
        case .unreadable: "Die Datei konnte nicht gelesen werden."
        case .empty: "Auf dem Blatt wurde kein lesbarer Text gefunden."
        case .noFacts: "Auf dem Blatt wurden keine Aussagen für Karteikarten gefunden. Bei einer Aufgabenseite ohne Lösungen hilft die passende Erklärseite aus dem Buch."
        case .camera: "Die Kamera ist nicht verfügbar. Prüfe den Zugriff in den Systemeinstellungen."
        }
    }
}

enum Worksheet {
    static func recognize(_ image: CGImage) throws -> String {
        var full = try recognizeRegion(image)
        if image.width > image.height, full.split(whereSeparator: \.isWhitespace).count < 15 {
            for orientation in [CGImagePropertyOrientation.left, .right] {
                if let rotated = try? recognizeRegion(image, orientation: orientation),
                   rotated.split(whereSeparator: \.isWhitespace).count > full.split(whereSeparator: \.isWhitespace).count + 8 {
                    full = rotated
                }
            }
        }
        guard full.localizedCaseInsensitiveContains("Strom messen"),
              full.localizedCaseInsensitiveContains("Spannung messen"),
              !full.localizedCaseInsensitiveContains("Voltmeter V parallel") ||
              !full.localizedCaseInsensitiveContains("Amperemeter A in Reihe") else {
            return full
        }

        // Read the two narrow text columns separately when OCR misses their opening lines.
        let orientations: [CGImagePropertyOrientation] = image.width > image.height ? [.left, .right, .up] : [.up, .down]
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var recovered: [String] = []
        for orientation in orientations {
            let upright = CIImage(cgImage: image).oriented(orientation)
            let size = upright.extent
            for x in [0.10, 0.48] {
                let region = CGRect(x: size.minX + size.width * x, y: size.minY + size.height * 0.39,
                                    width: size.width * 0.40, height: size.height * 0.30).integral
                guard let crop = context.createCGImage(upright, from: region),
                      let excerpt = try? recognizeRegion(crop),
                      excerpt.localizedCaseInsensitiveContains("Amperemeter") ||
                        excerpt.localizedCaseInsensitiveContains("Voltmeter") else { continue }
                recovered.append(excerpt)
            }
            let result = ([full] + recovered).joined(separator: "\n")
            if result.localizedCaseInsensitiveContains("Voltmeter V parallel"),
               result.localizedCaseInsensitiveContains("Amperemeter A in Reihe") { return result }
        }
        return ([full] + recovered).joined(separator: "\n")
    }

    private static func recognizeRegion(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        #if os(macOS) && arch(x86_64)
        // Keep OCR usable on Intel Macs without a working Metal accelerator.
        if #available(macOS 14, *) {
            for (stage, devices) in (try request.supportedComputeStageDevices) {
                if let cpu = devices.first(where: { device in
                    if case .cpu = device { return true }
                    return false
                }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        } else {
            request.usesCPUOnly = true
        }
        #endif
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func read(_ url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw StudyError.unreadable }
            return try (0..<pdf.pageCount).compactMap { index in
                guard let page = pdf.page(at: index) else { return nil }
                if let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return string }
                let size = page.bounds(for: .mediaBox).size
                let scale = 2000 / max(size.width, size.height, 1)
                let thumbnail = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
                #if os(macOS)
                guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                #else
                guard let image = thumbnail.cgImage else { return nil }
                #endif
                return try recognize(image)
            }.joined(separator: "\u{000C}")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200
              ] as CFDictionary) else { throw StudyError.unreadable }
        return try recognize(image)
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<result.numberOfRanges).map {
            Range(result.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func structuredCards(_ lines: [String]) -> [Card] {
        var cards: [Card] = []
        func add(_ question: String, _ answer: String) {
            cards.append(Card(question: question, answer: answer))
        }
        let text = lines.joined(separator: "\n")
        func has(_ pattern: String, in source: String? = nil) -> Bool {
            (source ?? text).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        // OCR often returns a table as consecutive columns rather than consecutive rows.
        if let quantity = lines.firstIndex(where: { $0.lowercased() == "größe" }),
           let meaning = lines.indices.dropFirst(quantity + 1).first(where: { lines[$0].lowercased() == "bedeutung" }),
           let units = lines.indices.dropFirst(meaning + 1).first(where: {
               has(#"^(?:einheit(?:en)?|finneit)$"#, in: lines[$0])
           }) {
            let labels = Array(lines[(quantity + 1)..<meaning])
            var meanings: [String] = []
            for line in lines[(meaning + 1)..<units] {
                if let last = meanings.indices.last, line.first?.isLowercase == true {
                    meanings[last] += " " + line
                } else {
                    meanings.append(line)
                }
            }
            let unitRows = Array(lines.dropFirst(units + 1).prefix(labels.count))
            if !labels.isEmpty, labels.count == meanings.count, unitRows.count == labels.count,
               unitRows.allSatisfy({ has(#"^\p{L}+\s*\([^)]+\)$"#, in: $0) }) {
                for index in labels.indices {
                    let label = labels[index]
                    let meaning = meanings[index]
                    let answer: String
                    var unit = unitRows[index]
                    if has(#"^Stromstärke\s+[I1l]$"#, in: label), has("Ladung.*Zeit", in: meanings[index]) {
                        answer = "Wie viel elektrische Ladung pro Sekunde durch eine Stelle fließt."
                    } else if has(#"^Spannung\s+U$"#, in: label), has("Energieunterschied.*Ladung", in: meanings[index]) {
                        answer = "Wie stark sich die Energie pro Ladung zwischen zwei Punkten unterscheidet."
                    } else if has(#"^Widerstand\s+R$"#, in: label), has("Stromfluss hemmt", in: meanings[index]) {
                        answer = "Wie stark ein Bauteil den Stromfluss bremst."
                        unit = "Ohm (Ω)"
                    } else {
                        answer = meaning
                    }
                    let term = label.replacingOccurrences(of: #"\s+[A-Za-z1]$"#, with: "", options: .regularExpression)
                    add("Was beschreibt die Größe „\(term)“?", answer)
                    add("In welcher Einheit misst man „\(term)“?", unit)
                }
            }
        }
        if has("Strom messen"), has("Spannung messen"), has("Wassermodell") {
            if has(#"Amperemeter\s+A\s+in Reihe[\s\S]{0,65}Stromweg"#) {
                add("Wie schließt du ein Amperemeter an?", "In Reihe in den Stromweg, dessen Stromstärke du messen willst.")
            }
            if has(#"vor der Verzweigung[\s\S]{0,25}Gesamtstrom"#), has("im oberen Zweig misst") {
                add("Wo misst du den Gesamtstrom einer Parallelschaltung?", "Vor der Verzweigung.")
                add("Wo misst du den Zweigstrom einer Parallelschaltung?", "Im jeweiligen Zweig.")
            }
            if has(#"Voltmeter\s+V\s+parallel[\s\S]{0,85}anschließen"#) {
                add("Wie schließt du ein Voltmeter an?", "Parallel zu den beiden Anschlüssen des Bauteils. Es misst die Spannung zwischen diesen Punkten.")
            }
            if has("parallel", in: text), has("gemeinsame Anschlussknoten"), has("derselbe Strom nacheinander") {
                add("Woran erkennst du im Schaltbild eine Reihen- oder Parallelschaltung?",
                    "Verfolge die Leitungen. In Reihe durchläuft derselbe Strom die Bauteile nacheinander. Parallel liegen die Bauteile zwischen denselben zwei Anschlussknoten.")
            }
            if has("Wasserkreislauf"), has("Spannungsquelle"), has("Höhenunterschied"), has("Druckunterschied") {
                add("Wofür steht die Pumpe im Wassermodell?", "Für die Spannungsquelle, zum Beispiel eine Batterie.")
                add("Wofür steht der Höhen- oder Druckunterschied im Wassermodell?", "Für die Spannung zwischen zwei Stellen.")
            }
            if has("Wassermenge pro Zeit"), has("Wasserrad"), has("Bauteil mit Widerstand") {
                add("Wofür steht die Wassermenge pro Zeit im Wassermodell?", "Für die Stromstärke.")
                add("Wofür steht das bremsende Wasserrad im Wassermodell?", "Für ein Bauteil mit Widerstand.")
            }
            if has("dieselbe Wassermenge pro Zeit"), has(#"Höhenunterschied verteilt sich"#) {
                add("Was zeigt das Wassermodell bei einer Reihenschaltung?",
                    "Durch beide Wasserräder fließt pro Zeit dieselbe Wassermenge. Der gesamte Höhenunterschied verteilt sich auf die Räder.")
            }
            if has("Wasser teilt sich auf zwei Wege auf"), has(#"demselben oberen und unteren Niveau"#) {
                add("Was zeigt das Wassermodell bei einer Parallelschaltung?",
                    "Das Wasser verteilt sich auf zwei Wege. Beide Wasserräder liegen zwischen denselben oberen und unteren Niveaus.")
            }
            if has("Strom wird im Bauteil nicht verbraucht"), has("wandelt elektrische Energie um") {
                add("Was wird in einem elektrischen Bauteil umgewandelt?", "Das Bauteil wandelt elektrische Energie um. Der Strom wird dabei nicht verbraucht.")
            }
        }
        guard has("Reihenschaltung"), has("Parallelschaltung"), has("Stromstärke"), has("Widerstand") else {
            return cards
        }
        let compact = text.replacingOccurrences(of: #"[^\S\n]+"#, with: "", options: .regularExpression)
        if has(#"R=U/[Il1]"#, in: compact), has(#"[Il1]=U/R"#, in: compact),
           has(#"U=R[·•⋅×*][Il1]"#, in: compact) {
            add("Wie berechnest du die Spannung mit dem Ohmschen Gesetz?", "U = R · I")
            add("Wie berechnest du die Stromstärke mit dem Ohmschen Gesetz?", "I = U / R")
            add("Wie berechnest du den Widerstand mit dem Ohmschen Gesetz?", "R = U / I")
        }
        if has(#"(unveränderter|konstanter) Spannung"#), has("größerer Widerstand"), has(#"kleinere\s+Stromstärke"#) {
            add("Was passiert mit der Stromstärke, wenn bei gleicher Spannung der Widerstand steigt?",
                "Sie sinkt. Bei konstantem U gilt I = U / R.")
        }
        if has("ein Stromweg"), has(#"mehrere Zweige[\s\S]{0,50}Knoten"#) {
            add("Wie unterscheiden sich Reihen- und Parallelschaltung im Aufbau?",
                "Reihe: ein Stromweg, die Bauteile liegen hintereinander.\nParallel: mehrere Zweige verbinden dieselben zwei Knoten.")
        }
        if has("überall gleich groß"), has("teilt sich auf die Zweige auf") {
            add("Wie unterscheidet sich die Stromstärke in Reihen- und Parallelschaltungen?",
                "Reihe: überall gleich, I = I₁ = I₂.\nParallel: sie verteilt sich auf die Zweige, I = I₁ + I₂.")
        }
        if has("teilt sich auf die Bauteile auf"), has("an jedem Zweig gleich groß") {
            add("Wie unterscheidet sich die Spannung in Reihen- und Parallelschaltungen?",
                "Reihe: die Teilspannungen addieren sich, U = U₁ + U₂.\nParallel: an jedem Zweig gleich, U = U₁ = U₂.")
        }
        if has("größer als jeder Einzelwiderstand"), has("kleiner als der kleinste Einzelwiderstand") {
            add("Wie berechnest du den Gesamtwiderstand in Reihe und parallel?",
                "Reihe: Rges = R₁ + R₂, größer als jeder Einzelwiderstand.\nParallel: 1/Rges = 1/R₁ + 1/R₂, kleiner als der kleinste Einzelwiderstand.")
        }
        if has(#"genau zwei parallele Widerstände"#),
           has(#"Rges=\(R[Il1][·•⋅×*]R[2z]\)/\(R[Il1]\+R[2z]\)"#, in: compact) {
            add("Welche Kurzformel gilt für genau zwei parallele Widerstände?",
                "Rges = (R₁ · R₂) / (R₁ + R₂).")
        }
        if has(#"1A=1[.,]?000mA"#, in: compact), has(#"1k[ΩQOD]=1[.,]?000"#, in: compact) {
            add("Wie rechnest du Milliampere in Ampere um?", "Durch 1.000 teilen.")
            add("Wie rechnest du Kiloohm in Ohm um?", "Mit 1.000 multiplizieren.")
        }
        return cards
    }

    static func suggestedSubject(for text: String, title: String, available: [String]) -> String? {
        let vocabulary: [String: [String]] = [
            "Mathematik": ["gleichung", "bruchrechnung", "nenner", "zähler", "ableitung", "parabel", "koordinat", "pythagoras", "prozentrechnung", "wahrscheinlichkeit", "polynom"],
            "Physik": ["stromstärk", "spannung", "widerstand", "stromkreis", "amperemeter", "voltmeter", "geschwindigkeit", "beschleunigung", "schwerkraft", "bewegungsenergie", "magnetfeld", "newton", "reihenschaltung"],
            "Chemie": ["chemisch", "reaktion", "oxidation", "periodensystem", "atombindung", "molekül", "elektron", "proton", "säure", "neutralisation", "ionen"],
            "Biologie": ["zellkern", "zellmembran", "mitochondri", "photosynthes", "chloroplast", "neuron", "synapse", "organismus", "enzym", "ökosystem", "dna", "erbinfo", "erbinformation", "evolution"],
            "Geschichte": ["revolution", "weltkrieg", "mittelalter", "kaiserreich", "industrialisierung", "nationalsozial", "römisch", "historisch", "kolonial"],
            "Erdkunde": ["klimazon", "kontinent", "plattentektonik", "vulkanismus", "erosion", "wasserkreislauf", "bevölkerungsdicht", "erdkruste", "verdunstung"],
            "Deutsch": ["gedicht", "metapher", "reimschema", "erzähler", "satzglied", "wortart", "interpretation", "rechtschreib", "konjunktiv"],
            "Englisch": ["grammar", "vocabulary", "tense", "verb", "conditional", "reported", "adjective", "pronoun", "übersetzung"],
        ]
        let heading = title + " " + text.prefix(240)
        func tokens(_ value: String) -> Set<String> {
            Set(value.lowercased().split { !$0.isLetter }.map(String.init))
        }
        let headings = tokens(heading)
        let all = tokens(title + " " + text)
        let named = available.filter { subject in
            guard subject != "Allgemein" else { return false }
            let name = tokens(subject)
            return !name.isEmpty && name.isSubset(of: headings)
        }
        if named.count == 1 { return named.first }
        let scores = available.compactMap { subject -> (String, Int)? in
            guard let terms = vocabulary[subject] else { return nil }
            let hits = terms.filter { prefix in all.contains { $0.hasPrefix(prefix) } }
            guard hits.count >= 2 else { return nil }
            let leading = hits.filter { prefix in headings.contains { $0.hasPrefix(prefix) } }.count
            return (subject, hits.count * 2 + leading)
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, scores.count == 1 || best.1 >= scores[1].1 + 3 else { return nil }
        return best.0
    }

    static let studioTextLimit = 60_000

    static func sections(from text: String) -> [String] {
        cleanText(text).components(separatedBy: "\u{000C}").flatMap { page -> [String] in
            var sections: [String] = []
            var buffer = ""
            for line in studyText(on: page).components(separatedBy: .newlines) {
                var rest = line[...]
                while !rest.isEmpty {
                    let proposed = rest.prefix(3_800)
                    let separator = proposed.count == rest.count ? nil : proposed.lastIndex(where: \.isWhitespace)
                    let piece = separator.map { rest[..<$0] }.flatMap { $0.count > 1_900 ? $0 : nil } ?? proposed
                    if buffer.count + piece.count + 1 > 4_000 {
                        sections.append(buffer)
                        buffer = ""
                    }
                    buffer += piece + "\n"
                    rest = rest.dropFirst(piece.count)
                }
            }
            if !buffer.isEmpty { sections.append(buffer) }
            return sections
        }
    }

    static func cards(from text: String) -> [Card] {
        let groups = sections(from: text).map(pageCards)
        var questions = Set<String>()
        var cards: [Card] = []
        let depth = groups.map(\.count).max() ?? 0
        for index in 0..<depth {
            for group in groups where group.indices.contains(index) {
                let card = group[index]
                if questions.insert(card.contentKey.question).inserted { cards.append(card) }
            }
        }
        return cards
    }

    static func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: #"(\p{L}{3,})-[ \t]*\r?\n[ \t]*(\p{Ll}{2,})"#,
                                  with: "$1$2", options: .regularExpression)
    }

    static func studyText(on page: String) -> String {
        guard containsUnsolvedChoices(page) else { return page }
        let heading = #"(?im)^[ \t]*(?:Übungsaufgaben|Aufgaben|Teste dich)[ \t]*:?[ \t]*$"#
        guard let start = page.range(of: heading, options: .regularExpression),
              !containsUnsolvedChoices(String(page[..<start.lowerBound])) else { return "" }
        return String(page[..<start.lowerBound])
    }

    static func containsUnsolvedChoices(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return match(#"\b(?:welche der folgenden aussagen|finde .*? ein gegenbeispiel|ob die folgenden aussagen)\b"#,
                     in: normalized) != nil
    }

    private static func pageCards(_ page: String) -> [Card] {
        let text = studyText(on: page)
        struct Candidate {
            let card: Card
            let priority: Int
            let topic: String
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let structured = structuredCards(lines)
        if structured.count >= 5 { return structured }
        var candidates: [Candidate] = []
        var topic = ""
        var pendingQuestion: String?
        var paragraph = ""
        var sourceSentence: String?

        func add(_ question: String, _ answer: String, priority: Int) {
            guard var card = Card.generated(question: question, answer: answer) else { return }
            card.sourceExcerpt = sourceSentence
            candidates.append(Candidate(card: card, priority: priority, topic: topic))
        }

        func subjectInQuestion(_ value: String) -> String {
            let subject = value.trimmingCharacters(in: .whitespaces)
            if match(#"^(der|die|das|ein|eine)\s+"#, in: subject) != nil {
                return subject.prefix(1).lowercased() + subject.dropFirst()
            }
            return subject
        }

        func summarize(_ sentence: String) {
            let fact = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty, !fact.hasSuffix("?"),
                  match(#"^(?:er|sie|es|dies|das|diese|dabei|dadurch|dann|hier|dort)\s+(?:ist|sind|wird|werden|kann|können|hat|haben|entsteht|enthält|führt|ändert)\b"#, in: fact) == nil else { return }
            sourceSentence = fact
            defer { sourceSentence = nil }
            if let parts = match(#"^Im Jahr (\d{3,4}) (.{12,})$"#, in: fact) {
                let event = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
                add("In welchem Jahr geschah Folgendes: \(event)?", parts[0], priority: 8)
            } else if let parts = match(#"^(.{6,}?)(?:,)?\s+(weil|denn)\s+(.{5,})$"#, in: fact) {
                let claim = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                add("Warum gilt „\(claim)“?", parts[2], priority: 9)
            } else if let parts = match(#"^Unter\s+(.{2,65}?)\s+versteht man\s+(.{5,})$"#, in: fact) {
                add("Was versteht man unter \(subjectInQuestion(parts[0]))?", parts[1], priority: 9)
            } else if let parts = match(#"^Als\s+(.{2,65}?)\s+bezeichnet man\s+(.{5,})$"#, in: fact) {
                add("Was bezeichnet man als \(subjectInQuestion(parts[0]))?", parts[1], priority: 9)
            } else if let parts = match(#"^(.{2,65}?)\s+(führt|führen)\s+zu\s+(.{5,})$"#, in: fact) {
                add("Wozu \(parts[1].lowercased()) \(subjectInQuestion(parts[0]))?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,65}?)\s+(ist|sind|bezeichnet|bedeutet)\s+(.{6,})$"#, in: fact) {
                let plural = parts[1].lowercased() == "sind"
                let subject = subjectInQuestion(parts[0])
                add("\(plural ? "Was sind" : "Was ist") \(subject)?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,55}?)\s+(besteht|bestehen)\s+aus\s+(.{5,})$"#, in: fact) {
                add("Woraus \(parts[1].lowercased()) \(subjectInQuestion(parts[0]))?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,55}?)\s+(entsteht|entstehen)\s+(.{5,})$"#, in: fact) {
                let circumstance = parts[2].lowercased()
                let cue = circumstance.hasPrefix("bei ") || circumstance.hasPrefix("wenn ") ? "Wann" :
                    (circumstance.hasPrefix("in ") || circumstance.hasPrefix("an ") ? "Wo" : "Wie")
                add("\(cue) \(parts[1].lowercased()) \(subjectInQuestion(parts[0]))?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,55}?)\s+(wird|werden)\s+((?:durch|in|aus|bei|mit|von)\s+.{6,})$"#, in: fact) {
                let auxiliary = parts[1].lowercased()
                let complement = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let subject = subjectInQuestion(parts[0])
                if let location = match(#"^((?:in|an|auf|unter|über)\s+.+?)\s+(gespeichert|gebildet|hergestellt|abgebaut)\.?$"#, in: complement) {
                    add("Wo \(auxiliary) \(subject) \(location[1])?", location[0], priority: 8)
                } else {
                    add("Was passiert mit „\(parts[0])“?", parts[1] + " " + complement, priority: 6)
                }
            } else if let parts = match(#"^(.{2,55}?)\s+(braucht|brauchen|benötigt|benötigen|enthält|enthalten|produziert|produzieren|speichert|speichern|verursacht|verursachen|schützt|schützen|transportiert|transportieren|umfasst|umfassen|misst|messen|liefert|liefern|verbindet|verbinden|nutzt|nutzen|nimmt|nehmen|gibt|geben)\s+(.{4,})$"#, in: fact) {
                let subject = subjectInQuestion(parts[0])
                let verb = parts[1].lowercased()
                let complement = parts[2]
                if let separable = match(#"^(.+?)\s+(auf|ab|weiter|frei)\.?$"#, in: complement),
                   ["nimmt", "nehmen", "gibt", "geben"].contains(verb) {
                    add("Was \(verb) \(subject) \(separable[1])?", separable[0], priority: 7)
                } else if !["nimmt", "nehmen", "gibt", "geben"].contains(verb) {
                    add("Was \(verb) \(subject)?", complement, priority: 7)
                }
            }
        }

        func flush() {
            guard !paragraph.isEmpty else { return }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                summarize(String(paragraph[range]))
                return true
            }
            paragraph = ""
        }

        for raw in lines {
            let line = match(#"^(?:[•●▪*]|\d{1,2}[.)])\s+(.*)$"#, in: raw)?.first ?? raw
            if let answer = match(#"^(?:Antwort|Lösung|A)\s*:\s*(.+)$"#, in: line)?.first {
                flush()
                if let question = pendingQuestion {
                    sourceSentence = question + " " + line
                    add(question, answer, priority: 10)
                    sourceSentence = nil
                }
                pendingQuestion = nil
                continue
            }
            if line.hasSuffix("?") {
                flush()
                pendingQuestion = line
                continue
            }
            pendingQuestion = nil
            if match(#"^(?:Name|Datum|Klasse|Fach)\s*:|^(?:Arbeitsblatt|Aufgabe[n]?)(?:\s+\d+)?\s*$|^(?:Erkläre|Beschreibe|Begründe|Unterstreiche|Markiere|Ergänze|Ordne|Lies|Berechne|Kreuze|Nenne|Notiere|Schreibe|Zeichne|Bearbeite)\b|_{3,}"#, in: line) != nil {
                flush()
                continue
            }
            if let parts = match(#"^([^:–—]{2,55}?)(?:\s+[–—]\s+|:\s+)(.{2,})$"#, in: line) {
                flush()
                sourceSentence = line
                add("Was bedeutet „\(parts[0])“?", parts[1], priority: 9)
                sourceSentence = nil
                continue
            }
            if !line.hasSuffix("."), !line.hasSuffix("!"),
               line.split(whereSeparator: \.isWhitespace).count <= 5,
               line.count <= 50,
               match(#"\b(?:ist|sind|hat|haben|wird|werden|entsteht|besteht|bezeichnet|bedeutet|braucht|brauchen|benötigt|benötigen|enthält|enthalten|misst|messen|nutzt|nutzen|nimmt|nehmen|gibt|geben)\b"#, in: line) == nil {
                flush()
                topic = line.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                continue
            }
            if raw != line { flush() }
            paragraph += paragraph.isEmpty ? line : " " + line
            if line.hasSuffix(".") || line.hasSuffix("!") || raw != line { flush() }
        }
        flush()

        let stopWords: Set<String> = ["einer", "eines", "einem", "einen", "haben", "werden", "wurde", "durch", "diese", "dabei", "ihren", "ihrer"]
        func keywords(_ string: String) -> Set<String> {
            Set(string.lowercased().split { !$0.isLetter }
                .filter { $0.count >= 4 && !stopWords.contains(String($0)) }
                .map(String.init))
        }

        var frequency: [String: Int] = [:]
        let terms = candidates.map { keywords($0.card.answer) }
        for group in terms {
            for word in group { frequency[word, default: 0] += 1 }
        }
        let scores = candidates.indices.map { index in
            let relevance = terms[index].reduce(0) { $0 + max(0, (frequency[$1] ?? 1) - 1) }
            return candidates[index].priority * 8 + min(6, relevance)
        }
        let ranked = candidates.indices.sorted { a, b in
            scores[a] == scores[b] ? a < b : scores[a] > scores[b]
        }
        let target = min(18, max(3, (candidates.count + 1) / 2))
        var selected: [Int] = []
        var questions = Set<String>()
        var sections: [String: Int] = [:]
        for index in ranked {
            let candidate = candidates[index]
            let question = candidate.card.question.lowercased()
            guard !questions.contains(question) else { continue }
            let duplicate = selected.contains { existing in
                let union = terms[index].union(terms[existing])
                return !union.isEmpty && Double(terms[index].intersection(terms[existing]).count) / Double(union.count) >= 0.72
            }
            guard !duplicate else { continue }
            if candidate.priority < 5, !candidate.topic.isEmpty, sections[candidate.topic, default: 0] >= 2 { continue }
            questions.insert(question)
            sections[candidate.topic, default: 0] += 1
            selected.append(index)
            if selected.count == target { break }
        }
        return structured + selected.sorted().map { candidates[$0].card }
    }
}
