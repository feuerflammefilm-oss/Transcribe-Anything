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

    private func prepareWhisper(_ quality: Quality, report: ProgressReporter) async throws -> WhisperKit {
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

    private func prepareSpeakerKit(report: ProgressReporter) async throws -> SpeakerKit {
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
        if cancel.isCancelled { throw EngineError.cancelled }

        // 1. Sprecher erkennen
        var spans: [(speaker: Int, start: Double, end: Double)] = []
        if options.speakers != 1 {
            let sk = try await prepareSpeakerKit(report: report)
            if cancel.isCancelled { throw EngineError.cancelled }
            report("Sprecher werden erkannt", 0, nil)
            let diarOptions = PyannoteDiarizationOptions(numberOfSpeakers: options.speakers == 0 ? nil : options.speakers)
            let result = try await sk.diarize(audioArray: samples, options: diarOptions, progressCallback: { p in
                report("Sprecher werden erkannt", p.fractionCompleted, nil)
            })
            spans = result.segments.compactMap { seg in
                guard let id = seg.speaker.speakerId else { return nil }
                return (id, Double(seg.startTime), Double(seg.endTime))
            }
        }
        if cancel.isCancelled { throw EngineError.cancelled }

        // 2. Sprache in Text umwandeln
        let whisper = try await prepareWhisper(options.quality, report: report)
        if cancel.isCancelled { throw EngineError.cancelled }
        report("Wird transkribiert", 0, nil)

        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: options.language.isEmpty ? nil : options.language,
            usePrefillPrompt: true,
            detectLanguage: options.language.isEmpty,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let box = ProgressBox()
        let results = try await whisper.transcribe(
            audioArray: samples,
            decodeOptions: decode,
            callback: { _ in cancel.isCancelled ? false : nil },
            segmentCallback: { segments in
                let (end, text) = box.add(segments)
                report("Wird transkribiert", min(0.99, end / duration), text)
            }
        )
        if cancel.isCancelled { throw EngineError.cancelled }

        // 3. Wörter den Sprechern zuordnen
        let words = Self.collectWords(results)
        guard !words.isEmpty else { throw EngineError.noSpeech }
        let utterances = Self.buildUtterances(words: words, spans: spans)
        let language = options.language.isEmpty ? (results.first?.language ?? "") : options.language

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
                    words.append(Word(text: w.word, start: Double(w.start), end: Double(w.end)))
                }
            } else {
                words.append(contentsOf: spread(text: seg.text, start: Double(seg.start), end: Double(seg.end)))
            }
        }
        return words.sorted { $0.start < $1.start }
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

        // Wörter zu Absätzen gruppieren
        var result: [Utterance] = []
        var current: [Word] = []
        var currentSpeaker = speakers[0]

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Utterance(speaker: currentSpeaker, start: first.start, end: last.end, text: text, words: current))
            current = []
        }

        for (i, w) in words.enumerated() {
            let sp = speakers[i]
            if let last = current.last {
                let gap = w.start - last.end
                let sentenceEnd = last.text.trimmingCharacters(in: .whitespaces).last.map { ".?!…".contains($0) } ?? false
                let length = last.end - (current.first?.start ?? last.end)
                if sp != currentSpeaker || gap > 3.0 || (sentenceEnd && (gap > 1.2 || length > 45)) {
                    flush()
                }
            }
            if current.isEmpty { currentSpeaker = sp }
            current.append(w)
        }
        flush()
        return result
    }
}
