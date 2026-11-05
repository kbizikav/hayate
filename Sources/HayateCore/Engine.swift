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
        static func == (a: Request, b: Request) -> Bool {
            a.text.convertTarget == b.text.convertTarget && a.left == b.left
        }
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
    private var cache: (Request, [Candidate])?  // queue only

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
    public func convert(_ text: ComposingText, left: String) -> [Candidate] {
        queue.sync { run(Request(text: text, left: left)) }
    }

    /// Experimental LLM-based typo correction (engine API, may change).
    public func typoCandidates(_ text: ComposingText, left: String) -> [ZenzaiTypoCandidate] {
        queue.sync {
            llm?.experimentalRequestTypoCorrection(
                leftSideContext: left, composingText: text,
                options: options(left: left, zenzai: true), inputStyle: .roman2kana
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

    private func run(_ r: Request) -> [Candidate] {
        if let (key, result) = cache, key == r { return result }
        let d = dict.requestCandidates(r.text, options: options(left: r.left, zenzai: false)).mainResults
        let result = llm.map { Self.merge(llm: $0.requestCandidates(r.text, options: options(left: r.left, zenzai: true)).mainResults, dict: d) } ?? d
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

    private func options(left: String, zenzai: Bool) -> ConvertRequestOptions {
        let mode: ConvertRequestOptions.ZenzaiMode = zenzai ? zenzURL.map {
            .on(
                weight: $0,
                inferenceLimit: inferenceLimit,
                requestRichCandidates: false,  // rich mode only adds prefix/katakana variants; dict supplies alternatives
                personalizationMode: nil,
                versionDependentMode: .v3(.init(leftSideContext: left.isEmpty ? nil : left, enableAlignmentSeparator: true))
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
