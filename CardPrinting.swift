import SwiftUI
import PDFKit

@MainActor
enum CardPrinting {
    private static let paper = CGSize(width: 595, height: 842)

    static func printAll(_ cards: [Card]) -> Bool {
        guard let document = document(for: cards) else { return false }
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = paper
        printInfo.orientation = .portrait
        guard let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: false) else {
            return false
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
        return true
    }

    static func document(for cards: [Card]) -> PDFDocument? {
        guard !cards.isEmpty else { return nil }
        let document = PDFDocument()
        for start in stride(from: 0, to: cards.count, by: 4) {
            let group = Array(cards[start..<min(start + 4, cards.count)])
            let renderer = ImageRenderer(content: sheet(group, page: start / 4 + 1)
                .frame(width: paper.width, height: paper.height, alignment: .top)
                .environment(\.colorScheme, .light))
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data) else { return nil }
            var box = CGRect(origin: .zero, size: paper)
            guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            renderer.render { _, render in
                context.beginPDFPage(nil)
                render(context)
                context.endPDFPage()
            }
            context.closePDF()
            guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    private static func sheet(_ cards: [Card], page: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Blattkarten").font(.system(size: 19, weight: .bold))
                Spacer()
                Text("Seite \(page)").font(.system(size: 10, weight: .medium))
            }
            Text("Entlang der Außenkante ausschneiden und an der gestrichelten Linie falten.")
                .font(.system(size: 10))
            ForEach(cards) { card in
                HStack(spacing: 0) {
                    face("FRAGE", text: card.question)
                    Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                        .frame(width: 1)
                    face("ANTWORT", text: card.answer, artwork: CardArtwork(card))
                }
                .frame(height: 176)
                .border(.black.opacity(0.6), width: 0.7)
            }
        }
        .padding(28)
        .foregroundStyle(.black)
        .background(.white)
    }

    private static func face(_ title: String, text: String, artwork: CardArtwork? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced))
            if let artwork, artwork != .concept {
                CardIllustration(artwork: artwork).frame(height: 36)
            }
            Text(text)
                .font(.system(size: 14, weight: title == "FRAGE" ? .semibold : .regular))
                .minimumScaleFactor(0.45)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
