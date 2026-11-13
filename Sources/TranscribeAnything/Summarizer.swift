import Foundation
import FoundationModels

/// Zusammenfassung mit Apples KI direkt auf dem Mac (Apple Intelligence).
enum Summarizer {
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence ist ausgeschaltet. Aktiviere es unter Systemeinstellungen → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apples KI-Modell wird noch geladen. Bitte versuche es später noch einmal."
        case .unavailable(.deviceNotEligible):
            return "Dieser Mac unterstützt Apple Intelligence nicht."
        case .unavailable:
            return "Apple Intelligence ist gerade nicht verfügbar."
        }
    }

    private static let instructions = """
    Du fasst Transkripte von Interviews und Gesprächen zusammen. \
    Antworte immer auf Deutsch, sachlich und klar gegliedert. Erfinde nichts dazu.
    """

    private static let chunkSize = 6000

    static func summarize(_ t: Transcript, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let text = t.utterances.map { "\(t.name(for: $0.speaker)): \($0.text)" }.joined(separator: "\n")
        var parts = chunks(of: text)

        // Lange Transkripte: erst Abschnitte zusammenfassen, dann die Teilergebnisse
        var round = 0
        while parts.count > 1 {
            round += 1
            var summaries: [String] = []
            for (i, part) in parts.enumerated() {
                progress("Abschnitt \(i + 1) von \(parts.count) wird zusammengefasst …")
                let session = LanguageModelSession(instructions: instructions)
                let r = try await session.respond(to: "Fasse diesen Abschnitt eines Gesprächs in kurzen Stichpunkten zusammen. Behalte wer was gesagt hat:\n\n\(part)")
                summaries.append(r.content)
            }
            parts = chunks(of: summaries.joined(separator: "\n\n"))
            if round > 4 { break }
        }

        progress("Zusammenfassung wird erstellt …")
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Erstelle eine Zusammenfassung dieses Gesprächs mit genau diesen Abschnitten:

        Kurzfassung: 3–4 Sätze.
        Hauptthemen: Stichpunkte.
        Wichtige Aussagen: Stichpunkte, jeweils mit Namen der Person.
        Offene Punkte / nächste Schritte: Stichpunkte, falls vorhanden.

        \(round > 0 ? "Teilzusammenfassungen" : "Transkript"):
        \(parts.first ?? "")
        """
        let r = try await session.respond(to: prompt)
        return r.content
    }

    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > chunkSize, !current.isEmpty {
                result.append(current)
                current = ""
            }
            // Sehr lange Einzelzeilen hart teilen
            var l = Substring(line)
            while l.count > chunkSize {
                result.append(String(l.prefix(chunkSize)))
                l = l.dropFirst(chunkSize)
            }
            current += l + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }
}
