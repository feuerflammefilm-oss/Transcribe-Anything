import AppKit
import Foundation
import SwiftUI

struct Word: Codable, Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct Utterance: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
    /// Wortgenaue Zeiten. Wird geleert, sobald der Text von Hand bearbeitet wird.
    var words: [Word]
}

struct Transcript: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var sourcePath: String
    var createdAt = Date()
    var language: String
    var duration: Double
    var speakerNames: [Int: String] = [:]
    var utterances: [Utterance]
    var summary: String?

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    var speakers: [Int] {
        Array(Set(utterances.map(\.speaker))).sorted()
    }

    func name(for speaker: Int) -> String {
        if let n = speakerNames[speaker], !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return "Sprecher \(speaker)"
    }

    var plainText: String {
        utterances.map { "\(name(for: $0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }
}

// MARK: - Einstellungen für neue Transkriptionen

enum Quality: String, CaseIterable, Identifiable, Codable, Sendable {
    case best, fast

    var id: String { rawValue }
    var title: String {
        switch self {
        case .best: return "Beste Qualität"
        case .fast: return "Schneller"
        }
    }
    var variant: String {
        switch self {
        case .best: return "large-v3-v20240930_turbo"
        case .fast: return "large-v3-v20240930_626MB"
        }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String   // "" = automatisch
    let name: String
    var id: String { code }

    static let all: [LanguageOption] = [
        .init(code: "", name: "Automatisch erkennen"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "en", name: "Englisch"),
        .init(code: "fr", name: "Französisch"),
        .init(code: "es", name: "Spanisch"),
        .init(code: "it", name: "Italienisch"),
        .init(code: "pt", name: "Portugiesisch"),
        .init(code: "nl", name: "Niederländisch"),
        .init(code: "pl", name: "Polnisch"),
        .init(code: "cs", name: "Tschechisch"),
        .init(code: "sv", name: "Schwedisch"),
        .init(code: "da", name: "Dänisch"),
        .init(code: "no", name: "Norwegisch"),
        .init(code: "fi", name: "Finnisch"),
        .init(code: "tr", name: "Türkisch"),
        .init(code: "ru", name: "Russisch"),
        .init(code: "uk", name: "Ukrainisch"),
        .init(code: "ar", name: "Arabisch"),
        .init(code: "he", name: "Hebräisch"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "ja", name: "Japanisch"),
        .init(code: "ko", name: "Koreanisch"),
        .init(code: "zh", name: "Chinesisch"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code.uppercased()
    }
}

struct JobOptions: Sendable {
    var language: String      // "" = automatisch
    var speakers: Int         // 0 = automatisch, 1 = keine Sprechererkennung
    var quality: Quality
}

// MARK: - Darstellung

enum SpeakerColors {
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.48, blue: 0.95),
        Color(red: 0.90, green: 0.35, blue: 0.25),
        Color(red: 0.15, green: 0.65, blue: 0.45),
        Color(red: 0.62, green: 0.36, blue: 0.85),
        Color(red: 0.92, green: 0.60, blue: 0.10),
        Color(red: 0.10, green: 0.62, blue: 0.72),
        Color(red: 0.85, green: 0.30, blue: 0.60),
        Color(red: 0.45, green: 0.50, blue: 0.20),
    ]
    static func color(_ speaker: Int) -> Color { palette[abs(speaker - 1) % palette.count] }
    static func nsColor(_ speaker: Int) -> NSColor { NSColor(color(speaker)) }
}

enum TimeFormat {
    /// 1:02:03 oder 02:03
    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 00:00:01,000 (SRT) bzw. 00:00:01.000 (VTT)
    static func subtitle(_ t: Double, separator: String) -> String {
        let ms = max(0, Int((t * 1000).rounded()))
        let h = ms / 3_600_000, m = (ms % 3_600_000) / 60_000, s = (ms % 60_000) / 1000, r = ms % 1000
        return String(format: "%02d:%02d:%02d", h, m, s) + separator + String(format: "%03d", r)
    }
}

// MARK: - Wortzeiten im Text

extension Utterance {
    /// Wortzeiten: echte, oder (falls keine da sind) gleichmäßig über den Absatz verteilt.
    var timedWords: [Word] {
        words.isEmpty ? TranscriptionEngine.spread(text: text, start: start, end: end) : words
    }

    /// Findet die Wörter der Reihe nach im Text und liefert ihre Zeichenbereiche (UTF-16).
    static func locate(_ words: [Word], in text: String) -> [NSRange?] {
        let ns = text as NSString
        var cursor = 0
        return words.map { w in
            let core = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty, cursor < ns.length else { return nil }
            let length = min(ns.length - cursor, (core as NSString).length + 40)
            let r = ns.range(of: core, options: [], range: NSRange(location: cursor, length: length))
            guard r.location != NSNotFound else { return nil }
            cursor = r.location + r.length
            return r
        }
    }

    /// Wörter mit ihren Zeichenbereichen (nicht gefundene Wörter werden weggelassen).
    var locatedWords: [(word: Word, range: NSRange)] {
        let ws = timedWords
        return zip(ws, Self.locate(ws, in: text)).compactMap { w, r in r.map { (w, $0) } }
    }

    /// Zeitpunkt des Wortes an einer Textstelle (z. B. dort, wo hineingeklickt wurde).
    func time(atOffset offset: Int) -> Double {
        locatedWords.last { $0.range.location <= offset }?.word.start ?? start
    }

    /// Zeichenbereich des Wortes, das zum Zeitpunkt gerade gesprochen wird.
    func range(at time: Double) -> NSRange? {
        locatedWords.last { $0.word.start <= time }?.range
    }

    /// Übernimmt einen bearbeiteten Text und behält die Wortzeiten außerhalb der geänderten Stelle.
    mutating func applyEdit(_ newText: String) {
        guard newText != text else { return }
        let old = text as NSString, new = newText as NSString
        let oldLen = old.length, newLen = new.length
        var p = 0
        while p < min(oldLen, newLen) && old.character(at: p) == new.character(at: p) { p += 1 }
        var s = 0
        while s < min(oldLen, newLen) - p && old.character(at: oldLen - 1 - s) == new.character(at: newLen - 1 - s) { s += 1 }

        var prefix: [Word] = [], suffix: [Word] = []
        var midStart = 0, midEndOld = oldLen
        for (w, r) in locatedWords {
            if NSMaxRange(r) < p {
                prefix.append(w)
                midStart = NSMaxRange(r)
            } else if r.location > oldLen - s {
                if suffix.isEmpty { midEndOld = r.location }
                suffix.append(w)
            }
        }
        let midEndNew = max(midStart, midEndOld + newLen - oldLen)
        let middle = new.substring(with: NSRange(location: midStart, length: midEndNew - midStart))
        let from = prefix.last?.end ?? start
        let to = max(from, suffix.first?.start ?? end)
        words = prefix + TranscriptionEngine.spread(text: middle, start: from, end: to) + suffix
        text = newText
    }

    /// Teilt den Absatz an einer Textstelle in zwei.
    func split(atOffset offset: Int) -> (Utterance, Utterance) {
        let ns = text as NSString
        let o = max(0, min(offset, ns.length))
        let located = locatedWords
        let left = located.filter { $0.range.location < o }.map(\.word)
        let right = located.filter { $0.range.location >= o }.map(\.word)
        let splitTime = right.first?.start ?? end
        let keepWords = !words.isEmpty
        var a = Utterance(speaker: speaker, start: start, end: left.last?.end ?? min(start, splitTime),
                          text: ns.substring(to: o).trimmingCharacters(in: .whitespacesAndNewlines),
                          words: keepWords ? left : [])
        a.id = id   // erster Teil behält seine Identität
        let b = Utterance(speaker: speaker, start: splitTime, end: max(end, splitTime),
                          text: ns.substring(from: o).trimmingCharacters(in: .whitespacesAndNewlines),
                          words: keepWords ? right : [])
        return (a, b)
    }

    /// Neuer Absatz, wenn länger als `gap` Sekunden nichts gesagt wird – oder bei sehr langen
    /// Absätzen am nächsten Satzende, damit kein riesiger Block entsteht.
    /// `silences`: Bereiche ohne Sprache aus der Sprechererkennung (falls vorhanden).
    func splitAtPauses(gap: Double = 5, maxDuration: Double = 45, silences: [ClosedRange<Double>] = []) -> [Utterance] {
        let ws = words
        guard ws.count > 1 else { return [self] }
        // Whisper zieht Wörter vor/nach Musik oft über die ganze Pause –
        // kein Wort dauert länger als 1,5 s.
        let maxWord = 1.5
        var paragraphStart = ws[0].start
        for i in 1..<ws.count {
            let prev = ws[i - 1], cur = ws[i]
            let prevText = prev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentenceEnd = prevText.last.map { ".?!…".contains($0) } ?? false
            let spokenEnd = min(prev.end, prev.start + maxWord)
            let spokenStart = max(cur.start, cur.end - maxWord)
            let silence = silences.contains { $0.upperBound - $0.lowerBound > gap && $0.lowerBound >= prev.start - 0.5 && $0.upperBound <= cur.end + 0.5 }
            let pause = spokenStart - spokenEnd > gap || silence
            let tooLong = sentenceEnd && ws[i].start - paragraphStart > maxDuration
            guard pause || tooLong else { continue }
            guard let r = Self.locate(ws, in: text)[i], r.location > 0 else { paragraphStart = ws[i].start; continue }
            let (a, b) = split(atOffset: r.location)
            guard !a.text.isEmpty, !b.text.isEmpty else { paragraphStart = ws[i].start; continue }
            return [a] + b.splitAtPauses(gap: gap, maxDuration: maxDuration, silences: silences)
        }
        return [self]
    }
}

extension Utterance {
    /// Hängt den folgenden Absatz an diesen an.
    mutating func merge(_ next: Utterance) {
        let keepWords = !words.isEmpty || !next.words.isEmpty
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        words = keepWords ? timedWords + next.timedWords.map { w in
            var w = w
            if w.text.first?.isWhitespace != true { w.text = " " + w.text }
            return w
        } : []
        text = a.isEmpty ? b : (b.isEmpty ? a : a + " " + b)
        end = max(end, next.end)
    }
}

extension Transcript {
    /// Teilt alle Absätze an langen Pausen (siehe `Utterance.splitAtPauses`).
    mutating func splitAtPauses() {
        utterances = utterances.flatMap { $0.splitAtPauses() }
    }
}
