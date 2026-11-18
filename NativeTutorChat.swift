import SwiftUI

struct TutorSessionRequest: Identifiable {
    let id = UUID()
    let scope: String
    let cards: [Card]
    let backend: TutorClient.Backend
    let firstQuestion: String
}

struct NativeTutorChat: View {
    let request: TutorSessionRequest
    let close: () -> Void
    @State private var draft = ""
    @State private var messages: [TutorMessage] = []
    @State private var pending = false
    @State private var notice: String?
    @State private var replyTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) { Label("Zur Sammlung", systemImage: "chevron.left") }
                Spacer()
                Text(request.scope).font(.headline).lineLimit(1)
                Spacer()
            }.padding(16)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == .user ? "Du" : "Lernchat")
                                    .font(.caption.bold()).foregroundStyle(mint)
                                Text(verbatim: message.content).textSelection(.enabled)
                            }
                            .padding(14)
                            .background(panel, in: RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                        }
                        if pending { ProgressView("Antwort wird erstellt …").controlSize(.small) }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .frame(maxWidth: 690)
                    .frame(maxWidth: .infinity)
                    .padding(22)
                }
                .onChange(of: messages.count) { reader.scrollTo("latest", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                if case .openAI = request.backend {
                    Text("Beim Senden gehen Frage und passende Kartentexte an OpenAI.")
                        .font(.caption).foregroundStyle(soft)
                }
                HStack {
                    TextField("Schreib deine Frage …", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    if pending {
                        Button("Stopp") { replyTask?.cancel() }.buttonStyle(Pill())
                    } else {
                        Button("Senden") { send(draft) }.buttonStyle(Pill(tint: mint))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(maxWidth: 690)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .foregroundStyle(.white)
        .background(ink)
        .preferredColorScheme(.dark)
        .onAppear {
            if messages.isEmpty && !pending { send(request.firstQuestion) }
        }
        .onDisappear { replyTask?.cancel() }
    }

    private func send(_ question: String) {
        let text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_500))
        guard !text.isEmpty, !pending else { return }
        let history = messages
        let previous = history.last { $0.role == .user }?.content ?? ""
        let reference = TutorClient.material(cards: request.cards, scope: request.scope, question: text + " " + previous)
        messages.append(TutorMessage(role: .user, content: text))
        draft = ""
        pending = true
        notice = nil
        replyTask = Task { @MainActor in
            defer { pending = false }
            do {
                let answer = try await TutorClient.reply(backend: request.backend, material: reference, history: history, question: text)
                try Task.checkCancellation()
                messages.append(TutorMessage(role: .assistant, content: answer))
            } catch {
                messages = history
                if draft.isEmpty { draft = text }
                if !Task.isCancelled { notice = error.localizedDescription }
            }
        }
    }
}
