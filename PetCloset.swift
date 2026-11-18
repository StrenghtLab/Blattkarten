import SwiftUI

struct PetCloset: View {
    let pet: StreakPet
    @Binding var desktopVisible: Bool
    let choose: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                FlamePet(outfit: Outfit(pet.outfit)).frame(width: 126, height: 126)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deine Lernflamme").font(.largeTitle.bold())
                    Text("\(pet.streak()) Tage am Stück · Rekord \(pet.record)")
                        .font(.headline).foregroundStyle(mint)
                    Text("\(pet.unlocked) von 365 Outfits · \(pet.answers) geübte Karten")
                        .foregroundStyle(soft)
                }
                Spacer()
            }
            Text("Neue Kleidung gibt es für neue Streak-Rekorde, je fünf bewertete Karten und importierte Arbeitsblätter.")
                .font(.caption).foregroundStyle(soft)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 9)], spacing: 9) {
                    ForEach(0..<Outfit.count, id: \.self) { index in
                        let outfit = Outfit(index)
                        let unlocked = index < pet.unlocked
                        Button {
                            choose(index)
                        } label: {
                            VStack(spacing: 4) {
                                if unlocked {
                                    FlamePet(outfit: outfit).frame(height: 54)
                                } else {
                                    Image(systemName: "lock").frame(height: 54).foregroundStyle(soft)
                                }
                                Text(outfit.name).font(.caption2).lineLimit(2)
                                Text(index == pet.outfit ? "Angezogen" : (unlocked ? "Anziehen" : "Gesperrt"))
                                    .font(.caption2.bold()).foregroundStyle(unlocked ? mint : soft)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, minHeight: 106)
                            .background(panel, in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(index == pet.outfit ? mint : .clear) }
                        }
                        .buttonStyle(.plain)
                        .disabled(!unlocked)
                    }
                }
            }
            HStack {
                Toggle("Flamme auf dem Schreibtisch anzeigen", isOn: $desktopVisible)
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 650, height: 580)
        .background(ink)
    }
}
