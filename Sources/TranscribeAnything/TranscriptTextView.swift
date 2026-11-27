import AppKit
import SwiftUI

/// Bearbeitbarer Absatz-Text (NSTextView), der
/// - das gerade gesprochene Wort hervorhebt, ohne das Bearbeiten zu stören,
/// - beim Klicken die angeklickte Textstelle meldet (zum Hinspringen im Ton),
/// - bei Enter den Absatz an der Cursorposition teilt.
struct TranscriptTextView: NSViewRepresentable {
    let text: String
    /// Zeichenbereich des aktuell gesprochenen Wortes (UTF-16)
    let highlight: NSRange?
    /// Das hervorgehobene Wort im Fenster sichtbar halten
    let follow: Bool
    /// Cursor an diese Stelle setzen und Fokus holen (z. B. nach dem Teilen)
    let focusOffset: Int?
    let onChange: (String) -> Void
    let onClick: (Int) -> Void
    let onSplit: (Int) -> Void
    /// Rücktaste ganz am Anfang: mit dem vorherigen Absatz zusammenführen
    let onMergeUp: () -> Void
    let onFocused: () -> Void

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView
        var lastHighlight: NSRange?
        init(_ parent: TranscriptTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onChange(tv.string)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Falls ein Zeilenumbruch doch als Text ankommt: ebenfalls teilen
            if replacementString == "\n" || replacementString == "\r" {
                parent.onSplit(range.location)
                return false
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSplit(textView.selectedRange().location)
                return true
            }
            if selector == #selector(NSResponder.deleteBackward(_:)), textView.selectedRange() == NSRange(location: 0, length: 0) {
                parent.onMergeUp()
                return true
            }
            return false
        }
    }

    final class ClickTextView: NSTextView {
        var onClick: ((Int) -> Void)?
        var onSplit: ((Int) -> Void)?

        override func keyDown(with event: NSEvent) {
            // Return (36) bzw. Enter am Ziffernblock (76) ohne Zusatztasten: Absatz teilen
            let mods = event.modifierFlags.intersection([.shift, .option, .command, .control])
            if (event.keyCode == 36 || event.keyCode == 76), mods.isEmpty, !hasMarkedText() {
                onSplit?(selectedRange().location)
                return
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)   // läuft, bis die Maus losgelassen wird
            let sel = selectedRange()
            if sel.length == 0 { onClick?(sel.location) }   // nur Klick, kein Markieren
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClickTextView {
        let tv = ClickTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        tv.defaultParagraphStyle = style
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        tv.string = text
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: ClickTextView, context: Context) {
        context.coordinator.parent = self
        tv.onClick = onClick
        tv.onSplit = onSplit
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            context.coordinator.lastHighlight = nil
        }

        if let lm = tv.layoutManager, context.coordinator.lastHighlight != highlight || highlight == nil {
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            if let h = highlight, NSMaxRange(h) <= full.length {
                lm.addTemporaryAttribute(.backgroundColor,
                                         value: NSColor.controlAccentColor.withAlphaComponent(0.45),
                                         forCharacterRange: h)
                if follow, context.coordinator.lastHighlight != h { tv.scrollRangeToVisible(h) }
            }
            context.coordinator.lastHighlight = highlight
        }

        if let focusOffset, let window = tv.window {
            if window.firstResponder !== tv { window.makeFirstResponder(tv) }
            let len = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(focusOffset, len), length: 0))
            DispatchQueue.main.async { onFocused() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: ClickTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let lineHeight = lm.defaultLineHeight(for: Self.font)
        return CGSize(width: width, height: max(ceil(lm.usedRect(for: tc).height), lineHeight))
    }
}
