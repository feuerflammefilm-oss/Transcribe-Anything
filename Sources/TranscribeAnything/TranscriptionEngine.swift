import Foundation
import SpeakerKit
import WhisperKit

/// Kann von außen gesetzt werden, um eine laufende Transkription abzubrechen.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var maxEnd: Double = 0
    private var texts: [String] = []

    func add(_ segments: [TranscriptionSegment]) -> (Double, String) {
        lock.lock(); defer { lock.unlock() }
        for s in segments {
            maxEnd = max(maxEnd, Double(s.end))
            texts.append(s.text)
        }
        if texts.count > 200 { texts.removeFirst(texts.count - 200) }
        return (maxEnd, texts.joined())
    }
}

enum EngineError: LocalizedError {
    case cancelled
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Abgebrochen"
        case .noSpeech: return "In der Datei wurde keine Sprache erkannt."
        }
    }
}

/// Meldet Phase, Fortschritt (0…1) und optional den bisher erkannten Text.
typealias ProgressReporter = @Sendable (_ phase: String, _ progress: Double, _ preview: String?) -> Void

actor TranscriptionEngine {
    private var whisper: WhisperKit?
    private var whisperVariant: String?
    private var speakerKit: SpeakerKit?

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Transcribe Anything/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Modelle laden

    private func prepareWhisper(_ quality: Quality, report: @escaping ProgressReporter) async throws -> WhisperKit {
        if let w = whisper, whisperVariant == quality.variant { return w }
        whisper = nil
        report("Sprachmodell wird geladen (nur beim ersten Mal)", 0, nil)
        let folder = try await WhisperKit.download(
            variant: quality.variant,
            downloadBase: Self.modelsDirectory,
            progressCallback: { p in
                report("Sprachmodell wird heruntergeladen (nur beim ersten Mal)", p.fractionCompleted, nil)
            }
        )
        report("Sprachmodell wird vorbereitet – beim ersten Mal kann das einige Minuten dauern", 1, nil)
        let config = WhisperKitConfig(
            downloadBase: Self.modelsDirectory,
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let w = try await WhisperKit(config)
        whisper = w
        whisperVariant = quality.variant
        return w
    }

    private func prepareSpeakerKit(report: @escaping ProgressReporter) async throws -> SpeakerKit {
        if let s = speakerKit { return s }
        report("Sprecher-Modell wird geladen (nur beim ersten Mal)", 0, nil)
        let config = PyannoteConfig(downloadBase: Self.modelsDirectory.path, verbose: false)
        let s = try await SpeakerKit(config)
        try await s.ensureModelsLoaded()
        speakerKit = s
        return s
    }

    // MARK: - Transkription

    func transcribe(url: URL, options: JobOptions, cancel: CancelFlag,
                    report: @escaping ProgressReporter) async throws -> Transcript {
        report("Audio wird gelesen", 0, nil)
        let samples = try await AudioLoader.load(url: url)
        let duration = Double(samples.count) / AudioLoader.sampleRate
        guard duration > 0.3 else { throw EngineError.noSpeech }
        if cancel.isCancelled || Task.isCancelled { throw EngineError.cancelled }

        // 1. Sprecher erkennen (auch bei "1 Sprecher": zeigt, wo überhaupt gesprochen wird)
        var spans: [(speaker: Int, start: Double, end: Double)] = []
        do {
            let sk = try await prepareSpeakerKit(report: report)
            if cancel.isCancelled || Task.isCancelled { throw EngineError.cancelled }
            report("Sprecher werden erkannt", 0, nil)
            let diarOptions = PyannoteDiarizationOptions(numberOfSpeakers: options.speakers <= 1 ? nil : options.speakers)
            let result = try await sk.diarize(audioArray: samples, options: diarOptions, progressCallback: { p in
                report("Sprecher werden erkannt", p.fractionCompleted, nil)
            })
            spans = result.segments.compactMap { seg in
                guard let id = seg.speaker.speakerId else { return nil }
                return (id, Double(seg.startTime), Double(seg.endTime))
            }
        }
        if cancel.isCancelled || Task.isCancelled { throw EngineError.cancelled }

        // 2. Sprache in Text umwandeln
        let whisper = try await prepareWhisper(options.quality, report: report)
        if cancel.isCancelled || Task.isCancelled { throw EngineError.cancelled }
        report("Wird transkribiert", 0, nil)

        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: options.language.isEmpty ? nil : options.language,
            usePrefillPrompt: true,
            detectLanguage: options.language.isEmpty,
            skipSpecialTokens: true,
            wordTimestamps: true,
            // Keine Aufteilung an "leisen" Stellen: Whisper arbeitet sich der Reihe nach
            // durch die Aufnahme und behält den Zusammenhang zum vorherigen Satz.
            chunkingStrategy: ChunkingStrategy.none
        )
        let box = ProgressBox()
        let onSegments: SegmentDiscoveryCallback = { segments in
            let (end, text) = box.add(segments)
            report("Wird transkribiert", min(0.99, max(end / duration, whisper.progress.fractionCompleted)), text)
        }
        // Bei VAD-Aufteilung meldet WhisperKit neue Abschnitte nur über diese Eigenschaft
        whisper.segmentDiscoveryCallback = onSegments
        defer { whisper.segmentDiscoveryCallback = nil }

        // Zusätzlich den internen Fortschritt regelmäßig abfragen
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let f = whisper.progress.fractionCompleted
                if f > 0 { report("Wird transkribiert", min(0.99, f), nil) }
            }
        }
        defer { poller.cancel() }

        let results = try await whisper.transcribe(
            audioArray: samples,
            decodeOptions: decode,
            callback: { _ in cancel.isCancelled ? false : nil },
            segmentCallback: onSegments
        )
        if cancel.isCancelled || Task.isCancelled { throw EngineError.cancelled }

        let language = options.language.isEmpty ? (results.first?.language ?? "") : options.language
        var words = Self.collectWords(results)

        // 3. Lücken nachholen: Whisper überspringt manchmal ganze 30-s-Abschnitte
        //    (z. B. bei Musik im Hintergrund). Stellen, an denen laut Sprechererkennung
        //    gesprochen wird, die aber keinen Text haben, werden einzeln nochmal transkribiert.
        let gaps = Self.missingSpeech(words: words, spans: spans, duration: duration)
        if !gaps.isEmpty {
            whisper.segmentDiscoveryCallback = nil
            var gapDecode = decode
            gapDecode.language = language.isEmpty ? nil : language
            gapDecode.detectLanguage = language.isEmpty
            gapDecode.noSpeechThreshold = nil   // hier wissen wir, dass gesprochen wird
            for (n, gap) in gaps.enumerated() {
                if cancel.isCancelled || Task.isCancelled { throw EngineError.cancelled }
                report("Lücken werden nachgeprüft", Double(n) / Double(gaps.count), nil)
                let from = max(0, gap.lowerBound - 1), to = min(duration, gap.upperBound + 1)
                let lo = Int(from * AudioLoader.sampleRate), hi = min(samples.count, Int(to * AudioLoader.sampleRate))
                guard hi - lo > Int(AudioLoader.sampleRate) else { continue }
                let r = try await whisper.transcribe(audioArray: Array(samples[lo..<hi]), decodeOptions: gapDecode)
                // Unsichere oder typische "erfundene" Sätze (bei Musik) verwerfen
                for res in r {
                    res.segments = res.segments.filter { seg in
                        let t = seg.text.lowercased()
                        return seg.avgLogprob > -1.0 && !t.contains("untertitel") && !t.contains("zdf")
                    }
                }
                let found = Self.collectWords(r)
                    .map { Word(text: $0.text, start: $0.start + from, end: $0.end + from) }
                    .filter { gap.contains(($0.start + min($0.end, $0.start + 1.5)) / 2) }
                words.append(contentsOf: found)
            }
            words.sort { $0.start < $1.start }
        }
        guard !words.isEmpty else { throw EngineError.noSpeech }

        // 4. Wörter den Sprechern zuordnen (bei "1 Sprecher" alle derselben Person)
        let utterances = Self.buildUtterances(words: words, spans: options.speakers == 1 ? [] : spans)

        report("Fertig", 1, nil)
        return Transcript(
            title: url.deletingPathExtension().lastPathComponent,
            sourcePath: url.path,
            language: language,
            duration: duration,
            utterances: utterances
        )
    }

    // MARK: - Zusammenführen

    static func collectWords(_ results: [TranscriptionResult]) -> [Word] {
        var words: [Word] = []
        let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }
        for seg in segments {
            if let ws = seg.words, !ws.isEmpty {
                for w in ws where !w.word.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Erstes Wort eines Segments hat oft kein Leerzeichen davor ("Halleluja!Mein")
                    let text = w.word.first?.isWhitespace == true ? w.word : " " + w.word
                    words.append(Word(text: text, start: Double(w.start), end: Double(w.end)))
                }
            } else {
                words.append(contentsOf: spread(text: seg.text, start: Double(seg.start), end: Double(seg.end)))
            }
        }
        return words.sorted { $0.start < $1.start }
    }

    /// Bereiche, in denen laut Sprechererkennung gesprochen wird, für die Whisper aber keinen Text hat.
    static func missingSpeech(words: [Word], spans: [(speaker: Int, start: Double, end: Double)], duration: Double) -> [ClosedRange<Double>] {
        guard !spans.isEmpty else { return [] }
        // Von Wörtern abgedeckte Zeit (ein Wort zählt höchstens 1,5 s, plus etwas Rand)
        let covered = words.map { ($0.start - 1.0)...(min($0.end, $0.start + 1.5) + 1.0) }
        // Sprache aus der Sprechererkennung, zusammengefasst
        var speech: [ClosedRange<Double>] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = speech.last, s.start <= last.upperBound + 1.0 {
                speech[speech.count - 1] = last.lowerBound...max(last.upperBound, s.end)
            } else {
                speech.append(s.start...s.end)
            }
        }
        // Sprache minus abgedeckte Zeit
        var missing: [ClosedRange<Double>] = []
        for sp in speech {
            var pieces = [sp]
            for c in covered where c.overlaps(sp) {
                pieces = pieces.flatMap { p -> [ClosedRange<Double>] in
                    guard c.overlaps(p) else { return [p] }
                    var out: [ClosedRange<Double>] = []
                    if c.lowerBound > p.lowerBound { out.append(p.lowerBound...c.lowerBound) }
                    if c.upperBound < p.upperBound { out.append(c.upperBound...p.upperBound) }
                    return out
                }
            }
            missing.append(contentsOf: pieces)
        }
        // Nahe Stücke zusammenfassen, zu kurze verwerfen
        var merged: [ClosedRange<Double>] = []
        for m in missing.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, m.lowerBound - last.upperBound < 2 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, m.upperBound)
            } else {
                merged.append(m)
            }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= 1.5 && $0.lowerBound < duration }
    }

    /// Verteilt Wörter gleichmäßig über eine Zeitspanne (wenn keine Wortzeiten vorhanden sind).
    static func spread(text: String, start: Double, end: Double) -> [Word] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let totalChars = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        var t = start
        return tokens.map { tok in
            let d = (end - start) * Double(tok.count + 1) / totalChars
            defer { t += d }
            return Word(text: " " + tok, start: t, end: t + d)
        }
    }

    static func buildUtterances(words: [Word], spans: [(speaker: Int, start: Double, end: Double)]) -> [Utterance] {
        // Jedem Wort den Sprecher mit der größten Überlappung geben
        var raw: [Int] = words.map { w in
            guard !spans.isEmpty else { return 0 }
            var best = -1
            var bestOverlap = 0.0
            for s in spans {
                let overlap = min(w.end, s.end) - max(w.start, s.start)
                if overlap > bestOverlap { bestOverlap = overlap; best = s.speaker }
            }
            if best >= 0 { return best }
            let mid = (w.start + w.end) / 2
            return spans.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }!.speaker
        }

        // Einzelne "Ausreißer"-Wörter zwischen demselben Sprecher glätten
        if raw.count > 2 {
            for i in 1..<(raw.count - 1) where raw[i - 1] == raw[i + 1] && raw[i] != raw[i - 1] {
                raw[i] = raw[i - 1]
            }
        }

        // Sprecher nach erstem Auftreten durchnummerieren: 1, 2, 3 …
        var mapping: [Int: Int] = [:]
        let speakers = raw.map { id -> Int in
            if let m = mapping[id] { return m }
            let n = mapping.count + 1
            mapping[id] = n
            return n
        }

        // Bereiche, in denen laut Sprechererkennung niemand spricht (z. B. Musik)
        var silences: [ClosedRange<Double>] = []
        var speechEnd: Double?
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let e = speechEnd, s.start > e { silences.append(e...s.start) }
            speechEnd = max(speechEnd ?? s.end, s.end)
        }

        // Wörter zu Absätzen gruppieren
        var result: [Utterance] = []
        var current: [Word] = []
        var currentSpeaker = speakers[0]

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let u = Utterance(speaker: currentSpeaker, start: first.start, end: last.end, text: text, words: current)
            result.append(contentsOf: u.splitAtPauses(silences: silences))
            current = []
        }

        for (i, w) in words.enumerated() {
            let sp = speakers[i]
            // Neuer Absatz nur bei Sprecherwechsel
            if !current.isEmpty && sp != currentSpeaker {
                flush()
            }
            if current.isEmpty { currentSpeaker = sp }
            current.append(w)
        }
        flush()
        return result
    }
}
