# Blattkarten fürs iPhone

Die native iPhone-Version verwendet dieselbe lokale Texterkennung, Kartenerstellung und Wiederholungslogik wie die Mac-App. Sie liest Fotos, PDFs und eingefügten Text. Die Kamera kann unterstützte Geräte zum Dokumentenscan verwenden. Die Karten und Lernstände werden auf dem iPhone gespeichert.

## IPA bauen

Voraussetzung ist vollständiges Xcode mit dem iPhone-SDK. Die App hat als Mindestziel iOS 16.

Führe im entpackten Projektordner den folgenden Befehl aus.

```sh
./iPhone/build-ipa.sh
```

Das Skript schreibt `Blattkarten-iPhone.ipa` in den Ordner `iPhone`. AltStore Classic signiert die App beim Import. Öffne dazu die IPA in AltStore Classic, während AltServer erreichbar ist.

- [AltStore Classic und AltServer](https://faq.altstore.io/altstore-classic/altserver)
- [Xcode von Apple](https://developer.apple.com/xcode/)

Die iPhone-Oberfläche, der Gerätebuild und die Installation konnten auf dem Entwicklungs-Mac ohne iPhone-SDK noch nicht getestet werden.
