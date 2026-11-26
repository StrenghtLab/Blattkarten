import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VisionKit
import ImageIO

private let mint = Color(red: 0.73, green: 0.98, blue: 0.86)
private let violet = Color(red: 0.79, green: 0.73, blue: 1)
private let studioBackground = Color(red: 0.075, green: 0.065, blue: 0.13)

@main struct BlattkartenApp: App {
    var body: some Scene {
        WindowGroup { LibraryView().preferredColorScheme(.dark) }
    }
}

private struct LibraryView: View {
    @AppStorage("iphone.cards.v1") private var stored = Data()
    @State private var cards: [Card] = []
    @State private var subject: String?
    @State private var importing = false
    @State private var session: StudySession?

    private var subjects: [String] { Set(cards.map(\.subjectName)).sorted() }
    private var visible: [Card] { cards.filter { subject == nil || $0.subjectName == subject } }
    private var due: [Card] { visible.filter { $0.isDue(at: .now) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dein Lernstudio").font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("\(visible.count) Karten · \(due.count) fällig").font(.subheadline)
                        }
                        Spacer()
                        Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 38))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .foregroundStyle(.black)
                    .background(LinearGradient(colors: [violet, mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 24))

                    Button { importing = true } label: {
                        Label("Lernmaterial einlesen", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)

                    if !cards.isEmpty {
                        Picker("Fach", selection: $subject) {
                            Text("Alle Fächer").tag(nil as String?)
                            ForEach(subjects, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        Button { session = StudySession(cards: due.isEmpty ? visible : due) } label: {
                            Label(due.isEmpty ? "Karten üben" : "Fällige Karten üben", systemImage: "bolt.fill")
                        }.buttonStyle(.bordered).disabled(visible.isEmpty)

                        ForEach(visible) { card in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(card.subjectName).font(.caption.weight(.semibold)).foregroundStyle(violet)
                                Text(card.question).font(.headline)
                                Text(card.answer).foregroundStyle(.secondary)
                                if let source = card.sourceExcerpt {
                                    DisclosureGroup("Belegstelle") { Text(source).font(.footnote) }
                                        .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(15)
                            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15))
                        }
                    } else {
                        Text("Importiere ein Foto, ein PDF oder Text für deine ersten Karten.")
                            .foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            .background(studioBackground.ignoresSafeArea())
            .navigationTitle("Blattkarten")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { cards = (try? JSONDecoder().decode([Card].self, from: stored)) ?? [] }
        .sheet(isPresented: $importing) {
            ImportView { drafts in
                var known = Set(cards.map { $0.subjectName + "\n" + $0.question })
                cards.insert(contentsOf: drafts.filter { known.insert($0.subjectName + "\n" + $0.question).inserted }, at: 0)
                subject = nil
                persist()
            }
        }
        .sheet(item: $session) { session in
            StudyView(cards: session.cards) { snapshot, known in
                guard let index = cards.firstIndex(where: { $0.id == snapshot.id }) else { return }
                cards[index].review = .after(cards[index].review, understood: known)
                persist()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cards) { stored = data }
    }
}

private struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    let save: ([Card]) -> Void
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var files = false
    @State private var scanner = false
    @State private var busy = false
    @State private var error: String?
    @State private var preview: [Card] = []
    @State private var subject = "Allgemein"
    private let subjects = ["Allgemein", "Mathematik", "Deutsch", "Englisch", "Physik", "Chemie", "Biologie", "Geschichte", "Erdkunde"]

    var body: some View {
        NavigationStack {
            Form {
                if preview.isEmpty {
                    Section("Lernmaterial") {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Foto auswählen", systemImage: "photo")
                        }
                        Button { files = true } label: { Label("Datei öffnen", systemImage: "folder") }
                        if VNDocumentCameraViewController.isSupported {
                            Button { scanner = true } label: { Label("Blatt scannen", systemImage: "camera") }
                        }
                        TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("Lerntext")
                        Text("\(text.count.formatted()) Zeichen").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Karten erstellen") {
                        let input = text
                        let available = subjects
                        run {
                            let result = await Task.detached {
                                (Worksheet.cards(from: input), Worksheet.suggestedSubject(for: input, title: "", available: available))
                            }.value
                            guard !result.0.isEmpty else { throw StudyError.noFacts }
                            preview = result.0
                            subject = result.1 ?? "Allgemein"
                        }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Picker("Fach", selection: $subject) {
                        ForEach(subjects, id: \.self) { Text($0).tag($0) }
                    }
                    Section("Vorschau · \(preview.count) Karten") {
                        ForEach(preview) { card in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.question).font(.headline)
                                Text(card.answer)
                                if let source = card.sourceExcerpt {
                                    DisclosureGroup("Belegstelle") { Text(source).font(.footnote) }
                                }
                            }
                        }.onDelete { preview.remove(atOffsets: $0) }
                    }
                    Button("\(preview.count) Karten speichern") {
                        save(preview.map { card in var copy = card; copy.subject = subject; return copy })
                        dismiss()
                    }
                    Button("Zurück zum Lerntext") { preview = [] }
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView("Wird verarbeitet …").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .navigationTitle("Lernmaterial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.pdf, .image, .plainText]) { result in
            run {
                let url = try result.get()
                text = try await Task.detached {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if url.pathExtension.lowercased() == "txt" { return try String(contentsOf: url, encoding: .utf8) }
                    return try Worksheet.read(url)
                }.value
            }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            run {
                defer { photo = nil }
                guard let bytes = try await item.loadTransferable(type: Data.self) else { throw StudyError.unreadable }
                text = try await Task.detached {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 3200
                          ] as CFDictionary) else { throw StudyError.unreadable }
                    return try Worksheet.recognize(image)
                }.value
            }
        }
        .sheet(isPresented: $scanner) {
            DocumentScanner { result in
                scanner = false
                guard let result else { return }
                run {
                    let pages = try result.get()
                    text = try await Task.detached { try pages.map(Worksheet.recognize).joined(separator: "\u{000C}") }.value
                }
            }.ignoresSafeArea()
        }
        .alert("Lernmaterial konnte nicht verarbeitet werden", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct StudySession: Identifiable {
    let id = UUID()
    let cards: [Card]
}

private struct StudyView: View {
    @Environment(\.dismiss) private var dismiss
    let cards: [Card]
    let rate: (Card, Bool) -> Void
    @State private var index = 0
    @State private var revealed = false
    @State private var typing: Bool?
    @State private var answer = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let typing, cards.indices.contains(index) {
                        studyCard(cards[index], typing: typing)
                    } else if index == cards.count {
                        Label("Runde abgeschlossen", systemImage: "checkmark.circle.fill").font(.title2.bold())
                        Button("Fertig") { dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Wie möchtest du üben?").font(.title2.bold())
                        Button("Karten umdrehen") { typing = false }.buttonStyle(.borderedProminent)
                        Button("Antwort eintippen") { typing = true }.buttonStyle(.bordered)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(studioBackground.ignoresSafeArea())
            .navigationTitle("Üben").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func studyCard(_ card: Card, typing: Bool) -> some View {
        ProgressView(value: Double(index), total: Double(cards.count))
        Text("Karte \(index + 1) von \(cards.count)").font(.caption)
        Text(card.question).font(.title2.bold()).padding(.vertical, 12)
        if !revealed {
            if typing {
                TextField("Deine Antwort", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
            }
            Button("Musterantwort anzeigen") { revealed = true }
                .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
        } else {
            if typing && !answer.isEmpty {
                Text("Deine Antwort: \(answer)").foregroundStyle(.secondary)
            }
            Text(card.answer).font(.title3).foregroundStyle(mint)
            HStack {
                Button("Nochmal") { advance(card, false) }.buttonStyle(.bordered)
                Button("Gewusst") { advance(card, true) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func advance(_ card: Card, _ known: Bool) {
        rate(card, known)
        answer = ""
        revealed = false
        index += 1
    }
}

private struct DocumentScanner: UIViewControllerRepresentable {
    let finished: (Result<[CGImage], Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let finished: (Result<[CGImage], Error>?) -> Void
        init(_ finished: @escaping (Result<[CGImage], Error>?) -> Void) { self.finished = finished }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage }
            if images.isEmpty { finished(.failure(StudyError.unreadable)) }
            else { finished(.success(images)) }
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { finished(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            finished(.failure(error))
        }
    }
}
