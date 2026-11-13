import SwiftUI
import Translation

/// Übersetzt ein Transkript mit Apples eingebauter Übersetzung (läuft lokal auf dem Mac).
/// Das Ergebnis wird als neues Transkript gespeichert – mit denselben Zeiten, also auch als Untertitel exportierbar.
struct TranslateSheet: View {
    let transcript: Transcript
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var target = "en"
    @State private var configuration: TranslationSession.Configuration?
    @State private var running = false
    @State private var error: String?

    private var targets: [LanguageOption] {
        LanguageOption.all.filter { !$0.code.isEmpty && $0.code != transcript.language }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transkript übersetzen").font(.title2.weight(.semibold))
            Text("Die Übersetzung läuft direkt auf deinem Mac. Beim ersten Mal fragt macOS eventuell, ob die Sprache heruntergeladen werden soll.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Zielsprache", selection: $target) {
                ForEach(targets) { Text($0.name).tag($0.code) }
            }
            .disabled(running)

            if running {
                HStack { ProgressView().controlSize(.small); Text("Wird übersetzt …") }
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übersetzen") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(24)
        .frame(width: 440)
        .translationTask(configuration) { session in
            await translate(using: session)
        }
    }

    private func start() {
        error = nil
        running = true
        let source: Locale.Language? = transcript.language.isEmpty ? nil : Locale.Language(identifier: transcript.language)
        let config = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: target))
        if configuration == config {
            configuration?.invalidate()
        } else {
            configuration = config
        }
    }

    private func translate(using session: TranslationSession) async {
        let requests = transcript.utterances.enumerated().map { i, u in
            TranslationSession.Request(sourceText: u.text, clientIdentifier: String(i))
        }
        do {
            let responses = try await session.translations(from: requests)
            var copy = transcript
            copy.id = UUID()
            copy.createdAt = Date()
            copy.title = "\(transcript.title) (\(LanguageOption.name(for: target)))"
            copy.language = target
            copy.summary = nil
            copy.utterances = transcript.utterances.map { u in
                var n = u
                n.id = UUID()
                n.words = []
                return n
            }
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), i < copy.utterances.count {
                    copy.utterances[i].text = r.targetText
                }
            }
            await MainActor.run {
                store.insert(copy)
                running = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                self.error = "Übersetzung fehlgeschlagen: \(error.localizedDescription)"
                running = false
            }
        }
    }
}
