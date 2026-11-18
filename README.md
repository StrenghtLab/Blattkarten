# Blattkarten

Blattkarten ist eine native macOS-App, die aus Arbeitsblättern Frage-Antwort-Karten zum Üben erstellt. Sie liest Bilder und PDFs ein und kann bei vorhandener Kamerafreigabe auch ein Arbeitsblatt fotografieren. Texterkennung und Kartenerstellung laufen auf dem Mac.

In der Sammlung siehst du Vorder- und Rückseite nebeneinander. Beim Üben wird die Karte umgedreht und zeigt die Antwort mit einer passenden Illustration. In der Seitenleiste lassen sich Fächer auswählen und eigene Fächer anlegen. Mit **+** neben dem Fach- oder Ordnernamen legst du Ordner und Unterordner an. Karten aus einem Import werden im gerade geöffneten Fach oder Ordner gespeichert. Über **Drucken** lassen sich das aktuelle Fach oder alle Fächer als faltbare A4-Karten ausgeben.

## Installation

Lade das DMG unter [Releases](https://github.com/StrenghtLab/Blattkarten/releases) herunter, öffne es und ziehe Blattkarten in **Programme**. Die App benötigt macOS 14 oder neuer und unterstützt Intel und Apple Silicon. Die veröffentlichte App ist lokal signiert und nicht von Apple notarisiert.

Im App-Menü unter **Blattkarten → Nach Updates suchen …** kannst du prüfen, ob ein neues DMG bereitsteht.

## Bauen

Mit den Xcode Command Line Tools erstellt `./build.sh` die App und `./make-dmg.sh` das DMG. Der Release-Workflow veröffentlicht das DMG für die Version aus der Info.plist.

## KI-Lernchat

Öffne ein Fach oder einen Ordner und klicke unten rechts auf **KI-Lernchat**. Der Chat verwendet passende Karteikarten aus dem geöffneten Bereich einschließlich seiner Unterordner. Unter **KI einrichten** kannst du ein auf deinem Mac laufendes Ollama-Modell wählen oder einen OpenAI-API-Schlüssel eingeben. Der Schlüssel bleibt bis zum Beenden der App im Arbeitsspeicher. Bei OpenAI werden die Frage und passende Kartentexte erst beim Senden an OpenAI übertragen.

## Suche, Wiederholung und KI-Import

Suche im geöffneten Fach oder Ordner nach Fragen, Antworten oder Dateinamen. Unter **Üben** kannst du fällige Karten, die Suchtreffer oder alle Karten auswählen. Gewusste Karten werden mit wachsenden Abständen wieder fällig. Schwierige Karten kommen früher zurück. Beim erneuten Import werden identische Karten am selben Ablageort übersprungen.

**Datei mit KI** lässt ein eingerichtetes Modell den erkannten Text für die Kartenerstellung auswerten. Bei OpenAI sendet die App den erkannten Text nur nach einer Bestätigung. **Datei öffnen** verwendet die lokale Kartenerstellung.

### Antworten direkt in Blattkarten

Wähle unter **KI einrichten** die **OpenAI API** oder ein lokales **Ollama**-Modell. Gib deine Frage im Blattkarten-Lernchat ein und klicke auf **Senden**. Frage, Antwort und Rückfragen bleiben in der nativen Chat-Ansicht von Blattkarten. Für das OpenAI-Modell brauchst du einen API-Schlüssel.
