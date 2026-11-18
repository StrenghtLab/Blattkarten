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
        case .noFacts: "Auf dem Blatt wurden keine Aussagen für Karteikarten gefunden. Wähle ein Blatt mit Erklärungen, Definitionen oder Lösungen."
        case .camera: "Die Kamera ist nicht verfügbar. Prüfe den Zugriff in den Systemeinstellungen."
        }
    }
}

enum Worksheet {
    static func recognize(_ image: CGImage) throws -> String {
        let full = try recognizeRegion(image)
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

    private static func recognizeRegion(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        #if arch(x86_64)
        // Keep OCR usable on Intel Macs without a working Metal accelerator.
        for (stage, devices) in (try request.supportedComputeStageDevices) {
            if let cpu = devices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        try VNImageRequestHandler(cgImage: image).perform([request])
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
                    let unit = unitRows[index]
                    let answer: String
                    if has(#"^Stromstärke\s+[I1l]$"#, in: label), has("Ladung.*Zeit", in: meanings[index]) {
                        answer = "Elektrische Ladung, die pro Zeit durch eine Stelle fließt. Symbol: I. Einheit: Ampere (A)."
                    } else if has(#"^Spannung\s+U$"#, in: label), has("Energieunterschied.*Ladung", in: meanings[index]) {
                        answer = "Energieunterschied pro Ladung zwischen zwei Stellen. Symbol: U. Einheit: Volt (V)."
                    } else if has(#"^Widerstand\s+R$"#, in: label), has("Stromfluss hemmt", in: meanings[index]) {
                        answer = "Gibt an, wie stark ein Bauteil den Stromfluss hemmt. Symbol: R. Einheit: Ohm (Ω)."
                    } else {
                        answer = meanings[index] + "\nEinheit: " + unit
                    }
                    let term = label.replacingOccurrences(of: #"\s+[A-Za-z]$"#, with: "", options: .regularExpression)
                    add("Was beschreibt die Größe „\(term)“ und welche Einheit hat sie?", answer)
                }
            }
        }
        if has("Strom messen"), has("Spannung messen"), has("Wassermodell") {
            if has(#"Amperemeter\s+A\s+in Reihe[\s\S]{0,65}Stromweg"#) {
                add("Wie schließt du ein Amperemeter an?", "In Reihe in den Stromweg, dessen Stromstärke du messen willst.")
            }
            if has(#"vor der Verzweigung[\s\S]{0,25}Gesamtstrom"#), has("im oberen Zweig misst") {
                add("Wo misst du in einer Parallelschaltung den Gesamtstrom und wo den Zweigstrom?",
                    "Vor der Verzweigung misst du den Gesamtstrom. Im jeweiligen Zweig misst du den Strom durch diesen Zweig.")
            }
            if has(#"Voltmeter\s+V\s+parallel[\s\S]{0,85}anschließen"#) {
                add("Wie schließt du ein Voltmeter an?", "Parallel zu den beiden Anschlüssen des Bauteils. Es misst die Spannung zwischen diesen Punkten.")
            }
            if has("parallel", in: text), has("gemeinsame Anschlussknoten"), has("derselbe Strom nacheinander") {
                add("Woran erkennst du im Schaltbild eine Reihen- oder Parallelschaltung?",
                    "Verfolge die Leitungen. In Reihe durchläuft derselbe Strom die Bauteile nacheinander. Parallel liegen die Bauteile zwischen denselben zwei Anschlussknoten.")
            }
            if has("Wasserkreislauf"), has("Spannungsquelle"), has("Höhenunterschied"), has("Druckunterschied") {
                add("Wofür stehen Pumpe und Höhen- oder Druckunterschied im Wassermodell?",
                    "Die Pumpe entspricht der Spannungsquelle, zum Beispiel einer Batterie. Der Höhen- oder Druckunterschied entspricht der Spannung zwischen zwei Stellen.")
            }
            if has("Wassermenge pro Zeit"), has("Wasserrad"), has("Bauteil mit Widerstand") {
                add("Wofür stehen Wassermenge pro Zeit und Wasserrad im Stromkreis?",
                    "Die Wassermenge pro Zeit entspricht der Stromstärke. Das Wasserrad, das den Fluss hemmt, entspricht einem Bauteil mit Widerstand.")
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
            add("Wie berechnest du Spannung, Stromstärke und Widerstand mit dem Ohmschen Gesetz?",
                "U = R · I,  I = U / R,  R = U / I.")
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
            add("Wie rechnest du Milliampere in Ampere und Kiloohm in Ohm um?",
                "mA → A: durch 1.000 teilen.\nkΩ → Ω: mit 1.000 multiplizieren.")
        }
        return cards
    }

    static func cards(from text: String) -> [Card] {
        var questions = Set<String>()
        return text.components(separatedBy: "\u{000C}")
            .flatMap(pageCards)
            .filter { questions.insert($0.question.lowercased()).inserted }
    }

    private static func pageCards(_ text: String) -> [Card] {
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

        func add(_ question: String, _ answer: String, priority: Int) {
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 520 else { return }
            candidates.append(Candidate(card: Card(question: question, answer: clean), priority: priority, topic: topic))
        }

        func summarize(_ sentence: String) {
            let fact = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty, !fact.hasSuffix("?") else { return }
            if let parts = match(#"^(.{2,65}?)\s+(ist|sind|bezeichnet|bedeutet)\s+(.{6,})$"#, in: fact) {
                let plural = parts[1].lowercased() == "sind"
                add("\(plural ? "Was sind" : "Was ist") \(parts[0])?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{6,}?)(?:,)?\s+(weil|da|denn)\s+(.{5,})$"#, in: fact) {
                add("Warum gilt die Aussage „\(parts[0])“?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,55}?)\s+(besteht|bestehen)\s+aus\s+(.{5,})$"#, in: fact) {
                add("Woraus \(parts[1].lowercased()) \(parts[0])?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,55}?)\s+(entsteht|entstehen)\s+(.{5,})$"#, in: fact) {
                add("Wie \(parts[1].lowercased()) \(parts[0])?", parts[2], priority: 8)
            } else if let parts = match(#"^(.{2,55}?)\s+(wird|werden)\s+((?:durch|in|aus|bei|mit|von)\s+.{6,})$"#, in: fact) {
                add("Was passiert mit „\(parts[0])“?", parts[1] + " " + parts[2], priority: 7)
            } else if let parts = match(#"^(.{2,55}?)\s+(braucht|brauchen|benötigt|benötigen|enthält|enthalten|produziert|produzieren|speichert|speichern|verursacht|verursachen|schützt|schützen|transportiert|transportieren)\s+(.{4,})$"#, in: fact) {
                let subject = parts[0].prefix(1).lowercased() + parts[0].dropFirst()
                let startsWithArticle = match(#"^(der|die|das|ein|eine)\s+"#, in: parts[0]) != nil
                add("Was \(parts[1].lowercased()) \(startsWithArticle ? subject : parts[0])?", parts[2], priority: 7)
            } else if !topic.isEmpty, fact.split(whereSeparator: \.isWhitespace).count >= 5 {
                add("Was sollte man über „\(topic)“ wissen?", fact, priority: 3)
            } else if let parts = match(#"^((?:(?:der|die|das|ein|eine)\s+)?[^\s,]+)\s+(.{15,})$"#, in: fact) {
                add("Was sagt das Blatt über „\(parts[0])“?", fact, priority: 2)
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
                if let question = pendingQuestion { add(question, answer, priority: 10) }
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
                add("Was bedeutet „\(parts[0])“?", parts[1], priority: 9)
                continue
            }
            if !line.hasSuffix("."), !line.hasSuffix("!"),
               line.split(whereSeparator: \.isWhitespace).count <= 5,
               line.count <= 50,
               match(#"\b(?:ist|sind|hat|haben|wird|werden|entsteht|besteht)\b"#, in: line) == nil {
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
    @State private var confirmCloudImport = false
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
    @State private var page = "Sammlung"
    @State private var cursor = 0
    @State private var known = 0
    @State private var missed: [Card] = []
    @State private var flipped = false
    @State private var typedAnswer = ""
    @State private var practiceMode: PracticeMode = .flip
    @State private var practiceSetup: PracticeSetup?
    @FocusState private var typingPracticeAnswer: Bool
    @State private var busy = false
    @State private var camera = false
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
                if page == "Sammlung" { collection } else { practice }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RadialGradient(colors: [Color(red: 0.17, green: 0.18, blue: 0.32), ink],
                               center: .topTrailing, startRadius: 10, endRadius: 740)
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
        .onChange(of: flameOnDesktop) { refreshDesktopFlame() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) {
            reviewClock = $0
            desktopFlame.refreshTime($0)
        }
        .onChange(of: selectedSubject) {
            currentFolderID = nil
            search = ""
            page = "Sammlung"
            session = []
            flipped = false
            appeared = true
        }
        .confirmationDialog("Arbeitsblatt mit OpenAI verarbeiten?", isPresented: $confirmCloudImport) {
            Button("Datei wählen und Text senden") { chooseFile(usingAI: true) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Beim Import wird der erkannte Text des ausgewählten Arbeitsblatts an OpenAI gesendet. Es können API-Kosten anfallen.")
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
        .sheet(item: $editing) { card in
            let existing = cards.contains { $0.id == card.id }
            EditCard(card: card, subjects: subjects, folders: folders, delete: existing ? {
                cards.removeAll { $0.id == card.id }
                session = []
                persist()
            } : nil) { updated in
                if let position = cards.firstIndex(where: { $0.id == updated.id }) {
                    var revised = updated
                    if cards[position].contentKey != updated.contentKey { revised.review = nil }
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
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ink).frame(width: 38, height: 38)
                    .background(mint, in: RoundedRectangle(cornerRadius: 12))
                Text("Blattkarten").font(.system(size: 18, weight: .bold))
            }
            .padding(.bottom, 14)
            navigation("Sammlung", "rectangle.stack")
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
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.08, green: 0.10, blue: 0.17))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
    }

    func subjectButton(_ subject: String) -> some View {
        let icon = Self.defaultSubjects.first { $0.0 == subject }?.1 ?? "folder"
        let selected = selectedSubject == subject
        return Button {
            selectedSubject = subject
            showFolder(nil)
        } label: {
            Label(subject, systemImage: icon)
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
            if title == "Üben", session.isEmpty, !practiceCards.isEmpty {
                choosePracticeMode(dueCards.isEmpty ? practiceCards : dueCards)
            } else {
                page = title
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(page == title ? mint : soft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(page == title ? mint.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    var collection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                folderHeader
                if !childFolders.isEmpty { folderGrid }
                importPanel
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
                if displayedCards.isEmpty {
                    Text(searchActive ? "Keine passenden Karten gefunden." : "Hier erscheinen deine Karten nach dem ersten Import.")
                        .foregroundStyle(soft).padding(.vertical, 12)
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
                        Label("Datei mit KI", systemImage: "sparkles")
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
                    ProgressView(value: Double(cursor), total: Double(session.count)).tint(mint)
                    Button {
                        togglePracticeCard()
                    } label: {
                        FlipCard(question: card.question, answer: card.answer, artwork: CardArtwork(card), angle: flipped ? 180 : 0, reduceMotion: reduceMotion)
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
                                .scrollBounceBehavior(.basedOnSize)
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
        typedAnswer = ""
        flipped = false
        page = "Üben"
    }

    func advance(_ understood: Bool) {
        let card = session[cursor]
        if understood { known += 1 } else { missed.append(card) }
        if let position = cards.firstIndex(where: { $0.id == card.id }) {
            reviewClock = .now
            cards[position].review = LearningProgress.after(cards[position].review, understood: understood, now: reviewClock)
            persist()
            rewardStudy(worksheet: false)
        }
        typedAnswer = ""
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
        if tutorSettings.provider == .openAI {
            guard !tutorSettings.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                tutorOpen = true
                showTutorSetup = true
                return
            }
            confirmCloudImport = true
        } else {
            chooseFile(usingAI: true)
        }
    }

    func chooseFile(usingAI: Bool = false) {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image, .pdf]
        picker.allowsMultipleSelection = false
        picker.message = "Wähle ein Arbeitsblatt als Bild oder PDF."
        if picker.runModal() == .OK, let url = picker.url { importFile(url, usingAI: usingAI) }
    }

    func importFile(_ url: URL, usingAI: Bool = false) {
        process(title: url.deletingPathExtension().lastPathComponent, usingAI: usingAI) { try Worksheet.read(url) }
    }

    func process(title: String, usingAI: Bool = false, load: @escaping @Sendable () throws -> String) {
        guard !busy else { return }
        let importSubject = selectedSubject
        let importFolderID = currentFolder?.id
        let cloudKey = usingAI && tutorSettings.provider == .openAI
            ? tutorSettings.key.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let preferredModel = tutorSettings.model
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let text = try await Task.detached { try load() }.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudyError.empty }
                let generated: [Card]
                if usingAI {
                    let backend: TutorClient.Backend
                    if let cloudKey {
                        backend = .openAI(cloudKey)
                    } else {
                        let local = try await TutorClient.localModels()
                        guard let model = local.contains(preferredModel) ? preferredModel : local.first else {
                            throw TutorClient.Failure.unavailable
                        }
                        backend = .local(model)
                    }
                    generated = try await TutorClient.createCards(backend: backend, worksheet: text)
                } else {
                    generated = await Task.detached { Worksheet.cards(from: text) }.value
                    guard !generated.isEmpty else { throw StudyError.noFacts }
                }

                var knownCards = Set(cards.filter { $0.subjectName == importSubject && $0.folderID == importFolderID }.map(\.contentKey))
                let fresh = generated.filter { knownCards.insert($0.contentKey).inserted }
                guard !fresh.isEmpty else {
                    importNotice = "Diese Karten gibt es hier bereits."
                    return
                }
                if selectedSubject == importSubject && currentFolder?.id == importFolderID { appeared = reduceMotion }
                cards = fresh.map {
                    Card(id: $0.id, question: $0.question, answer: $0.answer, subject: importSubject, worksheet: title, folderID: importFolderID)
                } + cards
                persist()
                rewardStudy(worksheet: true)
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(90)) }
                appeared = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct FlipCard: View, Animatable {
    let question: String
    let answer: String
    let artwork: CardArtwork
    var angle: Double
    let reduceMotion: Bool
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    var body: some View {
        let back = angle >= 90
        ScrollView {
            PaperCardFace(text: back ? answer : question, artwork: back ? artwork : nil, large: true)
        }
        .scrollBounceBehavior(.basedOnSize)
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
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.9"
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
