import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detail
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.add(urls: [url]) }
                }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = store.selectedID, let job = store.jobs.first(where: { $0.id == id }) {
            JobDetailView(job: job)
        } else if let id = store.selectedID, store.transcript(id) != nil {
            TranscriptView(id: id)
                .id(id)
        } else {
            EmptyStateView()
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Audio- oder Videodateien hierher ziehen")
                .font(.title2)
            Text("Interviews, Podcasts, Meetings, Videos – alles wird direkt auf deinem Mac transkribiert.")
                .foregroundStyle(.secondary)
            Button("Dateien auswählen …") { openFiles(store: store) }
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Seitenleiste

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @AppStorage("language") private var language = ""
    @AppStorage("speakers") private var speakers = 0
    @AppStorage("quality") private var quality = Quality.best

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                if !store.jobs.isEmpty {
                    Section("In Arbeit") {
                        ForEach(store.jobs) { job in
                            JobRow(job: job).tag(job.id)
                        }
                    }
                }
                Section("Transkripte") {
                    if store.transcripts.isEmpty {
                        Text("Noch keine").foregroundStyle(.secondary)
                    }
                    ForEach(store.transcripts) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).lineLimit(1)
                            Text("\(t.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(TimeFormat.clock(t.duration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(t.id)
                        .contextMenu {
                            Button("Originaldatei im Finder zeigen") {
                                NSWorkspace.shared.activateFileViewerSelecting([t.sourceURL])
                            }
                            Divider()
                            Button("Löschen", role: .destructive) { store.delete(t.id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            settings
        }
        .toolbar {
            ToolbarItem {
                Button { openFiles(store: store) } label: { Label("Hinzufügen", systemImage: "plus") }
                    .help("Dateien transkribieren (⌘O)")
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Für neue Dateien").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        .padding(12)
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.url.lastPathComponent).lineLimit(1)
            switch job.state {
            case .waiting:
                Text("Wartet").font(.caption).foregroundStyle(.secondary)
            case .running:
                ProgressView(value: job.progress).controlSize(.small)
            case .failed:
                Text("Fehler").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct JobDetailView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(job.url.lastPathComponent).font(.title2.weight(.semibold))

            switch job.state {
            case .waiting:
                Label("Wartet auf die vorherige Datei", systemImage: "clock").foregroundStyle(.secondary)
            case .running:
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.phase)
                    ProgressView(value: job.progress)
                    Text("\(Int(job.progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Erneut versuchen") { store.retry(job) }
            }

            if !job.preview.isEmpty {
                GroupBox("Bisher erkannt") {
                    ScrollView {
                        Text(job.preview)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(job.state == .running ? "Abbrechen" : "Entfernen", role: .destructive) { store.cancel(job) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
