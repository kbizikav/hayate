import Foundation
@_exported import KanaKanjiConverterModule

/// Runs every conversion on one serial queue, so the main thread (key handling)
/// never waits on LLM inference.
///
/// - `prefetch` is called on every keystroke: latest-only, stale requests are dropped.
/// - `convert` is called on Space: usually a cache hit from the last prefetch.
///
/// Two converters, because the engine keeps incremental lattice state per converter
/// and Zenzai/dictionary requests must not share it:
/// - `llm`:  Zenzai (zenz-v3.2). Context-aware top-1, but the engine turns typo correction off here.
///           Learning is OFF here: the engine lets learned words override the LLM, so a once-confirmed
///           「回答してください」 would beat 「冷凍肉を → 解凍」. Context decides the top-1 (user's choice).
/// - `dict`: dictionary Viterbi + classic typo correction + learning. ~3ms, alternatives (learned ones rank high).
public final class Engine: @unchecked Sendable {
    struct Request: Equatable {
        var text: ComposingText
        var left: String
        var right = ""
        static func == (a: Request, b: Request) -> Bool {
            a.text.convertTarget == b.text.convertTarget && a.left == b.left && a.right == b.right
        }
    }

    public struct Conversion {
        public var candidates: [Candidate]  // merged, best first
        public var llm: [Candidate]
        public var dict: [Candidate]
    }

    private let llm: KanaKanjiConverter?
    private let dict: KanaKanjiConverter
    private let queue = DispatchQueue(label: "hayate.engine", qos: .userInteractive)
    private let zenzURL: URL?
    private let memoryDir: URL
    private let textReplacer: TextReplacer
    public var inferenceLimit: Int

    private let lock = NSLock()
    private var latest: Request?  // guarded by lock
    private var cache: (Request, Conversion)?  // queue only

    public init(dictionaryURL: URL, zenzURL: URL?, memoryDir: URL, emojiURL: URL, inferenceLimit: Int = 5) {
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        self.dict = KanaKanjiConverter(dicdataStore: DicdataStore(dictionaryURL: dictionaryURL))
        self.llm = zenzURL.map { _ in KanaKanjiConverter(dicdataStore: DicdataStore(dictionaryURL: dictionaryURL)) }
        self.zenzURL = zenzURL
        self.memoryDir = memoryDir
        self.textReplacer = TextReplacer { emojiURL }
        self.inferenceLimit = inferenceLimit
    }

    /// Speculatively convert in the background. Never blocks.
    public func prefetch(_ text: ComposingText, left: String) {
        lock.withLock { latest = Request(text: text, left: left) }
        queue.async { [self] in
            // Coalesce: whichever block runs first takes the newest request; the rest no-op.
            guard let r = lock.withLock({ () -> Request? in defer { latest = nil }; return latest }) else { return }
            _ = run(r)
        }
    }

    /// Blocking conversion. Returns instantly when `prefetch` already handled this input.
    public func convert(_ text: ComposingText, left: String, right: String = "") -> Conversion {
        queue.sync { run(Request(text: text, left: left, right: right)) }
    }

    /// Experimental LLM-based typo correction (engine API, may change).
    public func typoCandidates(_ text: ComposingText, left: String) -> [ZenzaiTypoCandidate] {
        queue.sync {
            llm?.experimentalRequestTypoCorrection(
                leftSideContext: left, composingText: text,
                options: options(left: left, right: "", zenzai: true), inputStyle: .roman2kana
            ) ?? []
        }
    }

    public func commit(_ candidate: Candidate) {
        queue.async { [self] in
            dict.setCompletedData(candidate)
            dict.updateLearningData(candidate)
            llm?.setCompletedData(candidate)
        }
    }

    public func endComposition() {
        queue.async { [self] in
            dict.stopComposition()
            llm?.stopComposition()
            cache = nil
        }
    }

    public func saveLearning() {
        queue.async { [self] in dict.commitUpdateLearningData() }
    }

    /// Forget everything learned (memory and files).
    public func resetLearning() {
        queue.async { [self] in
            dict.resetMemory()
            cache = nil
        }
    }

    private func run(_ r: Request) -> Conversion {
        if let (key, result) = cache, key == r { return result }
        let d = dict.requestCandidates(r.text, options: options(left: r.left, right: r.right, zenzai: false)).mainResults
        let z = llm?.requestCandidates(r.text, options: options(left: r.left, right: r.right, zenzai: true)).mainResults ?? []
        let result = Conversion(candidates: llm == nil ? d : Self.merge(llm: z, dict: d), llm: z, dict: d)
        cache = (r, result)
        return result
    }

    /// LLM top-1 first (context-aware), then dictionary N-best (better alternatives), then the rest.
    static func merge(llm z: [Candidate], dict d: [Candidate]) -> [Candidate] {
        // ponytail: Zenzai skips typo correction, so a leftover ASCII letter in its top-1
        // ("ありがtぷ") means it choked on a typo; trust the dictionary's corrected result then.
        // Upgrade path: LLM typo correction via `typoCandidates`.
        let raw: (Candidate) -> Bool = { $0.text.contains { $0.isASCII && $0.isLetter } }
        var head = Array(z.prefix(1))
        if let z0 = z.first, let d0 = d.first, raw(z0), !raw(d0) { head = [d0] }
        var seen = Set<String>()
        return (head + d + z).filter { seen.insert($0.text).inserted }
    }

    private func options(left: String, right: String, zenzai: Bool) -> ConvertRequestOptions {
        let mode: ConvertRequestOptions.ZenzaiMode = zenzai ? zenzURL.map {
            .on(
                weight: $0,
                inferenceLimit: inferenceLimit,
                requestRichCandidates: false,  // rich mode only adds prefix/katakana variants; dict supplies alternatives
                personalizationMode: nil,
                versionDependentMode: .v3(.init(
                    leftSideContext: left.isEmpty ? nil : left,
                    rightSideContext: right.isEmpty ? nil : right,
                    enableAlignmentSeparator: true
                ))
            )
        } ?? .off : .off
        return ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: true,
            halfWidthKanaCandidate: true,
            learningType: zenzai ? .nothing : .inputAndOutput,  // see `llm` above
            memoryDirectoryURL: memoryDir,
            sharedContainerURL: memoryDir,
            textReplacer: textReplacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: mode,
            typoCorrectionMode: .enabled,  // .automatic means off on macOS
            metadata: .init(versionString: "Hayate")
        )
    }
}

/// A clause of a converted sentence: kana length + what is shown for it.
public struct Clause {
    public var length: Int
    public var candidate: Candidate
    public var confident: Bool
    public init(length: Int, candidate: Candidate, confident: Bool) {
        self.length = length
        self.candidate = candidate
        self.confident = confident
    }
}

public extension Engine {
    /// Cut `sentence` into 文節 by part of speech (content word + trailing particles/auxiliaries —
    /// the engine's own rule, see `isClauseBoundary`).
    ///
    /// Confidence: alternatives are the dictionary's candidates in engine order; those scored within
    /// `margin` of the first are compared with the sentence. Where they spell the same kana
    /// differently, the clauses holding the differing characters are unconfident.
    /// nil when the sentence's readings don't line up with the input (e.g. typo-corrected).
    static func split(_ sentence: Candidate, kanaCount n: Int, alternatives: [Candidate], margin: PValue = 2) -> [Clause]? {
        guard let sw = units(sentence, n) else { return nil }
        // clause index of each unit
        var clauseOf = [Int](), k = 0
        for (i, u) in sw.enumerated() {
            if i > 0, isClauseBoundary(sw[i - 1].element.rcid, u.element.lcid) { k += 1 }
            clauseOf.append(k)
        }
        var unsure = Array(repeating: false, count: k + 1)
        // Anchor on the first candidate: special ones (katakana, hiragana as-is) carry inflated scores.
        let anchor = alternatives.first?.value ?? 0
        for alt in alternatives where alt.text != sentence.text && abs(alt.value - anchor) <= margin {
            guard let aw = units(alt, n) else { continue }
            var p = 0
            for q in Set(sw.map(\.end)).intersection(aw.map(\.end)).sorted() {
                defer { p = q }
                let st = spelling(sw, p, q), at = spelling(aw, p, q)
                guard st != at else { continue }
                // differing characters of the sentence's text within [p, q)
                let pre = zip(st, at).prefix { $0 == $1 }.count
                let suf = zip(st.reversed(), at.reversed()).prefix { $0 == $1 }.count
                let lo = min(pre, max(st.count - 1, 0)), hi = max(lo + 1, st.count - min(suf, min(st.count, at.count) - pre))
                var off = 0
                for (i, u) in sw.enumerated() where u.start >= p && u.end <= q {
                    let len = u.element.word.count
                    if off < hi, off + len > lo { unsure[clauseOf[i]] = true }
                    off += len
                }
            }
        }
        return (0...k).map { c in
            let part = zip(sw, clauseOf).filter { $0.1 == c }.map(\.0)
            let len = part.map { $0.end - $0.start }.reduce(0, +)
            let cand = Candidate(
                text: part.map(\.element.word).joined(), value: sentence.value, composingCount: .surfaceCount(len),
                lastMid: part.last?.element.mid ?? 0, data: part.map(\.element)
            )
            return Clause(length: len, candidate: cand, confident: !unsure[c])
        }
    }

    /// Same rule as the engine's internal `DicdataStore.isClause` (word types: 0 prefix, 1 content,
    /// 2 particle/auxiliary, 3 BOS/EOS): a clause starts at a prefix or content word.
    static func isClauseBoundary(_ former: Int, _ latter: Int) -> Bool {
        let t = DicdataStore.wordTypes
        guard t.indices.contains(former), t.indices.contains(latter), t[former] != 3, t[latter] != 3 else { return false }
        return t[latter] <= 1 && t[former] != 0
    }

    /// A `data` element: the engine's unit (often several words, e.g. 「天気です」) with its kana span.
    private typealias Unit = (start: Int, end: Int, element: DicdataElement)

    private static func units(_ c: Candidate, _ n: Int) -> [Unit]? {
        var pos = 0, out = [Unit]()
        for e in c.data {
            out.append((pos, pos + e.ruby.count, e))
            pos += e.ruby.count
        }
        return pos == n && c.text == c.data.map(\.word).joined() ? out : nil
    }

    /// Text of the units inside kana range [a, b) (callers pass unit boundaries).
    private static func spelling(_ units: [Unit], _ a: Int, _ b: Int) -> String {
        units.filter { $0.start >= a && $0.end <= b }.map(\.element.word).joined()
    }
}

public extension ComposingText {
    /// Kana range [a, b) as its own input (romaji kept, so typo correction still applies).
    func slice(_ a: Int, _ b: Int) -> ComposingText {
        var t = self
        if a > 0 { t.prefixComplete(composingCount: .surfaceCount(a)) }
        _ = t.moveCursorFromCursorPosition(count: (b - a) - t.convertTargetCursorPosition)
        return t.prefixToCursorPosition()
    }

    /// Whether `c` converts all of this input.
    func isCovered(by c: Candidate) -> Bool {
        var r = self
        r.prefixComplete(composingCount: c.composingCount)
        return r.convertTarget.isEmpty
    }
}

/// Key input exactly as the IME feeds it (shared with bench so both test the same path).
public extension ComposingText {
    static let style = InputStyle.mapped(id: .defaultRomanToKana)

    /// Full-width intentions for ASCII symbols (Google IME defaults).
    /// Table from azooKey-Desktop, Copyright (c) 2025 Miwa Keita, MIT License: https://github.com/azooKey/azooKey-Desktop/blob/main/LICENSE
    private static let h2z: [Character: Character] = [
        "!": "！", "\"": "”", "#": "＃", "$": "＄", "%": "％", "&": "＆", "'": "’", "(": "（", ")": "）",
        "=": "＝", "~": "〜", "|": "｜", "`": "｀", "{": "『", "}": "』", "+": "＋", "*": "＊", "<": "＜",
        ">": "＞", "?": "？", "_": "＿", "-": "ー", "^": "＾", "\\": "＼", "@": "＠", "[": "「", "]": "」",
        ";": "；", ":": "：", ",": "、", ".": "。", "/": "・",
    ]

    mutating func type(_ ch: Character, shift: Bool = false) {
        insertAtCursorPosition([.init(piece: .key(intention: Self.h2z[ch], input: ch, modifiers: shift ? [.shift] : []), inputStyle: Self.style)])
    }

    mutating func type(_ s: String) { s.forEach { type($0) } }

    /// Conversion boundary: flushes pending romaji ("kon" → "こん"), as azooKey does on Space.
    func separated() -> ComposingText {
        guard input.last?.piece != .compositionSeparator else { return self }
        var t = self
        t.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: Self.style)])
        return t
    }
}
