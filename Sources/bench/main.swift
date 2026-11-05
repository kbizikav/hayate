// Latency + accuracy bench.  usage: bench <Dictionary dir> <emoji_all.txt> [zenz.gguf]
import Foundation
import HayateCore

let a = CommandLine.arguments
let dict = URL(fileURLWithPath: a[1]), emoji = URL(fileURLWithPath: a[2])
let zenz = a.count > 3 ? URL(fileURLWithPath: a[3]) : nil
let mem = ProcessInfo.processInfo.environment["HAYATE_MEMORY"].map { URL(fileURLWithPath: $0) }  // reuse a learning-data copy
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("hayate-bench-\(getpid())")

// (left context, romaji typed, expected). Some romaji contain deliberate typos.
let cases: [(String, String, String)] = [
    ("", "kisyanokisyagakisyadekisyasita", "記者の汽車が貴社で帰社した"),
    ("", "kyouhaiitenkidesune", "今日はいい天気ですね"),
    ("", "watasihanihongowohanasimasu", "私は日本語を話します"),
    ("この論文の誤字を", "kouseisuru", "校正する"),
    ("組織の", "kouseiwominaosu", "構成を見直す"),
    ("", "arigatpugozaimasu", "ありがとうございます"),      // typo: tp -> to
    ("", "konnnitiha", "こんにちは"),
    ("", "seikakunihenkansaretemanzokudesu", "正確に変換されて満足です"),
    ("", "nihon", "日本"),                                     // trailing n
    ("", "ra-menn.", "ラーメン。"),                             // symbols → full-width
]

func ms(_ f: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    f()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}
func pct(_ xs: [Double], _ p: Double) -> String {
    let s = xs.sorted()
    return String(format: "%.1f", s[min(s.count - 1, Int(Double(s.count) * p))])
}

// Clause-edit path used by the IME: convert only the first N kana, commit it, the rest stays.
do {
    let e = Engine(dictionaryURL: dict, zenzURL: zenz, memoryDir: mem, emojiURL: emoji)
    var t = ComposingText()
    t.type("kyouhaiitenkidesune")
    t = t.separated()
    var p = t
    _ = p.moveCursorFromCursorPosition(count: 3 - p.convertTargetCursorPosition)
    p = p.prefixToCursorPosition()
    let top = e.convert(p, left: "").candidates[0]
    var rest = t
    rest.prefixComplete(composingCount: top.composingCount)
    print("segment check: [\(p.convertTarget)] → \(top.text) + \(rest.convertTarget)")
    precondition(top.text == "今日" && rest.convertTarget == "はいいてんきですね", "clause edit broken")
    precondition(t.slice(3, 6).convertTarget == "はいい" && t.slice(9, 12).convertTarget == "ですね", "slice broken")

    // Google-style split: only the clause where close alternatives disagree is unconfident.
    func split(_ roman: String) -> [Clause] {
        var t = ComposingText()
        t.type(roman)
        t = t.separated()
        let r = e.convert(t, left: "")
        let s = r.candidates.first { t.isCovered(by: $0) }!
        let cs = Engine.split(s, kanaCount: t.convertTarget.count, alternatives: r.dict.filter { t.isCovered(by: $0) })!
        precondition(cs.map(\.candidate.text).joined() == s.text && cs.map(\.length).reduce(0, +) == t.convertTarget.count, "split loses text")
        return cs
    }
    let movie = split("kinouhatomodatitoeigawominiikimasita")
    let calm = split("watasihanihongowohanasimasu")
    print("split check: " + movie.map { $0.confident ? $0.candidate.text : "【\($0.candidate.text)】" }.joined(separator: "|"))
    precondition(movie.filter { !$0.confident }.map(\.candidate.text) == ["観に行きました"], "confidence moved")
    precondition(calm.allSatisfy(\.confident), "false alarm on a clear sentence")
}

// Context must beat learning: confirm 「回答してください」 3× (as during manual testing),
// then the same reading after 「冷凍肉を」 must still be 解凍 — with the learned one close behind.
if a.count > 4, a[4] == "--context" {
    let e = Engine(dictionaryURL: dict, zenzURL: zenz, memoryDir: mem, emojiURL: emoji)
    var t = ComposingText()
    t.type("kaitousitekudasai")
    t = t.separated()
    let ctx = "この冷凍肉を"
    let plain = e.convert(t, left: "").candidates
    print("no context     :", plain.prefix(3).map(\.text))
    for _ in 0..<3 {
        e.commit(plain[0])
        e.endComposition()
    }
    let learned = e.convert(t, left: "").candidates
    let withCtx = e.convert(t, left: ctx).candidates
    print("learned, no ctx:", learned.prefix(3).map(\.text))
    print("learned + ctx  :", withCtx.prefix(3).map(\.text))
    precondition(withCtx.first?.text == "解凍してください", "learning overrides context")
    precondition(withCtx.prefix(3).contains { $0.text == plain[0].text }, "learned candidate lost")
    print("context check: OK")
    exit(0)
}

// Clause split + confidence:  bench <dict> <emoji> <zenz> --segments <romaji>...
if a.count > 5, a[4] == "--segments" {
    let e = Engine(dictionaryURL: dict, zenzURL: zenz, memoryDir: mem, emojiURL: emoji)
    for roman in a[5...] {
        var t = ComposingText()
        t.type(roman)
        t = t.separated()
        let r = e.convert(t, left: "")
        let s = r.candidates.first { t.isCovered(by: $0) }!
        let alts = r.dict.filter { t.isCovered(by: $0) }
        print("\n\(t.convertTarget)")
        print("  LLM : \(r.llm.first?.text ?? "-")")
        for d in r.dict.filter({ t.isCovered(by: $0) }).prefix(3) { print("  dict: \(d.text)  \(String(format: "%.2f", d.value))") }
        if let cs = Engine.split(s, kanaCount: t.convertTarget.count, alternatives: alts) {
            print("  → " + cs.map { $0.confident ? $0.candidate.text : "【\($0.candidate.text)】" }.joined(separator: "|"))
        } else {
            print("  → (cannot align)")
        }
    }
    exit(0)
}

// Head-to-head with azooKey-Desktop's call pattern (its defaults, read from its source):
// one converter, Zenzai inferenceLimit 5, synchronous requestCandidates on every keystroke
// (live conversion), then Space = composition separator + requestRichCandidates.
if a.count > 4, a[4] == "--azookey" {
    let replacer = TextReplacer { emoji }
    func azooKey(_ left: String, rich: Bool) -> ConvertRequestOptions {
        ConvertRequestOptions(
            requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false, fullWidthRomanCandidate: true, learningType: .inputAndOutput,
            memoryDirectoryURL: mem, sharedContainerURL: mem, textReplacer: replacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: .on(weight: zenz!, inferenceLimit: 5, requestRichCandidates: rich, personalizationMode: nil,
                            versionDependentMode: .v3(.init(leftSideContext: left.isEmpty ? nil : left, enableAlignmentSeparator: true))),
            experimentalZenzaiPredictiveInput: true, typoCorrectionMode: .automatic, metadata: .init(versionString: "bench")
        )
    }
    func stats(_ xs: [Double]) -> String { "p50 \(pct(xs, 0.5)) ms / max \(pct(xs, 1)) ms" }

    let az = KanaKanjiConverter(dicdataStore: DicdataStore(dictionaryURL: dict))
    var warm = ComposingText()
    warm.type("tesuto")
    _ = az.requestCandidates(warm, options: azooKey("", rich: true))
    az.stopComposition()
    var azKey: [Double] = [], azSpace: [Double] = []
    for (left, roman, _) in cases {
        var t = ComposingText()
        for ch in roman {
            t.type(ch)
            azKey.append(ms { _ = az.requestCandidates(t, options: azooKey(left, rich: false)) })
        }
        let s = t.separated()
        azSpace.append(ms { _ = az.requestCandidates(s, options: azooKey(left, rich: true)) })
        az.stopComposition()
    }

    let e = Engine(dictionaryURL: dict, zenzURL: zenz, memoryDir: mem, emojiURL: emoji)
    _ = e.convert(warm.separated(), left: "")
    e.endComposition()
    var hKey: [Double] = [], hSpace: [Double] = []
    for (left, roman, _) in cases {
        var t = ComposingText()
        for ch in roman {
            hKey.append(ms { t.type(ch); e.prefetch(t.separated(), left: left) })  // all the main thread does
            Thread.sleep(forTimeInterval: 0.08)  // ~12 keys/s
        }
        hSpace.append(ms { _ = e.convert(t.separated(), left: left) })
        e.endComposition()
    }
    print("keystroke wait  azooKey \(stats(azKey))   Hayate \(stats(hKey))")
    print("Space → list    azooKey \(stats(azSpace))   Hayate \(stats(hSpace))")
    exit(0)
}

// Probe one input:  bench <dict> <emoji> <zenz> --probe <left> <romaji> [limit]
if a.count > 6, a[4] == "--probe" {
    let e = Engine(dictionaryURL: dict, zenzURL: zenz, memoryDir: mem, emojiURL: emoji, inferenceLimit: a.count > 7 ? Int(a[7])! : 5)
    var t = ComposingText()
    t.type(a[6])
    t = t.separated()
    _ = e.convert(t, left: a[5])  // warm
    e.endComposition()
    var c = [Candidate]()
    let tc = ms { c = e.convert(t, left: a[5]).candidates }
    print("convert \(String(format: "%.1f", tc))ms:", c.prefix(8).map(\.text).joined(separator: " / "))
    var typo = [ZenzaiTypoCandidate]()
    let tt = ms { typo = e.typoCandidates(t, left: a[5]) }
    print("typo \(String(format: "%.1f", tt))ms:", typo.prefix(5).map { "\($0.correctedInput)→\($0.convertedText) (\(String(format: "%.2f", $0.score)))" }.joined(separator: ", "))
    exit(0)
}

for limit in zenz == nil ? [0] : [0, 1, 5] {
    let e = Engine(dictionaryURL: dict, zenzURL: limit == 0 ? nil : zenz, memoryDir: mem, emojiURL: emoji, inferenceLimit: limit)
    var warm = ComposingText()
    warm.insertAtCursorPosition("てすと", inputStyle: .direct)
    let load = ms { _ = e.convert(warm, left: "") }
    e.endComposition()

    var perKey: [Double] = [], spaceWait: [Double] = [], ok = 0
    print("\n== zenzai inferenceLimit=\(limit) (0 = dictionary only)  first call \(String(format: "%.0f", load))ms")
    for (left, roman, expect) in cases {
        // 1) raw synchronous cost per keystroke (what azooKey pays on the main thread)
        var t = ComposingText()
        for ch in roman {
            t.type(ch)
            perKey.append(ms { _ = e.convert(t, left: left) })
        }
        e.endComposition()
        // 2) Hayate path: prefetch per key while typing at ~12 keys/s, then measure the Space wait
        t = ComposingText()
        for ch in roman {
            t.type(ch)
            e.prefetch(t.separated(), left: left)
            Thread.sleep(forTimeInterval: 0.08)
        }
        var top = [String]()
        spaceWait.append(ms { top = e.convert(t.separated(), left: left).candidates.prefix(3).map(\.text) })
        e.endComposition()
        let hit = top.first == expect
        if hit { ok += 1 }
        print("  \(hit ? "✓" : "✗") [\(left)]\(roman) → \(top.joined(separator: " / "))")
    }
    print("  per-key sync: p50 \(pct(perKey, 0.5))ms p90 \(pct(perKey, 0.9))ms max \(pct(perKey, 1))ms")
    print("  space wait (with prefetch): p50 \(pct(spaceWait, 0.5))ms max \(pct(spaceWait, 1))ms")
    print("  top1 accuracy: \(ok)/\(cases.count)")
}
