import Foundation

extension Card {
    var learningNote: String? {
        if let explanation, !explanation.isEmpty { return explanation }
        let front = question.lowercased()
        let back = answer.lowercased()

        if front.contains("ohmschen gesetz") {
            if back.hasPrefix("i =") { return "Bei 6 V und 3 Ω teilst du 6 durch 3. Es fließen 2 A." }
            if back.hasPrefix("r =") { return "Bei 6 V und 2 A teilst du 6 durch 2. Der Widerstand beträgt 3 Ω." }
            if back.hasPrefix("u =") { return "Bei 3 Ω und 2 A rechnest du 3 mal 2. Die Spannung beträgt 6 V." }
        }
        if front.contains("voltmeter"), back.contains("parallel") {
            return "Setze je eine Messspitze an beide Enden des Bauteils. So misst du den Unterschied zwischen diesen beiden Punkten."
        }
        if front.contains("amperemeter"), back.contains("in reihe") {
            return "Der Strom soll durch das Messgerät fließen. Deshalb sitzt das Messgerät direkt im Stromweg."
        }
        if front.contains("widerstand steigt"), back.contains("sinkt") {
            return "Bei derselben Spannung fließt durch 6 Ω nur halb so viel Strom wie durch 3 Ω."
        }
        if front.contains("welcher einheit") || front.contains("welche einheit") {
            if front.contains("stromstärke"), back.contains("ampere") { return "A ist die Abkürzung für Ampere. 1 A sind 1.000 mA." }
            if front.contains("spannung"), back.contains("volt") { return "V ist die Abkürzung für Volt. Eine Batterie kann zum Beispiel 1,5 V haben." }
            if front.contains("widerstand"), back.contains("ohm") { return "Ω steht für Ohm. 1 kΩ sind 1.000 Ω." }
        }
        if front.contains("was beschreibt"), front.contains("stromstärke"), back.contains("ladung") {
            return "Stell dir einen Punkt im Draht vor. Je mehr Ladung pro Sekunde an ihm vorbeifließt, desto größer ist die Stromstärke."
        }
        if front.contains("was beschreibt"), front.contains("spannung"), back.contains("ladung") {
            return "An zwei Punkten kann eine Ladung unterschiedlich viel Energie haben. Die Spannung gibt diesen Unterschied pro Ladung an."
        }
        if front.contains("was beschreibt"), front.contains("widerstand"), back.contains("stromfluss") {
            return "Ein großer Widerstand bremst den Strom stärker. Bei derselben Spannung fließt dann weniger Strom."
        }
        if front.contains("milliampere"), back.contains("teilen") { return "Beispiel: 500 mA ÷ 1.000 = 0,5 A." }
        if front.contains("kiloohm"), back.contains("multiplizieren") { return "Beispiel: 2 kΩ × 1.000 = 2.000 Ω." }
        return nil
    }
}
