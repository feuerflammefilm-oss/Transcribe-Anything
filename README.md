# FuFF Transcribe

Mac-App zum Transkribieren von Audio und Video – ähnlich wie Turboscribe, aber komplett lokal auf deinem Mac.
Keine Uploads, kein Abo, keine Längenbegrenzung.

## Funktionen

- **Transkription** in fast 100 Sprachen mit Whisper Large v3 Turbo (über [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift))
- **Sprecher-Erkennung** (Pyannote über SpeakerKit) – Sprecher umbenennen, einzelne Absätze umzuordnen
- **Editor** mit Wiedergabe: auf Zeitstempel klicken springt zur Stelle, aktuelle Stelle wird markiert, Text direkt korrigierbar
- **Export:** TXT, Word (DOCX), PDF, CSV, Untertitel als SRT und VTT (Zeilenlänge einstellbar)
- **Übersetzung** in andere Sprachen mit Apples eingebauter Übersetzung – auch als Untertitel exportierbar
- **Zusammenfassung** mit Apple Intelligence
- **Warteschlange** für viele Dateien, Ordner per Drag & Drop
- Suche im Transkript

Voraussetzung: Mac mit Apple Silicon und macOS 26 (Tahoe). Beim ersten Transkribieren werden die
Sprachmodelle einmalig heruntergeladen (ca. 1,6 GB) und landen unter
`~/Library/Application Support/Transcribe Anything/`.

## Installieren

1. Unter **Releases → „latest“** `FuFF-Transcribe.zip` herunterladen.
2. Entpacken und **FuFF Transcribe.app** in **Programme** ziehen.
3. Erster Start: **Rechtsklick → Öffnen**, oder **Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“**.

## Bauen

Jeder Push auf `main` baut die App per GitHub Actions (`scripts/build_app.sh`) und veröffentlicht sie als Release „latest“.
