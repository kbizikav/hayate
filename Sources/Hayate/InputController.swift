import Cocoa
import InputMethodKit
import HayateCore

/// Google-IME-style flow: kana while typing (zero lag), Space converts.
/// Every keystroke prefetches the LLM conversion in the background, so Space is usually a cache hit.
///
/// Converting: focused clause (thick underline) + rest as kana (thin underline).
/// Space/↓↑ pick a candidate, Shift+←→ resize the focused clause, 1–9 pick from the list,
/// Enter commits the clause and converts the rest; → does the same and opens the list for the rest (azooKey).
@objc(HayateInputController)
final class HayateInputController: IMKInputController {
    private static let japaneseMode = "com.apple.inputmethod.Japanese"
    private static let romanMode = "com.apple.inputmethod.Roman"
    private let notFound = NSRange(location: NSNotFound, length: 0)

    private var text = ComposingText()
    private var left = ""        // left context, captured once per composition
    private var cands: [Candidate] = []
    private var sel: Int?        // nil = showing kana, else index into cands
    private var seg: Int?        // focused clause length in kana; nil = whole input
    private var japanese = true
    private var firstKey = true  // log once per activation that key events arrive

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        firstKey = true
        log.notice("activated")
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard tag == kTextServiceInputModePropertyTag, let mode = value as? String else { return }
        if let c = sender as? IMKTextInput { commitAll(c) }
        japanese = mode == Self.japaneseMode
    }

    override func deactivateServer(_ sender: Any!) {
        if let c = sender as? IMKTextInput { commitAll(c) }
        candidateWindow.hide()
        engine.saveLearning()
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        if let c = sender as? IMKTextInput { commitAll(c) }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if firstKey {
            firstKey = false
            log.notice("key events arriving; client ok: \(sender is IMKTextInput, privacy: .public), japanese: \(self.japanese, privacy: .public)")
        }
        guard let event, event.type == .keyDown, let c = sender as? IMKTextInput else { return false }
        switch event.keyCode {
        case 102: commitAll(c); c.selectMode(Self.romanMode); return true  // 英数
        case 104: c.selectMode(Self.japaneseMode); return true             // かな
        default: break
        }
        guard japanese else { return false }
        if !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            // Ctrl+C while composing cancels it (like Esc); the next Ctrl+C reaches the app/terminal.
            if !text.isEmpty, event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "c" {
                clear(c)
                return true
            }
            commitAll(c)
            return false
        }
        if text.isEmpty {
            if event.keyCode == 49 { c.insertText("　", replacementRange: notFound); return true }  // full-width space, like Google IME
            return insertChar(event, c)
        }
        switch event.keyCode {
        case 36, 76: if let i = sel { commit(i, c) } else { commitAll(c) }  // return / enter
        case 49, 125: step(+1, c)                                           // space / ↓
        case 126: if sel != nil { step(-1, c) }                             // ↑
        case 123: if event.modifierFlags.contains(.shift) { resize(-1, c) }  // Shift+←
        case 124:
            if event.modifierFlags.contains(.shift) { resize(+1, c) }         // Shift+→
            else if let i = sel { commit(i, c, thenList: true) }              // →: commit clause, go to next
        case 51: if sel != nil { cancelConversion(c) } else { text.deleteBackwardFromCursorPosition(count: 1); typed(c) }
        case 53: if sel != nil { cancelConversion(c) } else { clear(c) }   // esc
        default:
            guard let s = Self.printable(event) else { break }  // tab etc.: ignore for now
            if let i = sel, candidateWindow.isVisible, let d = Int(s), d >= 1 {
                let pick = i / CandidateWindow.pageSize * CandidateWindow.pageSize + d - 1
                if pick < cands.count { commit(pick, c) }
                return true
            }
            if sel != nil { commitAll(c) }  // typing during conversion confirms it
            _ = insertChar(event, c)
        }
        return true  // swallow everything else while composing
    }

    private static func printable(_ event: NSEvent) -> String? {
        guard let s = event.characters, s.unicodeScalars.count == 1,
              let u = s.unicodeScalars.first, (0x21..<0x7f).contains(u.value) else { return nil }
        return s
    }

    // MARK: - Input menu (menu bar「あ」)

    override func menu() -> NSMenu! {
        let m = NSMenu()
        let debug = NSMenuItem(title: "デバッグモード（入力内容をログに記録）", action: #selector(toggleDebug(_:)), keyEquivalent: "")
        debug.state = debugMode ? .on : .off
        m.addItem(debug)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "学習データをクリア…", action: #selector(clearLearning(_:)), keyEquivalent: ""))
        return m
    }

    @objc private func toggleDebug(_ sender: Any?) {
        debugMode.toggle()
        log.notice("debug mode: \(debugMode, privacy: .public)")
    }

    @objc private func clearLearning(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "学習データをクリアしますか？"
        alert.informativeText = "これまでに確定した変換の学習がすべて消えます。元に戻せません。"
        alert.addButton(withTitle: "クリア")
        alert.addButton(withTitle: "キャンセル")
        alert.window.level = .floating  // background-only app: keep the alert above the user's window
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.resetLearning()
        log.notice("learning data cleared")
    }

    // MARK: - State transitions

    private func insertChar(_ event: NSEvent, _ c: IMKTextInput) -> Bool {
        guard let ch = Self.printable(event)?.first else { return false }
        if text.isEmpty { left = leftContext(c) }
        text.type(ch, shift: event.modifierFlags.contains(.shift))
        typed(c)
        return true
    }

    private func typed(_ c: IMKTextInput) {
        sel = nil
        seg = nil
        candidateWindow.hide()
        if text.isEmpty { return clear(c) }
        showMarked(c)
        engine.prefetch(text.separated(), left: left)  // what Space will convert
    }

    /// First Space converts (top candidate only, like Google IME); later ones walk the list.
    private func step(_ delta: Int, _ c: IMKTextInput) {
        if let s = sel {
            sel = (s + delta + cands.count) % cands.count
            showList(c)
        } else {
            convert()
        }
        showMarked(c)
    }

    /// (Re)convert the focused range: the whole input, or its first `seg` kana.
    private func convert() {
        _ = text.moveCursorFromCursorPosition(count: text.convertTarget.count - text.convertTargetCursorPosition)
        text = text.separated()
        var target = text
        if let seg {
            _ = target.moveCursorFromCursorPosition(count: seg - target.convertTargetCursorPosition)
            target = target.prefixToCursorPosition()
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        cands = engine.convert(target, left: left)
        sel = cands.isEmpty ? nil : 0
        if debugMode {
            let ms = String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            log.notice("[debug] convert \(ms, privacy: .public)ms 「\(self.left, privacy: .public)」+\(target.convertTarget, privacy: .public) → \(self.cands.prefix(5).map(\.text).joined(separator: " / "), privacy: .public)")
        }
    }

    /// Grow/shrink the focused clause by one kana.
    private func resize(_ delta: Int, _ c: IMKTextInput) {
        guard let i = sel else { return }
        let total = text.convertTarget.count
        let current = seg ?? (total - rest(cands[i]).convertTarget.count)
        let next = min(total, max(1, current + delta))
        guard next != current else { return }
        seg = next == total ? nil : next
        convert()
        showMarked(c)
        showList(c)
    }

    /// Confirm candidate `i`. If it covered only a prefix, convert the rest next
    /// (`thenList`: and open the candidate list for it).
    private func commit(_ i: Int, _ c: IMKTextInput, thenList: Bool = false) {
        let cand = cands[i]
        c.insertText(cand.text, replacementRange: notFound)
        engine.commit(cand)
        text = rest(cand)
        left += cand.text
        sel = nil
        seg = nil
        candidateWindow.hide()
        guard !text.isEmpty else { return clear(c, erase: false) }
        step(+1, c)
        if thenList { showList(c) }
    }

    private func commitAll(_ c: IMKTextInput) {
        guard !text.isEmpty else { return }
        if let i = sel { engine.commit(cands[i]) } else { text = text.separated() }
        let (head, tail) = parts()
        c.insertText(head + tail, replacementRange: notFound)
        clear(c, erase: false)
    }

    private func cancelConversion(_ c: IMKTextInput) {
        sel = nil
        seg = nil
        candidateWindow.hide()
        showMarked(c)
    }

    /// `erase`: also clear the app's marked text. Skip it right after `insertText`, which already
    /// replaced it — that redundant `setMarkedText` crashed Ghostty inside AppKit.
    private func clear(_ c: IMKTextInput, erase: Bool = true) {
        text = ComposingText()
        cands = []
        sel = nil
        seg = nil
        candidateWindow.hide()
        if erase {
            c.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        }
        engine.endComposition()
    }

    // MARK: - Display

    /// Input left after committing `cand`.
    private func rest(_ cand: Candidate) -> ComposingText {
        var r = text
        r.prefixComplete(composingCount: cand.composingCount)
        return r
    }

    /// (focused/converted part, remaining kana)
    private func parts() -> (String, String) {
        guard let i = sel else { return (text.convertTarget, "") }
        return (cands[i].text, rest(cands[i]).convertTarget)
    }

    private func showMarked(_ c: IMKTextInput) {
        let (head, tail) = parts()
        let s = NSMutableAttributedString(string: head, attributes: [
            .underlineStyle: (sel == nil ? NSUnderlineStyle.single : .thick).rawValue, .markedClauseSegment: 0,
        ])
        s.append(NSAttributedString(string: tail, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 1]))
        c.setMarkedText(s, selectionRange: NSRange(location: s.length, length: 0), replacementRange: notFound)
    }

    private func showList(_ c: IMKTextInput) {
        guard let i = sel else { return }
        candidateWindow.show(cands.map(\.text), selected: i, below: caretRect(c))
    }

    private func caretRect(_ c: IMKTextInput) -> NSRect {
        var r = NSRect.zero
        _ = c.attributes(forCharacterIndex: 0, lineHeightRectangle: &r)
        return r
    }

    /// Text left of the composition. Same as azooKey: `string(from:)` (widely implemented, unlike
    /// `attributedSubstring`), anchored at the marked range when there is one.
    private func leftContext(_ c: IMKTextInput) -> String {
        let marked = c.markedRange()
        let end = marked.location != NSNotFound ? marked.location : c.selectedRange().location
        guard end != NSNotFound, end > 0 else {
            log.notice("left context: none (cursor \(end == NSNotFound ? "unknown" : "at start", privacy: .public))")
            return ""
        }
        let n = min(end, 30)
        var actual = NSRange()
        let s = c.string(from: NSRange(location: end - n, length: n), actualRange: &actual) ?? ""
        log.notice("left context: \(s.count, privacy: .public) chars")  // count only unless debug mode
        if debugMode { log.notice("[debug] left context: 「\(s, privacy: .public)」") }
        return s
    }
}
