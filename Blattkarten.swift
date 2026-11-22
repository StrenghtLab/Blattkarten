import SwiftUI
import AppKit
import Vision
import CoreML
import CoreImage
import NaturalLanguage
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

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

struct WorksheetFolder: Codable, Identifiable {
    var id = UUID()
    let subject: String
    let parentID: UUID?
    let name: String
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
        #if arch(x86_64)
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
                guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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

final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "blattkarten.camera")
    private var result: ((Data) -> Void)?
    private var stopped = false
    @Published var ready = false
    @Published var failed = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            self.queue.async {
                guard !self.stopped else { return }
                guard allowed, let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    DispatchQueue.main.async { self.failed = true }
                    return
                }
                self.session.beginConfiguration()
                self.session.addInput(input)
                self.session.addOutput(self.output)
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async { self.ready = true }
            }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
    func capture(_ completion: @escaping (Data) -> Void) {
        queue.async {
            self.result = completion
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async {
            let callback = self.result
            self.result = nil
            DispatchQueue.main.async {
                if let data { callback?(data) } else { self.failed = true }
            }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct CameraSheet: View {
    @StateObject private var camera = Camera()
    @State private var capturing = false
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Data) -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Arbeitsblatt fotografieren").font(.title2.bold())
            if camera.failed {
                Text(StudyError.camera.localizedDescription).padding(24)
            } else {
                CameraPreview(session: camera.session).frame(width: 580, height: 360)
                    .background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
                Text("Halte das ganze Blatt gut beleuchtet und möglichst gerade ins Bild.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Schließen") { dismiss() }
                Button("Foto aufnehmen") {
                    capturing = true
                    camera.capture { data in
                        onCapture(data)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!camera.ready || camera.failed || capturing)
            }
        }
        .padding(24)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

let ink = Color(red: 0.07, green: 0.09, blue: 0.16)
let panel = Color(red: 0.11, green: 0.14, blue: 0.23)
let mint = Color(red: 0.56, green: 0.98, blue: 0.78)
let lilac = Color(red: 0.72, green: 0.66, blue: 1)
let soft = Color(red: 0.69, green: 0.74, blue: 0.83)

private enum PracticeMode {
    case typing, flip
}

private struct PracticeSetup: Identifiable {
    let id = UUID()
    let cards: [Card]
}

private struct TutorScopeIdentity: Hashable {
    let subject: String
    let folderID: UUID?
}

struct ContentView: View {
    @AppStorage("worksheet.deck.v1") private var saved = Data()
    @AppStorage("worksheet.title.v1") private var legacyTitle = ""
    @AppStorage("worksheet.selectedSubject.v1") private var selectedSubject = "Allgemein"
    @AppStorage("worksheet.customSubjects.v1") private var savedSubjects = Data()
    @State private var newSubject = ""
    @State private var addingSubject = false
    @State private var tutorOpen = false
    @State private var showingPet = false
    @State private var pet = StreakPet()
    @StateObject private var desktopFlame = FlameDesktop()
    @AppStorage("worksheet.flameOnDesktop.v1") private var flameOnDesktop = false
    @AppStorage("worksheet.streakPet.v1") private var savedPet = Data()
    @State private var nativeTutor: TutorSessionRequest?
    @StateObject private var tutorSettings = TutorSettings()
    @AppStorage("worksheet.folders.v1") private var savedFolders = Data()
    @State private var currentFolderID: UUID?
    @State private var addingFolder = false
    @State private var newFolder = ""
    @State private var search = ""
    @State private var importNotice: String?
    @State private var showTutorSetup = false
    @State private var reviewClock = Date.now

    private var folders: [WorksheetFolder] {
        (try? JSONDecoder().decode([WorksheetFolder].self, from: savedFolders)) ?? []
    }

    private var currentFolder: WorksheetFolder? {
        folders.first { $0.id == currentFolderID && $0.subject == selectedSubject }
    }

    private var childFolders: [WorksheetFolder] {
        folders.filter { $0.subject == selectedSubject && $0.parentID == currentFolder?.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var tutorCards: [Card] {
        guard let root = currentFolder?.id else { return subjectCards }
        var included: Set<UUID> = [root]
        var pending = [root]
        let children = Dictionary(grouping: folders.filter { $0.subject == selectedSubject }, by: \.parentID)
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where included.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return subjectCards.filter { card in card.folderID.map(included.contains) ?? false }
    }

    private var tutorScope: String {
        var names: [String] = []
        var folder = currentFolder
        var seen = Set<UUID>()
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while let entry = folder, seen.insert(entry.id).inserted {
            names.append(entry.name)
            folder = entry.parentID.flatMap { byID[$0] }
        }
        return ([selectedSubject] + names.reversed()).joined(separator: " / ")
    }

    private var location: String { currentFolder?.name ?? selectedSubject }

    private var trimmedFolder: String { newFolder.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAddFolder: Bool {
        !trimmedFolder.isEmpty && trimmedFolder.count <= 50 &&
            !childFolders.contains { $0.name.caseInsensitiveCompare(trimmedFolder) == .orderedSame }
    }

    private static let defaultSubjects = [
        ("Allgemein", "tray"), ("Mathematik", "function"), ("Deutsch", "text.book.closed"),
        ("Englisch", "globe"), ("Physik", "bolt"), ("Chemie", "flask"),
        ("Biologie", "leaf"), ("Geschichte", "building.columns"), ("Erdkunde", "map")
    ]

    private var subjects: [String] {
        Self.defaultSubjects.map { $0.0 } + ((try? JSONDecoder().decode([String].self, from: savedSubjects)) ?? [])
    }

    private var subjectCards: [Card] { cards.filter { $0.subjectName == selectedSubject } }

    private var visibleCards: [Card] {
        subjectCards.filter { $0.folderID == currentFolder?.id }
    }

    private var practiceCards: [Card] { currentFolder == nil ? subjectCards : visibleCards }
    private var searchActive: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var displayedCards: [Card] { searchActive ? tutorCards.filter { $0.matches(search) } : visibleCards }

    private var dueCards: [Card] {
        practiceCards.filter { $0.isDue(at: reviewClock) }
    }

    private var trimmedSubject: String { newSubject.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAddSubject: Bool {
        !trimmedSubject.isEmpty && trimmedSubject.count <= 32 &&
            !subjects.contains { $0.caseInsensitiveCompare(trimmedSubject) == .orderedSame }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cards: [Card] = []
    @State private var session: [Card] = []
    @State private var page = "Start"
    @State private var cursor = 0
    @State private var known = 0
    @State private var missed: [Card] = []
    @State private var flipped = false
    @State private var typedAnswer = ""
    @State private var retryingCard = false
    @State private var practiceMode: PracticeMode = .flip
    @State private var practiceSetup: PracticeSetup?
    @FocusState private var typingPracticeAnswer: Bool
    @State private var busy = false
    @State private var camera = false
    @AppStorage("worksheet.compactOverview.v1") private var compactOverview = false
    @State private var overviewCard: Card?
    @State private var editing: Card?
    @State private var error: String?
    @State private var appeared = false
    @State private var hovering = false
    @State private var printError = false

    var body: some View {
        Group {
            if let nativeTutor {
                NativeTutorChat(request: nativeTutor) { self.nativeTutor = nil }
                    .id(nativeTutor.id)
            } else {
                workspace
            }
        }
        .frame(minWidth: 840, minHeight: 620)
        .onOpenURL { url in
            guard url.scheme == "blattkarten", url.host == "lernflamme" else { return }
            nativeTutor = nil
            showingPet = true
        }
        .sheet(isPresented: $showingPet) {
            PetCloset(pet: pet, desktopVisible: $flameOnDesktop) { index in
                guard index < pet.unlocked else { return }
                pet.outfit = index
                savePet()
            }
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                switch page {
                case "Start": dashboard
                case "Sammlung": collection
                case "KI-Studio": generatorWorkspace
                default: practice
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                LinearGradient(colors: [Color(red: 0.17, green: 0.12, blue: 0.26), ink],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                TutorDock(scope: tutorScope, scopeID: currentFolder.map { "folder:" + $0.id.uuidString } ?? "subject:" + selectedSubject,
                          cards: tutorCards, expanded: $tutorOpen, setupRequested: $showTutorSetup,
                          openNativeChat: { nativeTutor = $0 }, settings: tutorSettings)
                    .id(TutorScopeIdentity(subject: selectedSubject, folderID: currentFolder?.id))
                    .padding(18)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 840, minHeight: 620)
        .onAppear {
            if let decoded = try? JSONDecoder().decode([Card].self, from: saved) { cards = decoded }
            if let decoded = try? JSONDecoder().decode(StreakPet.self, from: savedPet) { pet = decoded }
            pet.publish()
            refreshDesktopFlame()
            if !subjects.contains(selectedSubject) { selectedSubject = "Allgemein" }
            appeared = true
        }
        .onChange(of: flameOnDesktop) { _ in refreshDesktopFlame() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) {
            reviewClock = $0
            desktopFlame.refreshTime($0)
        }
        .onChange(of: selectedSubject) { _ in
            currentFolderID = nil
            search = ""
            page = "Sammlung"
            session = []
            flipped = false
            appeared = true
        }
        .alert("Arbeitsblatt importiert", isPresented: Binding(
            get: { importNotice != nil }, set: { if !$0 { importNotice = nil } }
        )) {
            Button("OK", role: .cancel) { importNotice = nil }
        } message: {
            Text(importNotice ?? "")
        }
        .alert("Fach hinzufügen", isPresented: $addingSubject) {
            TextField("Name des Fachs", text: $newSubject)
            Button("Abbrechen", role: .cancel) {}
            Button("Hinzufügen") { addSubject() }.disabled(!canAddSubject)
        }
        .alert("Ordner hinzufügen", isPresented: $addingFolder) {
            TextField("Ordnername", text: $newFolder)
            Button("Abbrechen", role: .cancel) {}
            Button("Hinzufügen") { addFolder() }.disabled(!canAddFolder)
        }
        .sheet(item: $practiceSetup) { setup in
            VStack(alignment: .leading, spacing: 14) {
                Text("Wie möchtest du üben?").font(.title2.bold())
                Button {
                    begin(setup.cards, mode: .typing)
                } label: {
                    Label("Antworten eintippen", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(Pill(tint: mint))
                Button {
                    begin(setup.cards, mode: .flip)
                } label: {
                    Label("Karten umdrehen", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(Pill())
                HStack {
                    Spacer()
                    Button("Abbrechen") { practiceSetup = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 350)
        }
        .sheet(isPresented: $camera) {
            CameraSheet { data in
                process(title: "Kameraaufnahme") {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 3200
                          ] as CFDictionary) else { throw StudyError.unreadable }
                    return try Worksheet.recognize(image)
                }
            }
        }
        .sheet(item: $overviewCard) { card in
            VStack(alignment: .trailing, spacing: 14) {
                ScrollView {
                    HStack(alignment: .top, spacing: 12) {
                        PaperCardFace(text: card.question, artwork: nil)
                        PaperCardFace(text: card.answer, artwork: CardArtwork(card), explanation: card.learningNote)
                    }
                }
                Button("Fertig") { overviewCard = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(22)
            .frame(width: 650, height: 410)
        }
        .sheet(item: $editing) { card in
            let existing = cards.contains { $0.id == card.id }
            EditCard(card: card, subjects: subjects, folders: folders, delete: existing ? {
                cards.removeAll { $0.id == card.id }
                session = []
                persist()
            } : nil) { updated in
                if let position = cards.firstIndex(where: { $0.id == updated.id }) {
                    var revised = updated
                    if cards[position].contentKey != updated.contentKey {
                        revised.review = nil
                        if revised.explanation == cards[position].explanation { revised.explanation = nil }
                    }
                    cards[position] = revised
                } else { cards.append(updated) }
                session = []
                persist()
            }
        }
        .alert("Drucken nicht verfügbar", isPresented: $printError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Druckseiten konnten nicht erstellt werden.")
        }
        .alert("Arbeitsblatt konnte nicht verarbeitet werden", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                Text("Blattkarten").font(.system(size: 18, weight: .bold))
            }
            .padding(.bottom, 14)
            navigation("Start", "house.fill")
            navigation("Sammlung", "rectangle.stack.fill")
            navigation("KI-Studio", "sparkles")
            navigation("Üben", "bolt.fill")
            Divider().padding(.vertical, 3)
            HStack {
                Text("Fächer").font(.caption.bold()).foregroundStyle(soft)
                Spacer()
                Button {
                    newSubject = ""
                    addingSubject = true
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(mint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fach hinzufügen")
                .help("Fach hinzufügen")
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(subjects, id: \.self) { subject in
                        subjectButton(subject)
                        if selectedSubject == subject { sidebarFolders }
                    }
                }
            }
            Button { showingPet = true } label: {
                HStack(spacing: 6) {
                    FlamePet(outfit: Outfit(pet.outfit)).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lernflamme").font(.caption.bold()).foregroundStyle(.white)
                        let streak = pet.streak(at: reviewClock)
                        Text("\(streak) \(streak == 1 ? "Lerntag" : "Lerntage")").font(.caption2).foregroundStyle(mint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
                .background(panel, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet den Kleiderschrank")
            Label("Lokal auf diesem Mac", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(soft)
        }
        .padding(20).padding(.top, 16)
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.105, green: 0.077, blue: 0.16))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
    }

    func subjectButton(_ subject: String) -> some View {
        let icon = Self.defaultSubjects.first { $0.0 == subject }?.1 ?? "folder"
        let selected = selectedSubject == subject
        return Button {
            selectedSubject = subject
            showFolder(nil)
        } label: {
            HStack {
                Label(subject, systemImage: icon).lineLimit(1)
                Spacer(minLength: 4)
                Text(cards.lazy.filter { $0.subjectName == subject }.count.formatted())
                    .font(.caption2.monospacedDigit()).foregroundStyle(soft)
                    .accessibilityLabel("Karten im Fach")
            }
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? mint : soft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selected ? mint.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sidebarFolders: some View {
        let children = Dictionary(grouping: folders.filter { $0.subject == selectedSubject }, by: \.parentID)
        func branches(_ parent: UUID?, depth: Int) -> [(folder: WorksheetFolder, depth: Int)] {
            (children[parent] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .flatMap { [($0, depth)] + branches($0.id, depth: depth + 1) }
        }

        return ForEach(branches(nil, depth: 0), id: \.folder.id) { entry in
            let selected = entry.folder.id == currentFolderID
            Button { showFolder(entry.folder.id) } label: {
                Label(entry.folder.name, systemImage: selected ? "folder.fill" : "folder")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(selected ? mint : soft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.leading, CGFloat(19 + min(entry.depth, 4) * 10))
                    .background(selected ? mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("Unterordner hinzufügen") {
                    showFolder(entry.folder.id)
                    newFolder = ""
                    addingFolder = true
                }
            }
        }
    }

    func addSubject() {
        guard canAddSubject else { return }
        let custom = Array(subjects.dropFirst(Self.defaultSubjects.count)) + [trimmedSubject]
        guard let data = try? JSONEncoder().encode(custom) else { return }
        savedSubjects = data
        selectedSubject = trimmedSubject
    }

    func showFolder(_ id: UUID?) {
        currentFolderID = id
        search = ""
        page = "Sammlung"
        session = []
        flipped = false
        appeared = true
    }

    func addFolder() {
        guard canAddFolder else { return }
        let folder = WorksheetFolder(subject: selectedSubject, parentID: currentFolder?.id, name: trimmedFolder)
        guard let data = try? JSONEncoder().encode(folders + [folder]) else { return }
        savedFolders = data
        showFolder(folder.id)
    }

    var folderHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let folder = currentFolder {
                let parentName = folders.first { $0.id == folder.parentID }?.name ?? selectedSubject
                Button { showFolder(folder.parentID) } label: {
                    Label(parentName, systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(mint)
            }
            HStack(spacing: 12) {
                Text(location).font(.system(size: 39, weight: .bold)).lineLimit(1)
                Button {
                    newFolder = ""
                    addingFolder = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(mint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ordner hinzufügen")
                .help(currentFolder == nil ? "Ordner hinzufügen" : "Unterordner hinzufügen")
            }
            if currentFolder == nil {
                Text("Arbeitsblätter und Karteikarten für dieses Fach").foregroundStyle(soft)
            }
        }
    }

    var folderGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(childFolders) { folder in
                Button { showFolder(folder.id) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder.fill").foregroundStyle(lilac)
                        Text(folder.name).lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right").foregroundStyle(soft).font(.caption)
                    }
                    .padding(12)
                    .background(panel, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    func navigation(_ title: String, _ icon: String) -> some View {
        Button {
            if title == "KI-Studio" {
                startAIImport()
            } else if title == "Üben", session.isEmpty, !practiceCards.isEmpty {
                choosePracticeMode(dueCards.isEmpty ? practiceCards : dueCards)
            } else {
                page = title
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(page == title ? .white : soft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(page == title ? Color(red: 0.38, green: 0.24, blue: 0.68) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private var generatorWorkspace: some View {
        GeneratorStudio(
            destination: [selectedSubject, currentFolder?.name].compactMap { $0 }.joined(separator: " / "),
            subjects: subjects,
            activeSubject: selectedSubject,
            insideFolder: currentFolder != nil,
            usesCloud: tutorSettings.provider == .openAI,
            preferredModel: tutorSettings.model,
            generate: generateInStudio,
            save: { drafts, title, subject in
                let destination = subject ?? selectedSubject
                storeImport(drafts, title: title, subject: destination,
                            folderID: destination == selectedSubject ? currentFolder?.id : nil)
                selectedSubject = destination
                page = "Sammlung"
            }
        )
    }

    private var dashboard: some View {
        let due = cards.lazy.filter { $0.isDue(at: reviewClock) }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                Text("Dein Lernstudio")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Aus Lernstoff werden Karten.")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Starte mit einem Foto, PDF oder deinem Lerntext.")
                            .foregroundStyle(ink.opacity(0.78))
                        Button(action: startAIImport) {
                            Label("KI-Studio öffnen", systemImage: "sparkles")
                        }.buttonStyle(Pill(tint: .white))
                    }
                    Spacer(minLength: 0)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 104, height: 104)
                        .accessibilityHidden(true)
                }
                .padding(23)
                .background(
                    LinearGradient(colors: [Color(red: 0.89, green: 0.82, blue: 1), Color(red: 0.68, green: 0.69, blue: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                HStack(spacing: 10) {
                    dashboardStat("Karten", count: cards.count, icon: "rectangle.on.rectangle", tint: lilac)
                    dashboardStat("Fällig", count: due, icon: "clock", tint: mint)
                    dashboardStat("Lerntage in Folge", count: pet.streak(at: reviewClock), icon: "flame.fill", tint: .orange)
                }
                HStack(spacing: 10) {
                    Button { choosePracticeMode(dueCards.isEmpty ? practiceCards : dueCards) } label: {
                        Label("\(location) üben", systemImage: "bolt.fill").lineLimit(1)
                    }.buttonStyle(Pill(tint: mint)).disabled(practiceCards.isEmpty)
                    Button { page = "Sammlung" } label: {
                        Label("Zur Sammlung", systemImage: "rectangle.stack")
                    }.buttonStyle(Pill())
                    Button { camera = true } label: {
                        Label("Kamera öffnen", systemImage: "camera")
                    }.buttonStyle(Pill()).disabled(busy)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Fächer").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 9)], spacing: 9) {
                        ForEach(subjects, id: \.self) { subject in
                            Button {
                                selectedSubject = subject
                                showFolder(nil)
                            } label: {
                                HStack {
                                    Text(subject).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(lilac)
                                }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(26).padding(.bottom, 45)
        }
    }

    private func dashboardStat(_ title: String, count: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(count.formatted()).font(.system(size: 25, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(panel, in: RoundedRectangle(cornerRadius: 13))
    }

    var collection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 12) {
                    folderHeader
                    Spacer(minLength: 0)
                    Button { camera = true } label: {
                        Label("Kamera", systemImage: "camera")
                    }.buttonStyle(Pill()).disabled(busy)
                    Button { chooseFile() } label: {
                        Label("Importieren", systemImage: "arrow.down.document")
                    }.buttonStyle(Pill(tint: lilac)).disabled(busy)
                }
                .padding(16)
                .background(lilac.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                if !childFolders.isEmpty { folderGrid }
                if displayedCards.isEmpty || busy { importPanel }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Karteikarten")
                            .font(.title2.bold()).lineLimit(1)
                        Text(searchActive ? "\(displayedCards.count) Treffer" : "\(visibleCards.count) \(visibleCards.count == 1 ? "Karte" : "Karten")")
                            .font(.caption).foregroundStyle(soft)
                    }
                    Spacer()
                    Button { editing = Card(question: "", answer: "", subject: selectedSubject, folderID: currentFolder?.id) } label: {
                        Label("Karte", systemImage: "plus")
                    }.buttonStyle(Pill())
                    if !cards.isEmpty {
                        Menu {
                            if currentFolder != nil {
                                Button("Diesen Ordner drucken") { printError = !CardPrinting.printAll(visibleCards) }
                                    .disabled(visibleCards.isEmpty)
                                    .keyboardShortcut("p")
                            }
                            Button("Dieses Fach drucken") { printError = !CardPrinting.printAll(subjectCards) }
                                .disabled(subjectCards.isEmpty)
                            Button("Alle Fächer drucken") { printError = !CardPrinting.printAll(cards) }
                        } label: {
                            Label("Drucken", systemImage: "printer")
                        }
                        .fixedSize()
                    }
                    if !practiceCards.isEmpty {
                        Menu {
                            Button("Fällige Karten (\(dueCards.count))") { choosePracticeMode(dueCards) }.disabled(dueCards.isEmpty)
                            Button("Alle Karten üben") { choosePracticeMode(practiceCards) }
                            if searchActive {
                                Button("Suchtreffer üben") { choosePracticeMode(displayedCards) }.disabled(displayedCards.isEmpty)
                            }
                        } label: {
                            Label("Üben", systemImage: "bolt.fill")
                        }
                        .fixedSize()
                    }
                }
                if !tutorCards.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(soft)
                        TextField("Karten oder Arbeitsblätter suchen", text: $search).textFieldStyle(.plain)
                        if searchActive {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(soft).accessibilityLabel("Suche leeren")
                        } else {
                            Text("\(dueCards.count) fällig").font(.caption).foregroundStyle(soft)
                        }
                    }
                    .padding(10).background(panel, in: RoundedRectangle(cornerRadius: 9))
                }
                HStack {
                    if !displayedCards.isEmpty {
                        Picker("Ansicht", selection: $compactOverview) {
                            Text("Vorder- und Rückseite").tag(false)
                            Text("Übersicht").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Kartenansicht")
                    }
                    Spacer()
                    if selectedSubject == "Biologie", !visibleCards.contains(where: { $0.worksheet == "Neurobiologie · Beispiele" }) {
                        Button("Neurobiologie-Beispiele hinzufügen") { addNeurobiologyExamples() }
                            .buttonStyle(Pill())
                    }
                }
                if displayedCards.isEmpty {
                    Text(searchActive ? "Keine passenden Karten gefunden." : "Hier erscheinen deine Karten nach dem ersten Import.")
                        .foregroundStyle(soft).padding(.vertical, 12)
                } else if compactOverview {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 12)], spacing: 12) {
                        ForEach(displayedCards) { card in
                            Button { overviewCard = card } label: { CompactLearningCard(card: card) }
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 470), spacing: 20)], spacing: 20) {
                        ForEach(Array(displayedCards.enumerated()), id: \.element.id) { index, card in
                            PaperCardPair(
                                card: card,
                                source: card.worksheet ?? (card.subject == nil && !legacyTitle.isEmpty ? legacyTitle : nil),
                                edit: { editing = card }
                            )
                            .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -8))
                            .offset(y: appeared || reduceMotion ? 0 : 52)
                            .opacity(appeared ? 1 : 0)
                            .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.68).delay(Double(min(index, 12)) * 0.048), value: appeared)
                        }
                    }
                }
            }.padding(32).padding(.bottom, 42)
        }
    }

    private func addNeurobiologyExamples() {
        var known = Set(visibleCards.map(\.contentKey))
        let fresh = NeurobiologyExamples.cards.filter { known.insert($0.contentKey).inserted }
        cards = fresh.map { draft in
            var card = draft
            card.subject = selectedSubject
            card.folderID = currentFolder?.id
            card.worksheet = "Neurobiologie · Beispiele"
            return card
        } + cards
        compactOverview = true
        persist()
    }

    var importPanel: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(busy ? "Karten entstehen …" : "Arbeitsblatt einlesen")
                    .font(.system(size: 25, weight: .bold))
                Text(busy ? "Die App sucht nach den wichtigsten Aussagen." :
                        "Fotografiere dein Blatt oder öffne ein Bild oder PDF. Ein neuer Import ergänzt deine Sammlung.")
                    .foregroundStyle(soft).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 9) {
                    Button { camera = true } label: {
                        Label("Kamera öffnen", systemImage: "camera")
                    }.buttonStyle(Pill(tint: mint))
                    Button { chooseFile() } label: {
                        Label("Datei öffnen", systemImage: "arrow.up.document")
                    }.buttonStyle(Pill())
                    Button(action: startAIImport) {
                        Label("KI-Generator", systemImage: "sparkles")
                    }.buttonStyle(Pill())
                }.disabled(busy)
            }
            Spacer(minLength: 4)
            CardStack(busy: busy, reduceMotion: reduceMotion).frame(width: 132, height: 112).accessibilityHidden(true)
        }
        .padding(24)
        .background(LinearGradient(colors: [panel, lilac.opacity(0.18)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 21))
        .overlay {
            RoundedRectangle(cornerRadius: 21).strokeBorder(hovering ? mint : lilac.opacity(0.23), lineWidth: 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !busy else { return false }
            importFile(url)
            return true
        } isTargeted: { hovering = $0 }
    }

    var practice: some View {
        VStack(spacing: 0) {
            if !session.isEmpty {
                PracticeProgressBar(completed: cursor, total: session.count)
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                Divider().overlay(.white.opacity(0.06))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    Text("Üben · \(location)").font(.system(size: 39, weight: .bold))
                    if session.isEmpty {
                        Text("Füge diesem Fach zuerst Karten hinzu.").foregroundStyle(soft)
                        Button("Zur Sammlung") { page = "Sammlung" }.buttonStyle(Pill(tint: mint))
                    } else if cursor >= session.count {
                        VStack(alignment: .leading, spacing: 17) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(mint)
                            Text("Runde geschafft").font(.largeTitle.bold())
                            Text("\(known) von \(session.count) gewusst").font(.title3).foregroundStyle(soft)
                            HStack {
                                if !missed.isEmpty {
                                    Button("\(missed.count) wiederholen") { choosePracticeMode(missed) }.buttonStyle(Pill(tint: mint))
                                }
                                Button("Alle neu mischen") { choosePracticeMode(practiceCards) }.buttonStyle(Pill())
                            }
                        }.padding(30).frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                            .background(panel, in: RoundedRectangle(cornerRadius: 22))
                    } else {
                        let card = session[cursor]
                        Text("Karte \(cursor + 1) von \(session.count)").font(.subheadline.bold()).foregroundStyle(soft)
                        if retryingCard {
                            Label("Noch ein Versuch", systemImage: "arrow.counterclockwise")
                                .font(.caption.bold())
                                .foregroundStyle(Color(red: 1, green: 0.70, blue: 0.71))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(Color(red: 0.43, green: 0.17, blue: 0.23), in: RoundedRectangle(cornerRadius: 7))
                        }
                        Button {
                            togglePracticeCard()
                        } label: {
                            FlipCard(question: card.question, answer: card.answer, artwork: CardArtwork(card), explanation: card.learningNote, angle: flipped ? 180 : 0, reduceMotion: reduceMotion)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(flipped ? card.answer : card.question)
                        .accessibilityHint("Dreht die Karte um")
                        .keyboardShortcut(typingPracticeAnswer ? nil : KeyboardShortcut(.space, modifiers: []))
                        if flipped {
                            if !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Deine Antwort").font(.caption.bold()).foregroundStyle(mint)
                                    ScrollView {
                                        Text(typedAnswer).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .bounceWhenContentOverflows()
                                    .frame(maxHeight: 58)
                                }
                                .padding(10)
                                .background(panel, in: RoundedRectangle(cornerRadius: 8))
                            }
                            HStack {
                                Button("Nochmal") { advance(false) }.buttonStyle(Pill())
                                    .keyboardShortcut(.leftArrow, modifiers: [])
                                Button("Gewusst") { advance(true) }.buttonStyle(Pill(tint: mint))
                                    .keyboardShortcut(.rightArrow, modifiers: [])
                            }
                        } else if practiceMode == .typing {
                            HStack(spacing: 10) {
                                TextField("Deine Antwort eingeben", text: $typedAnswer)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($typingPracticeAnswer)
                                    .onSubmit { togglePracticeCard() }
                                    .accessibilityHint("Mit der Eingabetaste die Musterantwort anzeigen")
                                Button("Antwort anzeigen") { togglePracticeCard() }
                                    .buttonStyle(Pill(tint: mint))
                            }
                            Text("Mit der Eingabetaste vergleichen oder die Karte per Klick umdrehen.")
                                .font(.caption).foregroundStyle(soft)
                        } else {
                            Text("Klicke auf die Karte oder drücke die Leertaste, um die Antwort zu sehen.")
                                .font(.caption).foregroundStyle(soft)
                        }
                    }
                }
                .padding(32).padding(.bottom, 42)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func togglePracticeCard() {
        typingPracticeAnswer = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { flipped.toggle() }
    }

    private func choosePracticeMode(_ deck: [Card]) {
        guard !deck.isEmpty else { return }
        practiceSetup = PracticeSetup(cards: deck)
    }

    private func begin(_ deck: [Card], mode: PracticeMode) {
        practiceMode = mode
        practiceSetup = nil
        session = deck.shuffled()
        cursor = 0
        known = 0
        missed = []
        retryingCard = false
        typedAnswer = ""
        flipped = false
        page = "Üben"
    }

    func advance(_ understood: Bool) {
        guard flipped, session.indices.contains(cursor) else { return }
        if !understood && !retryingCard {
            retryingCard = true
            typedAnswer = ""
            togglePracticeCard()
            return
        }

        let card = session[cursor]
        if understood { known += 1 } else { missed.append(card) }
        if let position = cards.firstIndex(where: { $0.id == card.id }) {
            reviewClock = .now
            cards[position].review = LearningProgress.after(cards[position].review, understood: understood, now: reviewClock)
            persist()
            rewardStudy(worksheet: false)
        }
        typedAnswer = ""
        retryingCard = false
        flipped = false
        cursor += 1
    }

    private func refreshDesktopFlame() {
        desktopFlame.update(pet: pet, visible: flameOnDesktop) { flameOnDesktop = false }
    }

    private func savePet() {
        if let data = try? JSONEncoder().encode(pet) { savedPet = data }
        pet.publish()
        refreshDesktopFlame()
    }

    private func rewardStudy(worksheet: Bool) {
        pet.activity(worksheet: worksheet)
        savePet()
    }

    func persist() { if let encoded = try? JSONEncoder().encode(cards) { saved = encoded } }

    func startAIImport() {
        tutorOpen = false
        page = "KI-Studio"
    }

    private func generateInStudio(_ text: String, limit: Int, model: String, timeout: TimeInterval) async throws -> [Card] {
        let backend: TutorClient.Backend
        if tutorSettings.provider == .openAI {
            let key = tutorSettings.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw TutorClient.Failure.server(401) }
            backend = .openAI(key)
        } else {
            guard !model.isEmpty else { throw TutorClient.Failure.unavailable }
            backend = .local(model)
        }
        return try await TutorClient.createCards(backend: backend, worksheet: text, localTimeout: timeout, limit: limit)
    }

    func chooseFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image, .pdf]
        picker.allowsMultipleSelection = false
        picker.message = "Wähle ein Arbeitsblatt als Bild oder PDF."
        if picker.runModal() == .OK, let url = picker.url { importFile(url) }
    }

    func importFile(_ url: URL) {
        process(title: url.deletingPathExtension().lastPathComponent) { try Worksheet.read(url) }
    }

    func process(title: String, load: @escaping @Sendable () throws -> String) {
        guard !busy else { return }
        let importSubject = selectedSubject
        let importFolderID = currentFolder?.id
        let availableSubjects = subjects
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let text = try await Task.detached { try load() }.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudyError.empty }
                let result = await Task.detached {
                    let cards = Worksheet.cards(from: text)
                    let subject = importFolderID == nil
                        ? Worksheet.suggestedSubject(for: text, title: title, available: availableSubjects) : nil
                    return (cards, subject)
                }.value
                guard !result.0.isEmpty else { throw StudyError.noFacts }
                let destination = result.1 ?? importSubject
                let shouldFollow = selectedSubject == importSubject && currentFolder?.id == importFolderID
                storeImport(result.0, title: title, subject: destination, folderID: importFolderID)
                if shouldFollow {
                    selectedSubject = destination
                    page = "Sammlung"
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func storeImport(_ drafts: [Card], title: String, subject: String, folderID: UUID?) {
        var known = Set(cards.filter { $0.subjectName == subject && $0.folderID == folderID }.map(\.contentKey))
        let fresh = drafts.filter { known.insert($0.contentKey).inserted }
        guard !fresh.isEmpty else {
            importNotice = "Diese Karten gibt es hier bereits."
            return
        }
        let visible = selectedSubject == subject && currentFolder?.id == folderID
        if visible { appeared = reduceMotion }
        cards = fresh.map { draft in
            var card = draft
            card.subject = subject
            card.worksheet = title
            card.folderID = folderID
            return card
        } + cards
        persist()
        rewardStudy(worksheet: true)
        if visible {
            Task { @MainActor in
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(90)) }
                appeared = true
            }
        }
    }

}

private struct PracticeProgressBar: View {
    let completed: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var body: some View {
        HStack(spacing: 13) {
            GeometryReader { proxy in
                Capsule()
                    .fill(Color(red: 0.22, green: 0.25, blue: 0.31))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [
                                Color(red: 0.28, green: 0.86, blue: 0.51),
                                Color(red: 0.55, green: 0.97, blue: 0.61)
                            ], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * fraction)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: fraction)
                    }
            }
            .frame(height: 13)
            Text("\(completed) / \(total)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(fraction == 1 ? mint : soft)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Übungsfortschritt")
        .accessibilityValue("\(completed) von \(total) Karten bearbeitet")
    }
}

struct FlipCard: View, Animatable {
    let question: String
    let answer: String
    let artwork: CardArtwork
    let explanation: String?
    var angle: Double
    let reduceMotion: Bool
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    var body: some View {
        let back = angle >= 90
        ScrollView {
            PaperCardFace(text: back ? answer : question, artwork: back ? artwork : nil,
                          explanation: back ? explanation : nil, large: true)
        }
        .bounceWhenContentOverflows()
        .frame(height: 304)
        .background(PaperCardFace.paperColor(back: back), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .rotation3DEffect(.degrees(reduceMotion ? 0 : angle - (back ? 180 : 0)), axis: (0, 1, 0), perspective: 0.45)
    }
}

struct CardStack: View {
    let busy: Bool
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(paused: !busy || reduceMotion)) { context in
            let phase = busy && !reduceMotion ? sin(context.date.timeIntervalSinceReferenceDate * 5) : 0
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(lilac)
                    .frame(width: 66, height: 87).rotationEffect(.degrees(-23 - phase * 13))
                    .offset(x: -21 - phase * 9, y: -1)
                RoundedRectangle(cornerRadius: 14).fill(mint)
                    .frame(width: 66, height: 87).rotationEffect(.degrees(22 + phase * 13))
                    .offset(x: 23 + phase * 9, y: 2)
                RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.96, green: 0.95, blue: 1))
                    .frame(width: 66, height: 87)
                    .overlay {
                        Image(systemName: "sparkles").font(.system(size: 31, weight: .medium)).foregroundStyle(ink)
                    }
                    .rotationEffect(.degrees(-4 + phase * 9))
                    .offset(y: -phase * 10)
                    .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            }
        }
    }
}

struct Pill: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(tint == nil ? .white : ink)
            .background(tint ?? .white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

struct EditCard: View {
    @State var card: Card
    let subjects: [String]
    let folders: [WorksheetFolder]
    @Environment(\.dismiss) private var dismiss
    let delete: (() -> Void)?
    let save: (Card) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Karte bearbeiten").font(.title2.bold())
            Picker("Fach", selection: Binding(
                get: { card.subjectName },
                set: { newSubject in
                    if card.subjectName != newSubject { card.folderID = nil }
                    card.subject = newSubject
                }
            )) {
                ForEach(subjects, id: \.self) { Text($0).tag($0) }
            }
            Picker("Ordner", selection: $card.folderID) {
                Text("Fachebene").tag(nil as UUID?)
                ForEach(folders.filter { $0.subject == card.subjectName }) { folder in
                    Text(folderPath(folder)).tag(Optional(folder.id))
                }
            }
            Text("Frage").font(.headline)
            TextEditor(text: $card.question).frame(height: 70).border(.secondary.opacity(0.3))
            Text("Antwort").font(.headline)
            TextEditor(text: $card.answer).frame(height: 95).border(.secondary.opacity(0.3))
            TextField("Erklärung oder Beispiel (optional)", text: Binding(
                get: { card.explanation ?? "" },
                set: { card.explanation = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder)
            HStack {
                if let delete {
                    Button("Karte löschen", role: .destructive) { delete(); dismiss() }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { save(card); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(card.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              card.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 475)
    }

    private func folderPath(_ folder: WorksheetFolder) -> String {
        var names = [folder.name]
        var seen: Set<UUID> = [folder.id]
        var parentID = folder.parentID
        while let id = parentID, seen.insert(id).inserted,
              let parent = folders.first(where: { $0.id == id }) {
            names.append(parent.name)
            parentID = parent.parentID
        }
        return names.reversed().joined(separator: " / ")
    }
}

@main struct BlattkartenApp: App {
    @State private var checking = false
    @State private var showingUpdate = false
    @State private var available: Updates.Available?
    @State private var updateMessage = ""

    var body: some Scene {
        WindowGroup {
            ContentView()
                .alert("Blattkarten-Updates", isPresented: $showingUpdate) {
                    if let available {
                        Button("DMG laden") { NSWorkspace.shared.open(available.download) }
                        Button("Später", role: .cancel) {}
                    } else {
                        Button("OK", role: .cancel) {}
                    }
                } message: {
                    Text(updateMessage)
                }
        }
            .defaultSize(width: 1030, height: 760)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Nach Updates suchen …") { checkForUpdate() }
                        .disabled(checking)
                }
            }
    }

    private func checkForUpdate() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.15"
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                available = try await Updates.latest(current: current)
                if let available {
                    updateMessage = "Version \(available.version) ist verfügbar. Lade das DMG herunter, um sie zu installieren."
                } else {
                    updateMessage = "Für deine Version \(current) ist derzeit kein neueres Update verfügbar."
                }
            } catch {
                available = nil
                updateMessage = "GitHub konnte nicht nach einem Update abgefragt werden. Versuche es später erneut."
            }
            showingUpdate = true
        }
    }
}


private extension View {
    @ViewBuilder
    func bounceWhenContentOverflows() -> some View {
        if #available(macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

private struct GeneratorStudio: View {
    let destination: String
    let subjects: [String]
    let activeSubject: String
    let insideFolder: Bool
    let usesCloud: Bool
    let preferredModel: String
    let generate: (String, Int, String, TimeInterval) async throws -> [Card]
    let save: ([Card], String, String?) -> Void

    @State private var source = ""
    @State private var suggestedSubject: String?
    @State private var chosenSubject: String?
    @State private var title = "KI-Karten"
    @State private var limit = 6
    @State private var pending = false
    @State private var cards: [Card] = []
    @State private var failure: String?
    @State private var fallbackNotice: String?
    @State private var confirmCloud = false
    @State private var isPreview = false
    @State private var useAI = false
    @State private var availableModels: [String] = []
    @State private var model = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(lilac)
                    .frame(width: 55, height: 55)
                    .background(lilac.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isPreview ? "Karten prüfen" : "KI-Karteikarten")
                        .font(.system(size: 28, weight: .bold))
                    Label(chosenSubject ?? suggestedSubject ?? destination, systemImage: "folder").foregroundStyle(soft)
                }
                Spacer()
                if isPreview {
                    Text(cards.count.formatted()).font(.title2.monospacedDigit().bold()).foregroundStyle(lilac)
                }
            }
            .padding(18)
            .background(LinearGradient(colors: [panel, lilac.opacity(0.20)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 18))

            if isPreview {
                Picker("Speichern in", selection: $chosenSubject) {
                    Text(suggestedSubject.map { "\($0) · automatisch erkannt" } ?? destination).tag(nil as String?)
                    ForEach(subjects, id: \.self) { subject in
                        Text(subject == activeSubject && insideFolder ? destination : subject).tag(Optional(subject))
                    }
                }.frame(maxWidth: 390)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(cards) { card in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(card.question).font(.headline)
                                    Spacer()
                                    Button(role: .destructive) {
                                        cards.removeAll { $0.id == card.id }
                                    } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Karte entfernen")
                                }
                                Text(card.answer).textSelection(.enabled)
                                let artwork = CardArtwork(card)
                                if artwork != .concept {
                                    CardIllustration(artwork: artwork)
                                        .frame(width: 102, height: 47)
                                        .foregroundStyle(lilac)
                                        .accessibilityHidden(true)
                                }
                                if let source = card.sourceExcerpt {
                                    DisclosureGroup("Belegstelle") {
                                        Text(source).textSelection(.enabled).padding(.top, 5)
                                    }.font(.caption).foregroundStyle(soft)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(panel, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if cards.isEmpty { Text("Keine Karten ausgewählt.").foregroundStyle(soft) }
                    }
                }
            } else {
                HStack {
                    Button(action: loadFile) {
                        Label("Bild oder PDF öffnen", systemImage: "photo.on.rectangle")
                    }.buttonStyle(Pill())
                    Spacer()
                    Text("\(source.count.formatted(.number.locale(Locale(identifier: "de_DE")))) / 60.000 Zeichen")
                        .font(.caption.monospacedDigit()).foregroundStyle(source.count > Worksheet.studioTextLimit ? .orange : soft)
                }.disabled(pending)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Lerntext").font(.headline)
                    TextEditor(text: $source)
                        .accessibilityLabel("Lerntext")
                        .font(.body)
                        .padding(7)
                        .scrollContentBackground(.hidden)
                        .background(panel, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(pending)
                }
                Picker("Erstellung", selection: $useAI) {
                    Label("Schnell", systemImage: "bolt.fill").tag(false)
                    Label("Mit KI", systemImage: "sparkles").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(pending)
                .onChange(of: useAI) { enabled in
                    failure = nil
                    if enabled && !usesCloud { Task { await loadModels() } }
                }
                HStack {
                    Text("Kartenlimit").font(.subheadline.weight(.semibold))
                    Picker("Kartenlimit", selection: $limit) {
                        Text("3 Karten").tag(3)
                        Text("6 Karten").tag(6)
                        Text("10 Karten").tag(10)
                        Text("20 Karten").tag(20)
                    }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 305).disabled(pending)
                    Spacer()
                    if !useAI {
                        Text("Lokal auf diesem Mac").font(.caption).foregroundStyle(soft)
                    } else if usesCloud {
                        Text("OpenAI").font(.caption).foregroundStyle(soft)
                    } else if !availableModels.isEmpty {
                        Picker("Ollama-Modell", selection: $model) {
                            ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: 150).disabled(pending)
                    } else {
                        Button("Ollama prüfen") { Task { await loadModels() } }
                            .buttonStyle(Pill()).disabled(pending)
                    }
                }
            }
            if let failure { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            if isPreview, let fallbackNotice {
                Label(fallbackNotice, systemImage: "bolt.fill").font(.subheadline).foregroundStyle(lilac)
            }
            Divider()
            HStack {
                if isPreview {
                    Button("Zurück zum Lerntext") { isPreview = false }.buttonStyle(Pill())
                } else if pending {
                    ProgressView().controlSize(.small)
                    Text("Lernmaterial wird verarbeitet …").foregroundStyle(soft)
                }
                Spacer()
                if isPreview {
                    Button("\(cards.count) Karten speichern") {
                        save(cards, title, chosenSubject ?? suggestedSubject)
                    }.buttonStyle(Pill(tint: mint)).disabled(cards.isEmpty)
                } else {
                    Button {
                        if useAI && usesCloud { confirmCloud = true } else { startGeneration() }
                    } label: { Label("Karten generieren", systemImage: "sparkles") }
                    .buttonStyle(Pill(tint: mint))
                    .disabled(pending || (useAI && !usesCloud && model.isEmpty) || source.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 || source.count > Worksheet.studioTextLimit)
                }
            }
        }
        .padding(24)
        .padding(.bottom, 48)
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .confirmationDialog("Lerntext an OpenAI senden?", isPresented: $confirmCloud) {
            Button("Text senden und Karten erstellen") { startGeneration() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("OpenAI verarbeitet den Text aus dem Editor. Dabei können API-Kosten anfallen.")
        }
    }

    private func loadModels() async {
        do {
            let models = try await TutorClient.localModels()
            availableModels = models
            model = models.contains(preferredModel) ? preferredModel :
                (models.first { $0 == "qwen2.5:1.5b" } ?? models.first ?? "")
            if useAI { failure = models.isEmpty ? "Installiere ein lokales Modell in Ollama und prüfe erneut." : nil }
        } catch { if useAI { failure = error.localizedDescription } }
    }

    private func loadFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image, .pdf]
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK, !picker.urls.isEmpty else { return }
        let urls = picker.urls
        pending = true
        failure = nil
        Task { @MainActor in
            defer { pending = false }
            do {
                let text = try await Task.detached {
                    try urls.map(Worksheet.read).joined(separator: "\u{000C}")
                }.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudyError.empty }
                source = text
                title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "\(urls.count) Dateien"
                if text.count > Worksheet.studioTextLimit { failure = "Kürze den Lerntext auf höchstens 60.000 Zeichen." }
            } catch { failure = error.localizedDescription }
        }
    }

    private func startGeneration() {
        let input = source
        let count = limit
        let selectedModel = model
        let useAI = useAI
        pending = true
        failure = nil
        fallbackNotice = nil
        Task { @MainActor in
            defer { pending = false }
            do {
                let quick = useAI && usesCloud ? [] : await Task.detached {
                    Array(Worksheet.cards(from: input).prefix(count))
                }.value
                if useAI {
                    do {
                        cards = try await generate(input, count, selectedModel, quick.isEmpty ? 75 : 20)
                    } catch where !quick.isEmpty && !Task.isCancelled {
                        cards = quick
                        fallbackNotice = "Ollama hat keine belegten Karten geliefert. Hier sind die Karten aus dem Schnellmodus."
                    }
                } else {
                    guard !quick.isEmpty else {
                        failure = "Im Schnellmodus wurden keine eindeutigen Karten gefunden. Versuche es mit der KI oder mit mehr erklärendem Text."
                        return
                    }
                    cards = quick
                }
                suggestedSubject = insideFolder ? nil :
                    Worksheet.suggestedSubject(for: input, title: title, available: subjects)
                chosenSubject = nil
                isPreview = true
            } catch let error as URLError where error.code == .timedOut {
                failure = "Ollama war zu langsam. Wähle ein kleineres Modell oder kürze den Lerntext."
            } catch { failure = error.localizedDescription }
        }
    }
}
