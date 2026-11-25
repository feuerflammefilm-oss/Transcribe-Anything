import AppKit
import SwiftUI

struct TranscriptView: View {
    let id: UUID
    @EnvironmentObject var store: Store
    @StateObject private var player = Player()

    @State private var search = ""
    @State private var follow = true
    @State private var showTranslate = false
    @State private var summarizing = false
    @State private var summaryStatus = ""
    @State private var summaryError: String?
    @State private var showSummary = true

    @AppStorage("exportTimestamps") private var exportTimestamps = true
    @AppStorage("subtitleSpeaker") private var subtitleSpeaker = false
    @AppStorage("subtitleChars") private var subtitleChars = 42

    private var t: Transcript { store.transcript(id) ?? Transcript(title: "", sourcePath: "", language: "", duration: 0, utterances: []) }

    private var binding: Binding<Transcript> {
        Binding(get: { t }, set: { store.update($0) })
    }

    private var sourceExists: Bool { FileManager.default.fileExists(atPath: t.sourcePath) }

    private var visible: [Utterance] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return t.utterances }
        return t.utterances.filter {
            $0.text.localizedCaseInsensitiveContains(q) || t.name(for: $0.speaker).localizedCaseInsensitiveContains(q)
        }
    }

    private var currentID: UUID? {
        t.utterances.last { $0.start <= player.currentTime + 0.05 }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        summarySection
                        ForEach(visible) { u in
                            UtteranceRow(
                                utterance: utteranceBinding(u.id),
                                transcript: t,
                                isCurrent: u.id == currentID && player.currentTime > 0,
                                onSeek: { player.seek(u.start, play: true) },
                                onSpeaker: { setSpeaker(u.id, $0) }
                            )
                            .id(u.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: currentID) { _, newID in
                    guard follow, player.isPlaying, let newID else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .center) }
                }
            }
            Divider()
            PlayerBar(player: player, enabled: sourceExists, follow: $follow)
        }
        .onAppear {
            if sourceExists { player.load(t.sourceURL, duration: t.duration) }
        }
        .onDisappear { player.stop() }
        .toolbar { toolbar }
        .searchable(text: $search, placement: .toolbar, prompt: "Im Transkript suchen")
        .sheet(isPresented: $showTranslate) {
            TranslateSheet(transcript: t)
        }
    }

    // MARK: - Kopfbereich

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Titel", text: binding.title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Label(TimeFormat.clock(t.duration), systemImage: "clock")
                Label(LanguageOption.name(for: t.language), systemImage: "globe")
                Label("\(t.speakers.count) Sprecher", systemImage: "person.2")
                if !sourceExists {
                    Label("Originaldatei nicht gefunden – Wiedergabe nicht möglich", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(t.speakers, id: \.self) { sp in
                        HStack(spacing: 6) {
                            Circle().fill(SpeakerColors.color(sp)).frame(width: 10, height: 10)
                            TextField("Sprecher \(sp)", text: speakerNameBinding(sp))
                                .textFieldStyle(.plain)
                                .frame(width: 130)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SpeakerColors.color(sp).opacity(0.12), in: Capsule())
                        .help("Klicken, um den Namen zu ändern")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var summarySection: some View {
        if summarizing || t.summary != nil || summaryError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Zusammenfassung", systemImage: "sparkles").font(.headline)
                    Spacer()
                    if t.summary != nil && !summarizing {
                        Button(showSummary ? "Ausblenden" : "Einblenden") { showSummary.toggle() }
                            .buttonStyle(.link)
                        Button("Kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(t.summary ?? "", forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                }
                if summarizing {
                    HStack { ProgressView().controlSize(.small); Text(summaryStatus).foregroundStyle(.secondary) }
                } else if let summaryError {
                    Text(summaryError).foregroundStyle(.red)
                } else if showSummary, let s = t.summary {
                    Text(s).textSelection(.enabled)
                }
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { store.resetID = id } label: { Label("Zurücksetzen", systemImage: "arrow.counterclockwise") }
                .disabled(!sourceExists)
                .help("Zurücksetzen: mit anderen Einstellungen (z. B. Sprache) nochmal transkribieren – ersetzt dieses Transkript")
            Button { summarize() } label: { Label("Zusammenfassen", systemImage: "sparkles") }
                .disabled(summarizing)
                .help("Zusammenfassung mit Kurzfassung, Hauptthemen und wichtigen Aussagen erstellen (Apple Intelligence)")
            Button { showTranslate = true } label: { Label("Übersetzen", systemImage: "translate") }
                .help("Transkript in eine andere Sprache übersetzen – wird als neues Transkript gespeichert")
            Menu {
                Section("Dokument") {
                    ForEach([ExportFormat.txt, .docx, .pdf, .csv]) { f in
                        Button(f.title) { export(f) }
                    }
                    Toggle("Zeitstempel einfügen", isOn: $exportTimestamps)
                }
                Section("Untertitel") {
                    Button(ExportFormat.srt.title) { export(.srt) }
                    Button(ExportFormat.vtt.title) { export(.vtt) }
                    Toggle("Sprechernamen in Untertiteln", isOn: $subtitleSpeaker)
                    Picker("Zeichen pro Zeile", selection: $subtitleChars) {
                        Text("32 (Social Media)").tag(32)
                        Text("37").tag(37)
                        Text("42 (Standard)").tag(42)
                    }
                }
                Divider()
                Button("Text kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Exporter.text(t, timestamps: exportTimestamps), forType: .string)
                }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
            }
            .help("Als Text, Word, PDF, Tabelle oder Untertitel (SRT/VTT) speichern")
        }
    }

    // MARK: - Aktionen

    private func utteranceBinding(_ uid: UUID) -> Binding<Utterance> {
        Binding(
            get: { t.utterances.first { $0.id == uid } ?? Utterance(speaker: 1, start: 0, end: 0, text: "", words: []) },
            set: { newValue in
                var copy = t
                if let i = copy.utterances.firstIndex(where: { $0.id == uid }) {
                    copy.utterances[i] = newValue
                    store.update(copy)
                }
            }
        )
    }

    private func speakerNameBinding(_ sp: Int) -> Binding<String> {
        Binding(
            get: { t.speakerNames[sp] ?? "" },
            set: { var copy = t; copy.speakerNames[sp] = $0; store.update(copy) }
        )
    }

    private func setSpeaker(_ uid: UUID, _ speaker: Int) {
        var copy = t
        if let i = copy.utterances.firstIndex(where: { $0.id == uid }) {
            copy.utterances[i].speaker = speaker
            copy.mergeAdjacentSpeakers()
            store.update(copy)
        }
    }

    private func summarize() {
        if let msg = Summarizer.availabilityMessage {
            summaryError = msg
            return
        }
        summaryError = nil
        summarizing = true
        summaryStatus = "Wird vorbereitet …"
        showSummary = true
        let snapshot = t
        Task {
            do {
                let s = try await Summarizer.summarize(snapshot) { status in
                    Task { @MainActor in summaryStatus = status }
                }
                var copy = t
                copy.summary = s
                store.update(copy)
            } catch {
                summaryError = "Zusammenfassung fehlgeschlagen: \(error.localizedDescription)"
            }
            summarizing = false
        }
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.title).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var sub = SubtitleOptions()
        sub.includeSpeaker = subtitleSpeaker
        sub.maxCharsPerLine = subtitleChars
        do {
            let data = try Exporter.data(for: t, format: format, includeTimestamps: exportTimestamps, subtitle: sub)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

// MARK: - Eine Zeile im Transkript

struct UtteranceRow: View {
    @Binding var utterance: Utterance
    let transcript: Transcript
    let isCurrent: Bool
    let onSeek: () -> Void
    let onSpeaker: (Int) -> Void

    private var textBinding: Binding<String> {
        Binding(
            get: { utterance.text },
            set: { newText in
                guard newText != utterance.text else { return }
                var u = utterance
                u.text = newText
                u.words = []    // Wortzeiten passen nach dem Bearbeiten nicht mehr
                utterance = u
            }
        )
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    ForEach(transcript.speakers, id: \.self) { sp in
                        Button(transcript.name(for: sp)) { onSpeaker(sp) }
                    }
                    Divider()
                    Button("Neuer Sprecher") { onSpeaker((transcript.speakers.max() ?? 0) + 1) }
                } label: {
                    Text(transcript.name(for: utterance.speaker))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(SpeakerColors.color(utterance.speaker))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sprecher ändern")

                Button(action: onSeek) {
                    Text(TimeFormat.clock(utterance.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Ab hier abspielen")
            }
            .frame(width: 140, alignment: .leading)

            TextField("", text: textBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}

// MARK: - Wiedergabe

struct PlayerBar: View {
    @ObservedObject var player: Player
    let enabled: Bool
    @Binding var follow: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(-5) } label: { Image(systemName: "gobackward.5") }
                .help("5 Sekunden zurück")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: .option)
            .help("Abspielen / Pause (⌥ Leertaste)")
            Button { player.skip(5) } label: { Image(systemName: "goforward.5") }
                .help("5 Sekunden vor")

            Text(TimeFormat.clock(player.currentTime)).font(.callout.monospacedDigit())
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }),
                   in: 0...max(player.duration, 1))
            Text(TimeFormat.clock(player.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)

            Menu("\(player.rate.formatted())×") {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { r in
                    Button("\(r.formatted())×") { player.setRate(r) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle("Mitlaufen", isOn: $follow)
                .toggleStyle(.checkbox)
                .help("Beim Abspielen automatisch zur aktuellen Stelle scrollen")
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
