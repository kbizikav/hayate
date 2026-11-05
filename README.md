<div align="center">

# Hayate

azooKey の 10 倍以上速い、macOS 用の local LLM 日本語入力です。

![powered by azooKey](https://img.shields.io/badge/powered%20by-azooKey-4c8bf5)
![macOS](https://img.shields.io/badge/macOS-14%2B-000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Metal-555?logo=apple)
![通信ゼロ](https://img.shields.io/badge/%E9%80%9A%E4%BF%A1-%E3%82%BC%E3%83%AD-2ea44f)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

## 速度

<table align="center">
  <tr><th></th><th>azooKey-Desktop</th><th>Hayate</th><th>差</th></tr>
  <tr><td>キー入力の待ち時間</td><td align="right">2.6 ms</td><td align="right">0.2 ms</td><td align="right">13 倍</td></tr>
  <tr><td>スペースを押してから変換が出るまで</td><td align="right">5.1 ms</td><td align="right">0.2 ms</td><td align="right">25 倍</td></tr>
</table>

<p align="center"><sub>中央値。M4 Max で、同じ変換エンジンとモデルを使って計測しました。</sub></p>

Hayate は local LLM (zenz) の変換をバックグラウンドで先に済ませておくので、キー入力が待たされません。

## 特長

- **文脈で選ぶ** — 「冷凍肉を」の後なら、かいとう は「解凍」
- **打ち間違いに強い** — `arigatpu` → ありがとうございます
- **迷った文節だけ選ぶ** — 確度の低い文節に、最初からフォーカス
- **完全オフライン** — 通信ゼロ。入力内容はログに残さない

## インストール

```sh
./build.sh install
```

システム設定の「キーボード」から入力ソースの編集を開き、日本語の中にある「日本語 (Hayate)」を追加してください。Hayate を更新したときは、起動中のアプリを再起動してから切り替えてください。

## 操作

| キー | 動作 |
|---|---|
| `Space` | 変換、次の候補 |
| `↑` `↓` | 候補を選ぶ |
| `←` `→` | 文節を移動 |
| `Shift` + `←` `→` | 文節の長さを変える |
| `1` から `9` | 番号で候補を選ぶ |
| `Enter` | 確定 |
| `Esc` | 取り消す |

メニューバーの「あ」から、学習データの消去とデバッグモードの切り替えができます。

## azooKey-Desktop との比較

変換エンジンは同じで、呼び出し方と操作部分が違います。

|  | azooKey-Desktop | Hayate |
|---|---|---|
| 1 位候補の決め方 | 学習を優先 | 文脈を優先 |
| 打ち間違いの補正 | local LLM 使用時は無効 | local LLM と併用 |
| 長文の変換 | 先頭の文節から順に確定 | 候補が分かれた文節に自動で移動 |
| 通信 | OpenAI 連携あり | なし |
| 機能 | 豊富 | 最小限 |

## 謝辞

Hayate は [azooKey](https://github.com/azooKey) の上に作られています。変換エンジン、辞書、かな漢字変換モデルの zenz は、すべて azooKey プロジェクトのものです。Hayate で作ったのは、エンジンの呼び出し方と IME の操作部分です。azooKey の開発者の方々に感謝します。

- [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)
- [azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage)
- [zenz-v3.2-small](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf)
- [azooKey-Desktop](https://github.com/azooKey/azooKey-Desktop)

## 開発

`Sources/HayateCore` が変換エンジン、`Sources/Hayate` が IME 本体、`Sources/bench` がベンチマークと回帰テストです。azooKey-Desktop との速度比較は次のコマンドで実行できます。

```sh
swift build -c release --product bench
D=.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary
.build/release/bench $D/azooKey_dictionary_storage/Dictionary \
  $D/azooKey_emoji_dictionary_storage/EmojiDictionary/emoji_all_E16.0.txt models/zenz.gguf --azookey
```

## ライセンス

[MIT](LICENSE)
