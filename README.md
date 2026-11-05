<div align="center">

# ⚡ Hayate

**azooKey の変換エンジンを、10 倍以上速く。**<br/>
local LLM 日本語入力 for macOS

![powered by azooKey](https://img.shields.io/badge/powered%20by-azooKey-4c8bf5)
![macOS](https://img.shields.io/badge/macOS-14%2B-000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Metal-555?logo=apple)
![通信ゼロ](https://img.shields.io/badge/%E9%80%9A%E4%BF%A1-%E3%82%BC%E3%83%AD-2ea44f)
![License](https://img.shields.io/badge/license-MIT-blue)

<br/>

<table align="center">
  <tr><th></th><th>azooKey-Desktop</th><th>Hayate</th><th></th></tr>
  <tr><td>キー入力の待ち</td><td align="right">2.6 ms</td><td align="right"><b>0.2 ms</b></td><td align="center"><b>13×</b></td></tr>
  <tr><td>スペース → 変換</td><td align="right">5.1 ms</td><td align="right"><b>0.2 ms</b></td><td align="center"><b>25×</b></td></tr>
</table>

<sub>中央値・M4 Max・同じ変換エンジンとモデルで計測</sub>

</div>

<br/>

## ⚡ なぜ速いか

local LLM の変換を、打鍵ごとに裏で先回りしておく。だからキー入力は止まらず、スペースを押した瞬間に結果が出る。

```mermaid
flowchart LR
  K["キー入力"] --> H["ひらがな表示"]
  K -. 裏で先回り .-> L["local LLM 変換"]
  S["スペース"] --> R["結果を即表示"]
  L --> R
```

## ✨ 速さだけじゃない

- **文脈で選ぶ** — 「冷凍肉を」の後なら、かいとう は「解凍」
- **打ち間違いに強い** — `arigatpu` → ありがとうございます
- **迷った文節だけ選ぶ** — 確度の低い文節に、最初からフォーカス
- **完全オフライン** — 通信ゼロ。入力内容はログに残さない

## 📦 はじめる

```sh
./build.sh install
```

**システム設定 → キーボード → 入力ソース → ＋ → 日本語 (Hayate)**

> 更新したら、起動中のアプリを再起動してから切り替えてください。

## ⌨️ 操作

| キー | 動作 |
|---|---|
| `Space` | 変換・次の候補 |
| `↑` `↓` | 候補を選ぶ |
| `←` `→` | 文節を移動 |
| `Shift` `←` `→` | 文節の長さを変える |
| `1`–`9` | 番号で選ぶ |
| `Enter` | 確定 |
| `Esc` | 取り消す |

メニューバーの「あ」から、学習データのクリアとデバッグモードを使えます。

## 🆚 azooKey-Desktop との違い

変換エンジンは同じ。呼び出し方と操作を作り直しています。

|  | azooKey-Desktop | **Hayate** |
|---|---|---|
| 1 位候補 | 学習が優先 | **文脈が優先** |
| 打ち間違い | local LLM 使用時はオフ | **local LLM と両立** |
| 長文 | 先頭から順に確定 | **迷った文節に自動フォーカス** |
| 通信 | OpenAI 連携あり | **完全オフライン** |
| 機能 | 豊富 | 最小限 |

## 💐 azooKey への感謝

Hayate は [azooKey](https://github.com/azooKey) の上に作られています。変換エンジン、辞書、かな漢字変換モデルの zenz は、すべて azooKey プロジェクトのものです。Hayate で作ったのは、エンジンの呼び出し方と IME の操作部分です。azooKey の開発者の方々に感謝します。

[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) · [azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage) · [zenz-v3.2-small](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) · [azooKey-Desktop](https://github.com/azooKey/azooKey-Desktop)

<details>
<summary><b>開発者向け</b></summary>

<br/>

| パス | 役割 |
|---|---|
| [`Sources/HayateCore`](Sources/HayateCore/Engine.swift) | 変換エンジン：先回り実行・候補マージ・文節分割 |
| [`Sources/Hayate`](Sources/Hayate) | IME 本体と候補ウィンドウ |
| [`Sources/bench`](Sources/bench/main.swift) | ベンチ兼回帰テスト |

```sh
swift build -c release --product bench
D=.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary
.build/release/bench $D/azooKey_dictionary_storage/Dictionary \
  $D/azooKey_emoji_dictionary_storage/EmojiDictionary/emoji_all_E16.0.txt models/zenz.gguf --azookey
```

`--azookey` は azooKey-Desktop 既定設定の呼び出し方との速度比較。`--probe "<左文脈>" "<ローマ字>"` で 1 文を調べられます。

</details>

## 📄 ライセンス

[MIT](LICENSE)
