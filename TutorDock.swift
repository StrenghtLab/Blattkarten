import SwiftUI
import AppKit

@MainActor
final class TutorSettings: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case local = "Lokal mit Ollama"
        case openAI = "OpenAI API"
        case chatGPT = "ChatGPT-App oder Browser"
        var id: Self { self }
    }

    @Published var provider: Provider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "tutor.provider.v1") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "tutor.provider.v1") ?? ""
        provider = Provider(rawValue: saved) ?? .local
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
    @ObservedObject var settings: TutorSettings
    @State private var showingSettings = false
    @State private var models: [String] = []
    @State private var modelStatus = ""
    @State private var checkingModels = false
    @State private var question = ""
    @State private var conversation: [TutorMessage] = []
    @State private var inFlight: Task<Void, Never>?
    @State private var error: String?
    @State private var copied = false
    @State private var showingHandoff = false
    @State private var handoffDraft = ""
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
        case .chatGPT:
            nil
        case .openAI:
            settings.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil :
                .openAI(settings.key.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var handoff: Bool { settings.provider == .chatGPT }

    private var canAsk: Bool {
        !cards.isEmpty && (handoff || backend != nil)
    }

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
        .sheet(isPresented: $showingHandoff) {
            TutorHandoffPreview(scope: scope, draft: $handoffDraft, open: openInChatGPT)
        }
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
        .onDisappear { inFlight?.cancel() }
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
            } else if handoff {
                Text("ChatGPT öffnet sich mit deiner Frage in der Zwischenablage. Füge sie in einem Chat mit ⌘V ein und sende sie ab.")
                    .foregroundStyle(soft)
                    .fixedSize(horizontal: false, vertical: true)
                if copied {
                    Label("Frage und passende Karten kopiert.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(mint)
                }
            } else if backend == nil {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Richte ein KI-Modell ein, um Fragen zu deinen Karten zu stellen.")
                        .foregroundStyle(soft)
                    Button("KI einrichten") { showingSettings = true }
                        .buttonStyle(Pill())
                }
            } else if conversation.isEmpty {
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
            } else {
                transcript
            }

            if handoff || !scopeExplanations.isEmpty {
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
            if inFlight != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Die KI formuliert eine Erklärung …").font(.caption).foregroundStyle(soft)
                    Spacer()
                    Button("Stopp") { inFlight?.cancel() }.buttonStyle(.plain)
                }
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
                Button(action: handoff ? previewHandoff : ask) {
                    if handoff {
                        Label("Vorschau", systemImage: "arrow.up.right")
                    } else {
                        Image(systemName: "arrow.up").accessibilityLabel("Frage senden")
                    }
                }
                .buttonStyle(Pill(tint: mint))
                .disabled(!canAsk || inFlight != nil ||
                          question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(lilac.opacity(0.25)) }
        .shadow(color: .black.opacity(0.48), radius: 18, y: 7)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conversation) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "Du" : "Lernchat")
                                .font(.caption.bold()).foregroundStyle(mint)
                            Text(verbatim: message.content).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
            }
            .frame(height: 238)
            .onChange(of: conversation.count, initial: true) { reader.scrollTo("latest", anchor: .bottom) }
        }
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
            } else if handoff {
                Text("Verwende dein normales ChatGPT-Konto. Blattkarten kopiert passende Kartentexte und deine Frage. Antworten erscheinen in ChatGPT.")
                    .fixedSize(horizontal: false, vertical: true)
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
            inFlight?.cancel()
            conversation = []
            copied = false
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
            Text("Kopiere die Erklärung in ChatGPT und füge sie hier mit ⌘V ein.")
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

    private func previewHandoff() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard handoff, !text.isEmpty, !cards.isEmpty else { return }
        handoffDraft = TutorClient.chatGPTPrompt(cards: cards, scope: scope, question: text)
        showingHandoff = true
        copied = false
    }

    private func openInChatGPT(_ draft: String) {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(prompt, forType: .string) else {
            error = "Die Frage konnte nicht in die Zwischenablage kopiert werden."
            return
        }
        error = nil
        copied = true
        showingHandoff = false
        let web = URL(string: "https://chatgpt.com/")!
        let workspace = NSWorkspace.shared
        let chatGPTApp = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.openai.chat")
        if let app = chatGPTApp {
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(web) } }
            }
        } else {
            workspace.open(web)
        }
    }

    private func ask() {
        let text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_500))
        guard let backend, !cards.isEmpty, !text.isEmpty, inFlight == nil else { return }
        let history = conversation
        let earlierQuestion = history.last { $0.role == .user }?.content ?? ""
        let material = TutorClient.material(cards: cards, scope: scope, question: text + " " + earlierQuestion)
        conversation.append(TutorMessage(role: .user, content: text))
        question = ""
        error = nil
        inFlight = Task { @MainActor in
            defer { inFlight = nil }
            do {
                let answer = try await TutorClient.reply(backend: backend, material: material, history: history, question: text)
                try Task.checkCancellation()
                conversation.append(TutorMessage(role: .assistant, content: answer))
            } catch {
                if conversation.last?.role == .user { conversation.removeLast() }
                if question.isEmpty { question = text }
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}


private struct TutorHandoffPreview: View {
    let scope: String
    @Binding var draft: String
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anfrage für ChatGPT").font(.title2.bold())
            Label(scope, systemImage: "folder").foregroundStyle(soft)
            Text("Prüfe den Text und entferne bei Bedarf einzelne Karten. Du sendest die Anfrage anschließend in ChatGPT.")
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 250)
                .border(.secondary.opacity(0.3))
                .accessibilityLabel("Anfrage und Kartentexte")
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Kopieren und ChatGPT öffnen") { open(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: 430)
    }
}
