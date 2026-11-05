// Latency + accuracy bench.  usage: bench <Dictionary dir> <emoji_all.txt> [zenz.gguf]
import Foundation
import HayateCore

let a = CommandLine.arguments
let dict = URL(fileURLWithPath: a[1]), emoji = URL(fileURLWithPath: a[2])
let zenz = a.count > 3 ? URL(fileURLWithPath: a[3]) : nil
let mem = FileManager.default.temporaryDirectory.appendingPathComponent("hayate-bench-\(getpid())")

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
    let top = e.convert(p, left: "")[0]
    var rest = t
    rest.prefixComplete(composingCount: top.composingCount)
    print("segment check: [\(p.convertTarget)] → \(top.text) + \(rest.convertTarget)")
    precondition(top.text == "今日" && rest.convertTarget == "はいいてんきですね", "clause edit broken")
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
    let tc = ms { c = e.convert(t, left: a[5]) }
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
        spaceWait.append(ms { top = e.convert(t.separated(), left: left).prefix(3).map(\.text) })
        e.endComposition()
        let hit = top.first == expect
        if hit { ok += 1 }
        print("  \(hit ? "✓" : "✗") [\(left)]\(roman) → \(top.joined(separator: " / "))")
    }
    print("  per-key sync: p50 \(pct(perKey, 0.5))ms p90 \(pct(perKey, 0.9))ms max \(pct(perKey, 1))ms")
    print("  space wait (with prefetch): p50 \(pct(spaceWait, 0.5))ms max \(pct(spaceWait, 1))ms")
    print("  top1 accuracy: \(ok)/\(cases.count)")
}
