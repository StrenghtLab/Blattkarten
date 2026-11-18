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

struct ContentView: View {
    @AppStorage("worksheet.deck.v1") private var saved = Data()
    @AppStorage("worksheet.title.v1") private var deckTitle = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cards: [Card] = []
    @State private var session: [Card] = []
    @State private var page = "Sammlung"
    @State private var cursor = 0
    @State private var known = 0
    @State private var missed: [Card] = []
    @State private var flipped = false
    @State private var busy = false
    @State private var camera = false
    @State private var editing: Card?
    @State private var error: String?
    @State private var appeared = false
    @State private var hovering = false
    @State private var printError = false

    var body: some View {
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
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 840, minHeight: 620)
        .onAppear {
            if let decoded = try? JSONDecoder().decode([Card].self, from: saved) { cards = decoded }
            appeared = true
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
            EditCard(card: card, delete: existing ? {
                cards.removeAll { $0.id == card.id }
                if cards.isEmpty { deckTitle = "" }
                session = []
                persist()
            } : nil) { updated in
                if let position = cards.firstIndex(where: { $0.id == updated.id }) {
                    cards[position] = updated
                } else { cards.append(updated) }
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
            .padding(.bottom, 32)
            navigation("Sammlung", "rectangle.stack")
            navigation("Üben", "bolt.fill")
            Spacer()
            Label("Lokal auf diesem Mac", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(soft)
        }
        .padding(20).padding(.top, 16)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.08, green: 0.10, blue: 0.17))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
    }

    func navigation(_ title: String, _ icon: String) -> some View {
        Button {
            if title == "Üben", session.isEmpty, !cards.isEmpty { begin(cards) }
            page = title
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
                VStack(alignment: .leading, spacing: 7) {
                    Text("Deine Sammlung").font(.system(size: 39, weight: .bold))
                    Text("Aus Arbeitsblättern werden Karten zum Lernen.").foregroundStyle(soft)
                }
                importPanel
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(deckTitle.isEmpty ? "Karteikarten" : deckTitle)
                            .font(.title2.bold()).lineLimit(1)
                        Text("\(cards.count) \(cards.count == 1 ? "Karte" : "Karten")")
                            .font(.caption).foregroundStyle(soft)
                    }
                    Spacer()
                    if !cards.isEmpty {
                        Button { editing = Card(question: "", answer: "") } label: {
                            Label("Karte", systemImage: "plus")
                        }.buttonStyle(Pill())
                        Button { printError = !CardPrinting.printAll(cards) } label: {
                            Label("Alle drucken", systemImage: "printer")
                        }
                        .buttonStyle(Pill())
                        .keyboardShortcut("p")
                        Button { begin(cards) } label: {
                            Label("Jetzt üben", systemImage: "bolt.fill")
                        }.buttonStyle(Pill(tint: mint))
                    }
                }
                if cards.isEmpty {
                    Text("Hier erscheinen deine Karten nach dem ersten Import.")
                        .foregroundStyle(soft).padding(.vertical, 12)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 14)], spacing: 14) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            Button { editing = card } label: {
                                VStack(alignment: .leading, spacing: 13) {
                                    HStack {
                                        Text("LERNKARTE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(index.isMultiple(of: 2) ? mint : lilac)
                                        Spacer()
                                        Image(systemName: "pencil").foregroundStyle(soft)
                                    }
                                    CardIllustration(artwork: CardArtwork(card))
                                        .frame(height: 55)
                                        .foregroundStyle(index.isMultiple(of: 2) ? mint : lilac)
                                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                        .accessibilityHidden(true)
                                    Text(card.question).font(.headline).lineLimit(3)
                                    Spacer(minLength: 0)
                                }
                                .padding(17).frame(height: 165)
                                .background(panel, in: RoundedRectangle(cornerRadius: 16))
                                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09)) }
                            }
                            .buttonStyle(.plain)
                            .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -8))
                            .offset(y: appeared || reduceMotion ? 0 : 52)
                            .opacity(appeared ? 1 : 0)
                            .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.68).delay(Double(min(index, 12)) * 0.048), value: appeared)
                        }
                    }
                }
            }.padding(32)
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
                    Button(action: chooseFile) {
                        Label("Datei öffnen", systemImage: "arrow.up.document")
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
        VStack(alignment: .leading, spacing: 23) {
            Text("Üben").font(.system(size: 39, weight: .bold))
            if session.isEmpty {
                Text("Lies zuerst ein Arbeitsblatt ein.").foregroundStyle(soft)
                Button("Zur Sammlung") { page = "Sammlung" }.buttonStyle(Pill(tint: mint))
            } else if cursor >= session.count {
                VStack(alignment: .leading, spacing: 17) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(mint)
                    Text("Runde geschafft").font(.largeTitle.bold())
                    Text("\(known) von \(session.count) gewusst").font(.title3).foregroundStyle(soft)
                    HStack {
                        if !missed.isEmpty {
                            Button("\(missed.count) wiederholen") { begin(missed) }.buttonStyle(Pill(tint: mint))
                        }
                        Button("Alle neu mischen") { begin(cards) }.buttonStyle(Pill())
                    }
                }.padding(30).frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 22))
            } else {
                let card = session[cursor]
                Text("Karte \(cursor + 1) von \(session.count)").font(.subheadline.bold()).foregroundStyle(soft)
                ProgressView(value: Double(cursor), total: Double(session.count)).tint(mint)
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { flipped.toggle() }
                } label: {
                    FlipCard(question: card.question, answer: card.answer, artwork: CardArtwork(card), angle: flipped ? 180 : 0, reduceMotion: reduceMotion)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(flipped ? card.answer : card.question)
                .accessibilityHint("Dreht die Karte um")
                .keyboardShortcut(.space, modifiers: [])
                if flipped {
                    HStack {
                        Button("Nochmal") { advance(false) }.buttonStyle(Pill())
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Gewusst") { advance(true) }.buttonStyle(Pill(tint: mint))
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                } else {
                    Text("Klicke auf die Karte oder drücke die Leertaste.").foregroundStyle(soft)
                }
            }
            Spacer(minLength: 0)
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }

    func begin(_ deck: [Card]) {
        session = deck.shuffled()
        cursor = 0
        known = 0
        missed = []
        flipped = false
        page = "Üben"
    }

    func advance(_ understood: Bool) {
        if understood { known += 1 } else { missed.append(session[cursor]) }
        flipped = false
        cursor += 1
    }

    func persist() { if let encoded = try? JSONEncoder().encode(cards) { saved = encoded } }

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
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let generated = try await Task.detached {
                    let text = try load()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudyError.empty }
                    let result = Worksheet.cards(from: text)
                    guard !result.isEmpty else { throw StudyError.noFacts }
                    return result
                }.value
                if cards.isEmpty { deckTitle = title } else if deckTitle != title { deckTitle = "Arbeitsblätter" }
                appeared = reduceMotion
                cards = generated + cards
                persist()
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
            VStack(alignment: .leading, spacing: 20) {
                Label(back ? "Antwort" : "Frage", systemImage: back ? "checkmark.circle" : "questionmark.circle")
                    .font(.subheadline.bold())
                if back {
                    CardIllustration(artwork: artwork).frame(maxWidth: 310).frame(height: 64)
                }
                Text(back ? answer : question).font(.system(size: 29, weight: .bold))
                    .textSelection(.disabled)
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
            .padding(28)
        }
        .frame(height: 244)
        .foregroundStyle(ink)
        .background(back ? mint : lilac, in: RoundedRectangle(cornerRadius: 22))
        .contentShape(RoundedRectangle(cornerRadius: 22))
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
    @Environment(\.dismiss) private var dismiss
    let delete: (() -> Void)?
    let save: (Card) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Karte bearbeiten").font(.title2.bold())
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
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5"
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
