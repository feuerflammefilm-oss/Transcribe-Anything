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
