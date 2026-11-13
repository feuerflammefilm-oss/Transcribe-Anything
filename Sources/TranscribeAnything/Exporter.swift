import AppKit
import CoreText
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, docx, pdf, srt, vtt, csv

    var id: String { rawValue }
    var title: String {
        switch self {
        case .txt: return "Text (TXT)"
        case .docx: return "Word (DOCX)"
        case .pdf: return "PDF"
        case .srt: return "Untertitel (SRT)"
        case .vtt: return "Untertitel (VTT)"
        case .csv: return "Tabelle (CSV)"
        }
    }
}

struct SubtitleOptions {
    var maxCharsPerLine = 42
    var maxLines = 2
    var maxDuration = 6.0
    var includeSpeaker = false
}

struct Cue {
    var start: Double
    var end: Double
    var text: String
}

enum Exporter {
    static func data(for transcript: Transcript, format: ExportFormat,
                     includeTimestamps: Bool, subtitle: SubtitleOptions) throws -> Data {
        switch format {
        case .txt: return Data(text(transcript, timestamps: includeTimestamps).utf8)
        case .srt: return Data(srt(cues(transcript, subtitle)).utf8)
        case .vtt: return Data(vtt(cues(transcript, subtitle)).utf8)
        case .csv: return csv(transcript)
        case .docx: return try docx(transcript, timestamps: includeTimestamps)
        case .pdf: return pdf(transcript, timestamps: includeTimestamps)
        }
    }

    // MARK: - Text

    static func text(_ t: Transcript, timestamps: Bool) -> String {
        var out = ""
        for u in t.utterances {
            if timestamps { out += "[\(TimeFormat.clock(u.start))] " }
            out += "\(t.name(for: u.speaker)):\n\(u.text)\n\n"
        }
        return out
    }

    // MARK: - Untertitel

    private static func timedWords(_ u: Utterance) -> [Word] {
        if !u.words.isEmpty { return u.words }
        return TranscriptionEngine.spread(text: u.text, start: u.start, end: u.end)
    }

    static func cues(_ t: Transcript, _ o: SubtitleOptions) -> [Cue] {
        var cues: [Cue] = []
        for u in t.utterances {
            let words = timedWords(u)
            var lines: [String] = [""]
            var cueStart: Double?
            var cueEnd = u.start
            var firstCueOfUtterance = true

            func flush() {
                let body = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let s = cueStart, !body.isEmpty else { return }
                var text = body.joined(separator: "\n")
                if o.includeSpeaker && firstCueOfUtterance { text = "\(t.name(for: u.speaker)): " + text }
                cues.append(Cue(start: s, end: cueEnd, text: text))
                firstCueOfUtterance = false
                lines = [""]
                cueStart = nil
            }

            for w in words {
                let token = w.text.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { continue }
                let candidate = lines[lines.count - 1].isEmpty ? token : lines[lines.count - 1] + " " + token
                if candidate.count > o.maxCharsPerLine && !lines[lines.count - 1].isEmpty {
                    if lines.count >= o.maxLines { flush(); lines[0] = token } else { lines.append(token) }
                } else {
                    lines[lines.count - 1] = candidate
                }
                if cueStart == nil { cueStart = w.start }
                cueEnd = w.end
                let sentenceEnd = token.last.map { ".?!…".contains($0) } ?? false
                let totalChars = lines.reduce(0) { $0 + $1.count }
                if let s = cueStart, (w.end - s) >= o.maxDuration || (sentenceEnd && totalChars > o.maxCharsPerLine / 2) {
                    flush()
                }
            }
            flush()
        }
        // Mindestdauer 1 s, aber ohne den nächsten Untertitel zu überlappen
        for i in cues.indices {
            let next = i + 1 < cues.count ? cues[i + 1].start : .infinity
            if cues[i].end - cues[i].start < 1.0 { cues[i].end = min(cues[i].start + 1.0, next) }
            if cues[i].end > next { cues[i].end = next }
        }
        return cues
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(TimeFormat.subtitle(c.start, separator: ",")) --> \(TimeFormat.subtitle(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(TimeFormat.subtitle(c.start, separator: ".")) --> \(TimeFormat.subtitle(c.end, separator: "."))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: - CSV (Semikolon, damit Excel es auf deutschen Macs direkt öffnet)

    static func csv(_ t: Transcript) -> Data {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["Start;Ende;Sprecher;Text"]
        for u in t.utterances {
            rows.append([TimeFormat.clock(u.start), TimeFormat.clock(u.end), esc(t.name(for: u.speaker)), esc(u.text)].joined(separator: ";"))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data(rows.joined(separator: "\r\n").utf8)
    }

    // MARK: - DOCX

    static func docx(_ t: Transcript, timestamps: Bool) throws -> Data {
        func x(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func hex(_ speaker: Int) -> String {
            let c = SpeakerColors.nsColor(speaker).usingColorSpace(.sRGB) ?? .black
            return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }

        var body = """
        <w:p><w:pPr><w:spacing w:after="240"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="36"/></w:rPr><w:t xml:space="preserve">\(x(t.title))</w:t></w:r></w:p>
        """
        for u in t.utterances {
            var head = "<w:r><w:rPr><w:b/><w:color w:val=\"\(hex(u.speaker))\"/></w:rPr><w:t xml:space=\"preserve\">\(x(t.name(for: u.speaker)))</w:t></w:r>"
            if timestamps {
                head += "<w:r><w:rPr><w:color w:val=\"888888\"/></w:rPr><w:t xml:space=\"preserve\">   \(TimeFormat.clock(u.start))</w:t></w:r>"
            }
            body += "<w:p><w:pPr><w:keepNext/><w:spacing w:before=\"200\" w:after=\"40\"/></w:pPr>\(head)</w:p>"
            body += "<w:p><w:r><w:t xml:space=\"preserve\">\(x(u.text))</w:t></w:r></w:p>"
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1417" w:bottom="1134" w:left="1417" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        try contentTypes.write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rels.write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try document.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)

        let out = dir.appendingPathComponent("out.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-X", "-q", "-r", out.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()
        return try Data(contentsOf: out)
    }

    // MARK: - PDF

    static func attributed(_ t: Transcript, timestamps: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        func add(_ text: String, font: NSFont, color: NSColor, spacingBefore: CGFloat = 0) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.lineSpacing = 2
            s.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, colorKey: color.cgColor, .paragraphStyle: p,
            ]))
        }
        add(t.title + "\n", font: .boldSystemFont(ofSize: 20), color: .black)
        add("\(TimeFormat.clock(t.duration)) · \(LanguageOption.name(for: t.language))\n", font: .systemFont(ofSize: 10), color: .gray)
        for u in t.utterances {
            add(t.name(for: u.speaker), font: .boldSystemFont(ofSize: 11), color: SpeakerColors.nsColor(u.speaker), spacingBefore: 10)
            add(timestamps ? "   \(TimeFormat.clock(u.start))\n" : "\n", font: .systemFont(ofSize: 9), color: .gray)
            add(u.text + "\n", font: .systemFont(ofSize: 11), color: .black)
        }
        return s
    }

    static func pdf(_ t: Transcript, timestamps: Bool) -> Data {
        let attr = attributed(t, timestamps: timestamps)
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let textRect = mediaBox.insetBy(dx: 56, dy: 56)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < attr.length
        ctx.closePDF()
        return data as Data
    }
}
