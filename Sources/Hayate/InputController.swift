import Cocoa
import InputMethodKit
import HayateCore

/// Google-IME-style flow: kana while typing (zero lag), Space converts.
/// Every keystroke prefetches the LLM conversion in the background, so Space is usually a cache hit.
///
/// Converting shows the sentence as clauses (文節), Google style. When the LLM and close dictionary
/// alternatives disagree somewhere, the sentence starts split with that clause focused; when they agree
/// it starts as one whole-sentence clause. Space/↓↑ cycle the focused clause, ←→ move focus (and open
/// a whole sentence into clauses), Shift+←→ resize, 1–9 pick, Enter commits everything.
@objc(HayateInputController)
final class HayateInputController: IMKInputController {
    private static let japaneseMode = "com.apple.inputmethod.Japanese"
    private static let romanMode = "com.apple.inputmethod.Roman"
    private let notFound = NSRange(location: NSNotFound, length: 0)

    private struct Seg {
        var length: Int           // kana
        var cands: [Candidate]    // all convert exactly this clause; [0] is what conversion first showed
        var sel = 0
        var expanded = false      // cands holds the full list (fetched lazily, with both-side context)
        var shown: Candidate { cands[sel] }
    }

    private var text = ComposingText()
    private var left = ""         // left context, captured once per composition
    private var segs: [Seg] = []  // empty = showing kana
    private var focus = 0
    private var japanese = true
    private var firstKey = true   // log once per activation that key events arrive

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        firstKey = true
        log.notice("activated")
    }

    // Mode/source switches: never talk to the client here. The system fixes the marked text itself
    // (TSM insertFixLenText) and calls `commitComposition`; inserting or re-marking text at the same
    // time crashed Ghostty inside AppKit. Same approach as azooKey.
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer { super.setValue(value, forTag: tag, client: sender) }
        guard tag == kTextServiceInputModePropertyTag, let mode = value as? String else { return }
        japanese = mode == Self.japaneseMode
    }

    override func deactivateServer(_ sender: Any!) {
        reset()
        engine.saveLearning()
        super.deactivateServer(sender)
    }

    /// IMK may push this to the client on its own; it must never be nil (a nil marked string
    /// reaches AppKit's `_forceAttributedString` → `CFEqual(NULL)`).
    override func composedString(_ sender: Any!) -> Any! { markedString().text }

    override func originalString(_ sender: Any!) -> NSAttributedString! { NSAttributedString(string: text.convertTarget) }

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
        let converting = !segs.isEmpty
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 36, 76: commitAll(c)                                             // return / enter
        case 49, 125: converting ? step(+1, c) : startConversion(c)          // space / ↓
        case 126: if converting { step(-1, c) }                              // ↑
        case 123: if converting { shift ? resize(-1, c) : move(-1, c) }      // ←
        case 124: if converting { shift ? resize(+1, c) : move(+1, c) }      // →
        case 51: if converting { cancelConversion(c) } else { text.deleteBackwardFromCursorPosition(count: 1); typed(c) }
        case 53: if converting { cancelConversion(c) } else { clear(c) }    // esc
        default:
            guard let s = Self.printable(event) else { break }  // tab etc.: ignore for now
            if converting, candidateWindow.isVisible, let d = Int(s), d >= 1 {
                pick(segs[focus].sel / CandidateWindow.pageSize * CandidateWindow.pageSize + d - 1, c)
                return true
            }
            if converting { commitAll(c) }  // typing during conversion confirms it
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

    // MARK: - Typing

    private func insertChar(_ event: NSEvent, _ c: IMKTextInput) -> Bool {
        guard let ch = Self.printable(event)?.first else { return false }
        if text.isEmpty { left = leftContext(c) }
        text.type(ch, shift: event.modifierFlags.contains(.shift))
        typed(c)
        return true
    }

    private func typed(_ c: IMKTextInput) {
        segs = []
        candidateWindow.hide()
        if text.isEmpty { return clear(c) }
        showMarked(c)
        engine.prefetch(text.separated(), left: left)  // what Space will convert
    }

    // MARK: - Converting

    private func startConversion(_ c: IMKTextInput) {
        _ = text.moveCursorFromCursorPosition(count: text.convertTarget.count - text.convertTargetCursorPosition)
        text = text.separated()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = engine.convert(text, left: left)
        let whole = r.candidates.filter { text.isCovered(by: $0) }
        guard let sentence = whole.first else { return }
        let n = text.convertTarget.count
        let clauses = Engine.split(sentence, kanaCount: n, alternatives: r.dict.filter { text.isCovered(by: $0) })
        if let clauses, clauses.count > 1, let k = clauses.firstIndex(where: { !$0.confident }) {
            segs = clauses.map { Seg(length: $0.length, cands: [$0.candidate]) }
            focus = k
        } else {
            segs = [Seg(length: n, cands: whole, expanded: true)]
            focus = 0
        }
        if debugMode {
            let ms = String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            let shown = (clauses ?? []).map { $0.confident ? $0.candidate.text : "【\($0.candidate.text)】" }.joined(separator: "|")
            log.notice("[debug] convert \(ms, privacy: .public)ms 「\(self.left, privacy: .public)」+\(self.text.convertTarget, privacy: .public) → \(shown, privacy: .public)")
        }
        showMarked(c)
    }

    /// Next/previous candidate of the focused clause; opens the list.
    private func step(_ delta: Int, _ c: IMKTextInput) {
        if !segs[focus].expanded { expand(focus) }
        let count = segs[focus].cands.count
        segs[focus].sel = (segs[focus].sel + delta + count) % count
        showMarked(c)
        showList(c)
    }

    /// Fetch the focused clause's full candidate list, converting it with both neighbours as context.
    private func expand(_ i: Int) {
        let list = candidates(for: i)
        var cands = [segs[i].shown]
        for x in list where !cands.contains(where: { $0.text == x.text }) { cands.append(x) }
        segs[i].cands = cands
        segs[i].sel = 0
        segs[i].expanded = true
    }

    /// Candidates that convert exactly clause `i`, best first.
    private func candidates(for i: Int) -> [Candidate] {
        let a = segs[..<i].map(\.length).reduce(0, +)
        let t = text.slice(a, a + segs[i].length)
        let l = left + segs[..<i].map(\.shown.text).joined()
        let r = segs[(i + 1)...].map(\.shown.text).joined()
        return engine.convert(t, left: l, right: r).candidates.filter { t.isCovered(by: $0) }
    }

    /// ←→: move focus. A whole-sentence clause opens up into its 文節 first.
    private func move(_ delta: Int, _ c: IMKTextInput) {
        if segs.count == 1, let cs = Engine.split(segs[0].shown, kanaCount: segs[0].length, alternatives: []), cs.count > 1 {
            segs = cs.map { Seg(length: $0.length, cands: [$0.candidate]) }
            focus = delta > 0 ? 0 : segs.count - 1
        } else {
            focus = max(0, min(segs.count - 1, focus + delta))
        }
        candidateWindow.hide()
        showMarked(c)
    }

    /// Shift+←→: move the boundary after the focused clause by one kana, then reconvert both sides.
    private func resize(_ delta: Int, _ c: IMKTextInput) {
        let i = focus
        guard segs[i].length + delta >= 1 else { return }
        if delta > 0 {
            guard i + 1 < segs.count else { return }  // already reaches the end
            segs[i + 1].length -= 1
            if segs[i + 1].length == 0 { segs.remove(at: i + 1) }
        } else if i + 1 < segs.count {
            segs[i + 1].length += 1
        } else {
            segs.append(Seg(length: 1, cands: segs[i].cands))  // placeholder, reconverted below
        }
        segs[i].length += delta
        for j in [i, i + 1] where j < segs.count {
            let list = candidates(for: j)
            if !list.isEmpty { segs[j].cands = list }
            segs[j].sel = 0
            segs[j].expanded = !list.isEmpty
        }
        showMarked(c)
        showList(c)
    }

    /// 1–9: choose for the focused clause, then go to the next one (or commit after the last).
    private func pick(_ k: Int, _ c: IMKTextInput) {
        guard k < segs[focus].cands.count else { return }
        segs[focus].sel = k
        candidateWindow.hide()
        if focus + 1 < segs.count {
            focus += 1
            showMarked(c)
        } else {
            commitAll(c)
        }
    }

    private func commitAll(_ c: IMKTextInput) {
        guard !text.isEmpty else { return }
        let out: String
        if segs.isEmpty {
            text = text.separated()
            out = text.convertTarget
        } else {
            segs.forEach { engine.commit($0.shown) }
            out = segs.map(\.shown.text).joined()
        }
        c.insertText(out, replacementRange: notFound)
        clear(c, erase: false)
    }

    private func cancelConversion(_ c: IMKTextInput) {
        segs = []
        candidateWindow.hide()
        showMarked(c)
    }

    /// `erase`: also clear the app's marked text. Skip it right after `insertText`, which already
    /// replaced it — that redundant `setMarkedText` crashed Ghostty inside AppKit.
    private func clear(_ c: IMKTextInput, erase: Bool = true) {
        reset()
        if erase {
            c.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        }
    }

    /// Forget the composition without touching the client.
    private func reset() {
        text = ComposingText()
        segs = []
        candidateWindow.hide()
        engine.endComposition()
    }

    // MARK: - Display

    private func showMarked(_ c: IMKTextInput) {
        let (s, caret) = markedString()
        c.setMarkedText(s, selectionRange: NSRange(location: caret, length: 0), replacementRange: notFound)
    }

    /// Marked text (kana, or clauses with the focused one thick-underlined) and the caret offset.
    private func markedString() -> (text: NSAttributedString, caret: Int) {
        let s = NSMutableAttributedString()
        var caret = 0
        if segs.isEmpty {
            s.append(NSAttributedString(string: text.convertTarget, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]))
            caret = s.length
        }
        for (i, seg) in segs.enumerated() {
            let style: NSUnderlineStyle = i == focus ? .thick : .single
            s.append(NSAttributedString(string: seg.shown.text, attributes: [.underlineStyle: style.rawValue, .markedClauseSegment: i]))
            if i == focus { caret = s.length }
        }
        return (s, caret)
    }

    /// Candidate list under the focused clause.
    private func showList(_ c: IMKTextInput) {
        let offset = segs[..<focus].map { $0.shown.text.utf16.count }.reduce(0, +)
        var r = NSRect.zero
        _ = c.attributes(forCharacterIndex: offset, lineHeightRectangle: &r)
        candidateWindow.show(segs[focus].cands.map(\.text), selected: segs[focus].sel, below: r)
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
        let raw = c.string(from: NSRange(location: end - n, length: n), actualRange: &actual) ?? ""
        // Current line only, leading blanks trimmed (as azooKey): earlier lines — a terminal's
        // scrollback above all — leak words, e.g. 「機能」 on the previous line turned 「きのうは」 into 機能は.
        let line = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        let s = String(line.drop(while: \.isWhitespace))
        log.notice("left context: \(s.count, privacy: .public) chars")  // count only unless debug mode
        if debugMode { log.notice("[debug] left context: 「\(s, privacy: .public)」") }
        return s
    }
}
