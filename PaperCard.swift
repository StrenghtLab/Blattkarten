import SwiftUI

struct PaperCardPair: View {
    let card: Card
    let source: String?
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let source {
                    Label(source, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(soft)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: edit) {
                    Label("Bearbeiten", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(soft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Karte bearbeiten: \(card.question)")
            }
            HStack(alignment: .top, spacing: 10) {
                PaperCardFace(text: card.question, artwork: nil)
                PaperCardFace(text: card.answer, artwork: CardArtwork(card), explanation: card.learningNote)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PaperCardFace: View {
    let text: String
    let artwork: CardArtwork?
    var explanation: String? = nil
    var large = false

    private var back: Bool { artwork != nil }
    private var accent: Color {
        back ? Color(red: 0.10, green: 0.39, blue: 0.28) : Color(red: 0.34, green: 0.24, blue: 0.60)
    }

    static func paperColor(back: Bool) -> Color {
        back ? Color(red: 0.92, green: 0.98, blue: 0.94) : Color(red: 0.98, green: 0.96, blue: 0.91)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 14 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(back ? "Rückseite" : "Vorderseite").fontWeight(.bold)
                Spacer()
                Text(back ? "Antwort" : "Frage")
            }
            .font(.system(size: large ? 12 : 10, weight: .medium, design: .monospaced))
            .foregroundStyle(accent)

            Rectangle().fill(accent.opacity(0.30)).frame(height: 1)

            Text(text)
                .font(.system(size: large ? (back ? 23 : 28) : (back && text.count > 110 ? 14 : 16),
                              weight: back && text.count > 110 ? .regular : .semibold))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)

            if let artwork, artwork != .concept {
                CardIllustration(artwork: artwork)
                    .frame(maxWidth: 330)
                    .frame(height: large ? 70 : 52)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(accent)
                    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
            }

            if back, let explanation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Einfach erklärt")
                        .font(.system(size: large ? 12 : 10, weight: .bold))
                        .foregroundStyle(accent)
                    Text(explanation)
                        .font(.system(size: large ? 15 : 13))
                        .foregroundStyle(ink.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            if !back {
                Spacer(minLength: 9)
                Canvas { context, size in
                    for fraction in [0.18, 0.52, 0.86] {
                        let y = size.height * fraction
                        var line = Path()
                        line.addLines([CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)])
                        context.stroke(line, with: .color(accent.opacity(0.14)), lineWidth: 1)
                    }
                }
                .frame(height: large ? 55 : 31)
                .accessibilityHidden(true)
            }
        }
        .padding(large ? 24 : 14)
        .frame(maxWidth: .infinity, minHeight: large ? 304 : 198, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.paperColor(back: back), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.24)) }
        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
        .accessibilityElement(children: .combine)
    }
}
