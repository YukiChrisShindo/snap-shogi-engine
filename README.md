# SnapShogi エンジン統合部（GPLv3）

iOSアプリ **SnapShogi** が将棋エンジン「やねうら王」を利用するための統合コード一式です。
GPLv3に基づき、このディレクトリの内容を公開しています。

## 使用しているエンジン

| | |
|---|---|
| エンジン | [やねうら王（YaneuraOu）](https://github.com/yaneurao/YaneuraOu) — © yaneurao |
| ライセンス | **GPLv3**（やねうら王はStockfish由来のため） |
| 参照commit | `1308ab3803e0011979473296741e56a6981c46ba`（2026-07-10） |
| ビルド構成 | `YANEURAOU_ENGINE_NNUE`（**標準NNUE型 halfKP256**） |
| 評価関数 | **水匠5**（© たややん, GPLv3）を同梱。取得は `fetch_suisho5.sh`（公式リリースから） |
| 定跡 | **同梱していません**（`BookFile=no_book` で無効化） |

**やねうら王本体のソースコードは改変していません。** ビルド時のコンパイルフラグのみを
iOS向けに変更しています（`-Dmain=yaneuraou_main` によるmain関数のリネームを含む）。
やねうら王のソースは上記commitを `git clone` して取得してください。取得は
`build_ios.sh` が自動で行います。

## エンジンとアプリの関係

エンジンは独立したモジュールとして扱い、**USIプロトコル（テキスト）** 経由でのみ
やり取りしています。アプリ側がエンジンの内部APIを直接呼ぶことはありません。

```
SnapShogi アプリ (Swift)
        │
        │  USIプロトコルのテキスト
        │  ("position sfen ..." / "go movetime 1000" → "bestmove 7g7f")
        │  ※ 標準入出力をパイプに差し替えて送受信
        ▼
snapshogi_engine_start()     ← usi_bridge.cpp（このディレクトリ）
        │
        ▼
yaneuraou_main()             ← やねうら王本体（無改変）
```

iOSは `fork`/`exec` による別プロセス起動を許可していないため、エンジンは
アプリと同一プロセス内の専用スレッドで動作します。通信経路はパイプ経由の
USIテキストのみです。

## ファイル

| ファイル | 内容 | ライセンス |
|---|---|---|
| `build_ios.sh` | やねうら王をiOS向け静的ライブラリ（シミュレータ用x86_64 / 実機用arm64）にビルドする | **GPLv3+** |
| `usi_bridge.cpp` | リネームしたmain関数を通常の関数として呼び出すCブリッジ | **GPLv3+** |
| `LICENSE` | GNU General Public License v3 全文 | — |
| `USIEngine.swift` | アプリ側のUSIクライアント（標準入出力の差し替え、コマンド送信、応答パース）。本体リポジトリでは `App/Core/USIEngine.swift` | 参考公開（下記） |

## ビルド方法

```bash
./build_ios.sh simulator   # iOSシミュレータ用（x86_64）
./build_ios.sh device      # 実機用（arm64）
```

やねうら王のソースが未取得なら自動でcloneし、上記の固定commitへcheckoutします。
成果物は `build/libyaneuraou-sim-x86_64.a` または `build/libyaneuraou-ios-arm64.a`。

アプリへのリンク時は **`-force_load` が必須**です。やねうら王のエンジンは静的
イニシャライザで自己登録するため、通常の `-l` 指定では実行時に
「Error: no engine entry point.」で停止します。

```
-lc++ -Wl,-force_load,/path/to/libyaneuraou-sim-x86_64.a
```

## ライセンス

**`build_ios.sh` と `usi_bridge.cpp` は GPLv3以降** で提供されます。全文は `LICENSE` を
参照してください。この2つはやねうら王を直接ビルド・呼び出すコードであり、GPLv3が
定める「対応するソースコード」（コンパイルを制御するスクリプトを含む）に当たります。

**`USIEngine.swift` は参考として公開**しているものです。これはUSI境界の**アプリ側**にある
クライアントコードで、エンジンとのやり取りが本当にパイプ経由のテキストだけであることを
第三者が検証できるように収録しています。SnapShogiアプリ本体はオープンソースではありません。

やねうら王本体の著作権は yaneurao 氏および Stockfish の各著作権者にあります。
配布元: https://github.com/yaneurao/YaneuraOu

## お問い合わせ

このエンジン統合部やライセンスに関するご指摘は、GitHubのIssueでお知らせください。
