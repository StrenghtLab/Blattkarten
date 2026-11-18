import SwiftUI
import AppKit

@MainActor
final class TutorSettings: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case local = "Lokal mit Ollama"
        case openAI = "OpenAI API"
        var id: Self { self }
    }

    @Published var provider: Provider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "tutor.provider.v1") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "tutor.provider.v1") ?? ""
        provider = Provider(rawValue: saved) ?? (saved.isEmpty ? .local : .openAI)
    }
    @Published var model = ""
    @Published var key = ""
}

private struct TutorExplanation: Codable, Identifiable {
    var id = UUID()
    let scope: String
    let question: String
    let answer: String
    let savedAt: Date
}

struct TutorDock: View {
    let scope: String
    let scopeID: String
    let cards: [Card]
    @Binding var expanded: Bool
    @Binding var setupRequested: Bool
    let openNativeChat: (TutorSessionRequest) -> Void
    @ObservedObject var settings: TutorSettings
    @State private var showingSettings = false
    @State private var models: [String] = []
    @State private var modelStatus = ""
    @State private var checkingModels = false
    @State private var question = ""
    @State private var error: String?
    @State private var showingExplanations = false
    @State private var explanationDraft = ""
    @AppStorage("tutor.explanations.v1") private var savedExplanations = Data()

    private var explanations: [TutorExplanation] {
        (try? JSONDecoder().decode([TutorExplanation].self, from: savedExplanations)) ?? []
    }

    private var scopeExplanations: [TutorExplanation] {
        explanations.filter { $0.scope == scopeID }.sorted { $0.savedAt > $1.savedAt }
    }
    @FocusState private var focused: Bool

    private var backend: TutorClient.Backend? {
        switch settings.provider {
        case .local:
            models.contains(settings.model) ? .local(settings.model) : nil
        case .openAI:
            settings.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil :
                .openAI(settings.key.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var canAsk: Bool { !cards.isEmpty && backend != nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if expanded { chat }
            Button {
                expanded.toggle()
                if expanded && models.isEmpty && settings.provider == .local {
                    Task { await loadModels() }
                }
            } label: {
                Label(expanded ? "Lernchat schließen" : "KI-Lernchat", systemImage: expanded ? "xmark" : "sparkles")
            }
            .buttonStyle(Pill(tint: mint))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .sheet(isPresented: $showingSettings) { configuration }
        .sheet(isPresented: $showingExplanations) { explanationLibrary }
        .onChange(of: setupRequested) {
            if setupRequested {
                showingSettings = true
                setupRequested = false
            }
        }
        .task(id: scope) {
            if expanded && settings.provider == .local { await loadModels() }
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("KI-Lernchat", systemImage: "sparkles").font(.headline).foregroundStyle(mint)
                Spacer()
                Button {
                    showingSettings = true
                    if settings.provider == .local { Task { await loadModels() } }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lernchat-Einstellungen")
            }
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(scope).lineLimit(1).help(scope)
                Spacer()
                Text("\(cards.count) \(cards.count == 1 ? "Karte" : "Karten")")
            }
            .font(.caption)
            .foregroundStyle(soft)
            Divider()

            if cards.isEmpty {
                Text("Füge hier zuerst Karteikarten hinzu oder öffne einen Ordner mit Lernstoff.")
                    .foregroundStyle(soft)
                    .padding(.vertical, 12)
            } else if backend == nil {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Richte ein KI-Modell ein, um Fragen zu deinen Karten zu stellen.")
                        .foregroundStyle(soft)
                    Button("KI einrichten") { showingSettings = true }
                        .buttonStyle(Pill())
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Was verstehst du noch nicht?").foregroundStyle(soft)
                    HStack(spacing: 8) {
                        Button("Einfaches Beispiel") {
                            question = "Erkläre mir einen wichtigen Begriff aus diesem Ordner mit einem einfachen Beispiel."
                            focused = true
                        }
                        Button("Mini-Quiz") {
                            question = "Stell mir eine kurze Frage zum wichtigsten Stoff in diesem Ordner. Warte auf meine Antwort."
                            focused = true
                        }
                    }
                    .buttonStyle(Pill())
                }
                .padding(.vertical, 6)
            }

            if !scopeExplanations.isEmpty {
                Button {
                    explanationDraft = ""
                    showingExplanations = true
                } label: {
                    Label(scopeExplanations.isEmpty ? "Antwort ablegen" : "Erklärungen (\(scopeExplanations.count))",
                          systemImage: "bookmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(mint)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.provider == .openAI && backend != nil && !cards.isEmpty {
                Text("Beim Senden gehen deine Frage und passende Kartentexte an OpenAI.")
                    .font(.caption2).foregroundStyle(soft)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Was verstehst du nicht?", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .focused($focused)
                    .disabled(!canAsk)
                Button(action: ask) {
                    Label("Senden", systemImage: "arrow.up")
                }
                .buttonStyle(Pill(tint: mint))
                .disabled(!canAsk ||
                          question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(lilac.opacity(0.25)) }
        .shadow(color: .black.opacity(0.48), radius: 18, y: 7)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("KI einrichten").font(.title2.bold())
            Picker("Anbieter", selection: $settings.provider) {
                ForEach(TutorSettings.Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            if settings.provider == .local {
                Text("Starte Ollama auf diesem Mac und lade dort ein lokales Chat-Modell.")
                    .fixedSize(horizontal: false, vertical: true)
                if !models.isEmpty {
                    Picker("Modell", selection: $settings.model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                if !modelStatus.isEmpty { Text(modelStatus).font(.caption).foregroundStyle(soft) }
                HStack {
                    Button(checkingModels ? "Suche läuft …" : "Modelle suchen") { Task { await loadModels() } }
                        .disabled(checkingModels)
                    Link("Ollama öffnen", destination: URL(string: "https://ollama.com/download/mac")!)
                }
            } else {
                Text("OpenAI verarbeitet die Frage und die ausgewählten Kartentexte. Für Anfragen können API-Kosten anfallen.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("OpenAI API-Schlüssel", text: $settings.key)
                    .textFieldStyle(.roundedBorder)
                Text("Der Schlüssel bleibt bis zum Beenden der App im Arbeitsspeicher.")
                    .font(.caption).foregroundStyle(soft)
            }
            HStack {
                Spacer()
                Button("Fertig") { showingSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .onChange(of: settings.provider) {
                error = nil
            if settings.provider == .local { Task { await loadModels() } }
        }
    }

    private func loadModels() async {
        guard !checkingModels else { return }
        checkingModels = true
        defer { checkingModels = false }
        do {
            let available = try await TutorClient.localModels()
            guard !Task.isCancelled else { return }
            models = available
            if !models.contains(settings.model) { settings.model = models.first ?? "" }
            modelStatus = available.isEmpty ? "Ollama läuft. Es ist noch kein lokales Modell installiert." : ""
        } catch {
            guard !Task.isCancelled else { return }
            models = []
            modelStatus = error.localizedDescription
        }
    }

    private var explanationLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Erklärungen").font(.title2.bold())
            Label(scope, systemImage: "folder").foregroundStyle(soft)
            if !scopeExplanations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(scopeExplanations) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.question).font(.headline)
                                Text(verbatim: entry.answer).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 195)
            }
            Text("Füge bei Bedarf eine weitere Erklärung mit ⌘V ein.")
                .foregroundStyle(soft)
            TextEditor(text: $explanationDraft)
                .frame(minHeight: 105)
                .border(.secondary.opacity(0.3))
                .accessibilityLabel("Erklärung aus ChatGPT")
            HStack {
                Spacer()
                Button("Schließen", role: .cancel) { showingExplanations = false }
                Button("Im Ordner speichern") { saveExplanation() }
                    .disabled(explanationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func saveExplanation() {
        let answer = explanationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        let heading = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = TutorExplanation(scope: scopeID, question: heading.isEmpty ? "Gespeicherte Erklärung" : heading,
                                     answer: answer, savedAt: .now)
        guard let data = try? JSONEncoder().encode(explanations + [entry]) else { return }
        savedExplanations = data
        explanationDraft = ""
    }

    private func ask() {
        let text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_500))
        guard let backend, !cards.isEmpty, !text.isEmpty else { return }
        openNativeChat(TutorSessionRequest(scope: scope, cards: cards, backend: backend, firstQuestion: text))
    }
}
