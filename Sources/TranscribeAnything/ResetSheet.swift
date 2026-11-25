import SwiftUI

/// Fenster zum Zurücksetzen eines Transkripts: neue Einstellungen wählen und nochmal transkribieren.
struct ResetSheet: View {
    let transcript: Transcript
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var language = ""
    @State private var speakers = 0
    @AppStorage("quality") private var quality = Quality.best

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zurücksetzen und neu transkribieren").font(.title2.weight(.semibold))
            Text("„\(transcript.title)“ wird mit diesen Einstellungen nochmal transkribiert. Wenn das fertig ist, ersetzt das neue Ergebnis das bisherige Transkript – Änderungen, Sprechernamen und Zusammenfassung gehen dabei verloren. Das alte Transkript landet im Papierkorb.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("Sprache", selection: $language) {
                    ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                }
                Picker("Sprecher", selection: $speakers) {
                    Text("Automatisch").tag(0)
                    Text("Nur eine Person").tag(1)
                    ForEach(2...10, id: \.self) { Text("\($0) Personen").tag($0) }
                }
                Picker("Genauigkeit", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.title).tag($0) }
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Neu transkribieren") {
                    store.reset(transcript.id, options: JobOptions(language: language, speakers: speakers, quality: quality))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            // Mit den Werten des bisherigen Transkripts vorbelegen
            language = LanguageOption.all.contains { $0.code == transcript.language } ? transcript.language : ""
            speakers = transcript.speakers.count >= 2 ? min(transcript.speakers.count, 10) : 0
        }
    }
}
