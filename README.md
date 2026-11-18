# Blattkarten

Blattkarten ist eine native macOS-App, die aus Arbeitsblättern Frage-Antwort-Karten zum Üben erstellt. Sie liest Bilder und PDFs ein und kann bei vorhandener Kamerafreigabe auch ein Arbeitsblatt fotografieren. Texterkennung und Kartenerstellung laufen auf dem Mac.

Die Karten enthalten passende Illustrationen. Über **Alle drucken** lassen sich alle Fragen und Antworten nebeneinander als faltbare A4-Karten ausgeben.

## Installation

Lade das DMG unter [Releases](https://github.com/StrenghtLab/Blattkarten/releases) herunter, öffne es und ziehe Blattkarten in **Programme**. Die App benötigt macOS 14 oder neuer und unterstützt Intel und Apple Silicon. Die veröffentlichte App ist lokal signiert und nicht von Apple notarisiert.

Im App-Menü unter **Blattkarten → Nach Updates suchen …** kannst du prüfen, ob ein neues DMG bereitsteht.

## Bauen

Mit den Xcode Command Line Tools erstellt `./build.sh` die App und `./make-dmg.sh` das DMG. Der Release-Workflow veröffentlicht das DMG für die Version aus der Info.plist.
