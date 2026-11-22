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
            if let excerpt = card.sourceExcerpt {
                DisclosureGroup("Belegstelle") {
                    Text(excerpt)
                        .textSelection(.enabled)
                        .padding(.vertical, 5)
                }
                .font(.caption)
                .foregroundStyle(soft)
            }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 21))
        .overlay { RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.10)) }
    }
}

struct PaperCardFace: View {
    let text: String
    let artwork: CardArtwork?
    var explanation: String? = nil
    var large = false

    private var back: Bool { artwork != nil }
    private var accent: Color {
        back ? Color(red: 0.06, green: 0.35, blue: 0.31) : Color(red: 0.31, green: 0.19, blue: 0.58)
    }

    static func paperColor(back: Bool) -> Color {
        back ? Color(red: 0.90, green: 0.97, blue: 0.95) : Color(red: 0.94, green: 0.91, blue: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 16 : 11) {
            Label(back ? "Antwort" : "Frage", systemImage: back ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .font(.system(size: large ? 14 : 11, weight: .bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(accent)
                .background(accent.opacity(0.09), in: Capsule())

            Text(text)
                .font(.system(size: large ? (back ? 24 : 30) : (back && text.count > 110 ? 15 : 19),
                              weight: back && text.count > 110 ? .regular : .semibold,
                              design: back ? .default : .rounded))
                .foregroundStyle(ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let artwork, artwork != .concept {
                VStack(alignment: .leading, spacing: 5) {
                    if let caption = artwork.caption {
                        Text(caption).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                    }
                    CardIllustration(artwork: artwork)
                        .frame(maxWidth: 350)
                        .frame(height: large ? 92 : 63)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .padding(10)
                .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 11))
            }

            if back, let explanation {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Einfach erklärt", systemImage: "lightbulb")
                        .font(.system(size: large ? 13 : 11, weight: .bold))
                        .foregroundStyle(accent)
                    Text(explanation)
                        .font(.system(size: large ? 15 : 13))
                        .foregroundStyle(ink.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(large ? 25 : 16)
        .frame(maxWidth: .infinity, minHeight: large ? 304 : 198, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 17)
                .fill(LinearGradient(colors: [.white, Self.paperColor(back: back)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .leading) {
                    Rectangle().fill(accent.opacity(0.55)).frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(accent.opacity(0.18)) }
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        .accessibilityElement(children: .combine)
    }
}

struct CompactLearningCard: View {
    let card: Card
    var body: some View {
        let artwork = CardArtwork(card)
        let accent: Color = switch artwork {
        case .neuron, .synapse: Color(red: 0.38, green: 0.24, blue: 0.62)
        case .brain: Color(red: 0.59, green: 0.26, blue: 0.47)
        case .impulse: Color(red: 0.58, green: 0.29, blue: 0.14)
        default: Color(red: 0.12, green: 0.38, blue: 0.30)
        }
        VStack(alignment: .leading, spacing: 7) {
            Text(card.question).font(.system(size: 14, weight: .bold)).lineLimit(2)
            HStack(alignment: .top, spacing: 6) {
                Text(card.answer).font(.system(size: 12)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if artwork != .concept {
                    CardIllustration(artwork: artwork)
                        .frame(width: 59, height: 39)
                        .foregroundStyle(accent)
                        .padding(3)
                        .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .foregroundStyle(ink)
        .background(Color(red: 0.98, green: 0.96, blue: 0.99), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.45)) }
    }
}

enum NeurobiologyExamples {
    static var cards: [Card] {
        [
            Card(question: "Was ist ein Neuron?", answer: "Ein Neuron ist eine Nervenzelle. Sie empfängt und leitet Signale weiter."),
            Card(question: "Was passiert an einer chemischen Synapse?", answer: "Ein Botenstoff überträgt das Signal auf die nächste Zelle."),
            Card(question: "Was ist ein Aktionspotenzial?", answer: "Eine kurze Änderung der elektrischen Spannung an der Zellmembran."),
            Card(question: "Wozu dient die Myelinscheide?", answer: "Sie isoliert das Axon und beschleunigt die Weiterleitung von Signalen."),
            Card(question: "Was gehört zum zentralen Nervensystem (ZNS)?", answer: "Gehirn und Rückenmark."),
            Card(question: "Was gehört zum peripheren Nervensystem (PNS)?", answer: "Die Nerven und Nervenknoten außerhalb von Gehirn und Rückenmark.")
        ]
    }
}
