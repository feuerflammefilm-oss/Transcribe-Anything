import AppKit
import Foundation
import SwiftUI

enum JobState: Equatable {
    case waiting, running, failed(String)
}

@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let options: JobOptions
    /// Transkript, das nach erfolgreicher Neu-Transkription ersetzt wird
    var replaces: UUID?
    let cancelFlag = CancelFlag()
    @Published var state: JobState = .waiting
    @Published var phase = "Wartet"
    @Published var progress = 0.0
    @Published var preview = ""

    init(url: URL, options: JobOptions) {
        self.url = url
        self.options = options
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var transcripts: [Transcript] = []
    @Published var jobs: [Job] = []
    @Published var selectedID: UUID?
    /// Transkript, für das gerade das Fenster "Zurücksetzen" offen ist
    @Published var resetID: UUID?

    /// Die Einstellungen werden in der Seitenleiste per @AppStorage gesetzt.
    private var currentOptions: JobOptions {
        let d = UserDefaults.standard
        return JobOptions(
            language: d.string(forKey: "language") ?? "",
            speakers: d.object(forKey: "speakers") as? Int ?? 0,
            quality: Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .best
        )
    }

    private let engine = TranscriptionEngine()
    private var isProcessing = false
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var runningTasks: [UUID: Task<Transcript, Error>] = [:]

    static let mediaExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "ogg", "opus", "caf", "wma",
        "mov", "mp4", "m4v", "mkv", "avi", "mxf", "webm", "mts", "m2ts", "mpg", "mpeg", "3gp",
    ]

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Transcribe Anything/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { load() }

    // MARK: - Speichern / Laden

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        transcripts = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Transcript.self, from: Data(contentsOf: $0)) }
            .map { t -> Transcript in var t = t; t.mergeAdjacentSpeakers(); return t }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func write(_ t: Transcript) {
        let url = folder.appendingPathComponent("\(t.id.uuidString).json")
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: url, options: .atomic) }
    }

    func transcript(_ id: UUID) -> Transcript? {
        transcripts.first { $0.id == id }
    }

    /// Änderungen übernehmen und kurz danach speichern.
    func update(_ t: Transcript) {
        guard let i = transcripts.firstIndex(where: { $0.id == t.id }) else { return }
        if transcripts[i] == t { return }
        transcripts[i] = t
        saveTasks[t.id]?.cancel()
        saveTasks[t.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let current = self.transcript(t.id) else { return }
            self.write(current)
        }
    }

    func insert(_ t: Transcript, select: Bool = true) {
        transcripts.insert(t, at: 0)
        write(t)
        if select { selectedID = t.id }
    }

    func delete(_ id: UUID) {
        let index = transcripts.firstIndex { $0.id == id }
        transcripts.removeAll { $0.id == id }
        // In den Papierkorb statt endgültig löschen – falls man sich vertippt
        let file = folder.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        if selectedID == id {
            // Nächsten Eintrag auswählen, damit man mehrere nacheinander löschen kann
            let i = min(index ?? 0, transcripts.count - 1)
            selectedID = i >= 0 ? transcripts[i].id : nil
        }
    }

    // MARK: - Warteschlange

    func add(urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                    .compactMap { $0 as? URL } ?? []
                files += items.filter { Self.mediaExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            } else {
                files.append(url)
            }
        }
        let options = currentOptions
        let newJobs = files.map { Job(url: $0, options: options) }
        jobs += newJobs
        if let first = newJobs.first { selectedID = first.id }
        Task { await processQueue() }
    }

    /// Bricht sofort ab: Der Eintrag verschwindet direkt, die Arbeit im Hintergrund wird gestoppt.
    func cancel(_ job: Job) {
        job.cancelFlag.cancel()
        runningTasks[job.id]?.cancel()
        if selectedID == job.id {
            selectedID = jobs.first(where: { $0.id != job.id })?.id ?? transcripts.first?.id
        }
        jobs.removeAll { $0.id == job.id }
    }

    /// Transkript zurücksetzen: mit neuen Einstellungen nochmal transkribieren, das Ergebnis ersetzt das alte.
    func reset(_ id: UUID, options: JobOptions) {
        guard let t = transcript(id) else { return }
        let job = Job(url: t.sourceURL, options: options)
        job.replaces = id
        jobs.append(job)
        selectedID = job.id
        Task { await processQueue() }
    }

    func retry(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        let j = Job(url: job.url, options: job.options)
        j.replaces = job.replaces
        jobs.append(j)
        selectedID = j.id
        Task { await processQueue() }
    }

    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transkription läuft")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            isProcessing = false
        }

        var didFinish = false
        while let job = jobs.first(where: { $0.state == .waiting }) {
            job.state = .running
            job.phase = "Startet …"
            let engine = self.engine
            let task = Task<Transcript, Error> {
                try await engine.transcribe(
                    url: job.url, options: job.options, cancel: job.cancelFlag,
                    report: { phase, progress, preview in
                        Task { @MainActor in
                            guard !job.cancelFlag.isCancelled else { return }
                            // Innerhalb einer Phase soll der Balken nie zurückspringen
                            job.progress = phase == job.phase ? max(job.progress, progress) : progress
                            job.phase = phase
                            if let preview { job.preview = preview }
                        }
                    })
            }
            runningTasks[job.id] = task
            do {
                let transcript = try await task.value
                runningTasks[job.id] = nil
                if job.cancelFlag.isCancelled { continue }
                var t = transcript
                t.id = job.id   // damit die Auswahl in der Seitenleiste erhalten bleibt
                if let oldID = job.replaces, let old = self.transcript(oldID) {
                    t.title = old.title   // selbst vergebenen Titel behalten
                    delete(oldID)
                }
                jobs.removeAll { $0.id == job.id }
                insert(t, select: selectedID == job.id)
                didFinish = true
            } catch {
                runningTasks[job.id] = nil
                if job.cancelFlag.isCancelled || error is CancellationError {
                    jobs.removeAll { $0.id == job.id }
                } else {
                    job.state = .failed(error.localizedDescription)
                }
            }
        }
        if didFinish { NSSound(named: "Glass")?.play() }
    }
}
