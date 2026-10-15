#!/bin/bash
# 評価関数「つようら王11mini」（SFNN_ka2_4096_8_64_progress8）を公式配布元から取得する。
#
# 取得元: https://yaneurao.fanbox.cc/posts/12761272 （やねうら王プロジェクト、2026-10-14 公開）
#   TuyouraOu11mini-….7z（約5.6MB）→ 展開して nn.bin（約7.7MB）と progress.bin（約1MB）
#
# 2つとも必要。progress.bin は局面の進行度（序盤〜終盤）を判定するパラメーターで、
# nn.bin と同じフォルダから読み込まれる（無いと isready で失敗する）。
#
# ライセンス: nn.bin / progress.bin は MIT License（配布ページに明記。二次配布・商用利用可）。
# アプリ内のライセンス表記（AboutView）にも著作権表示と許諾文を載せている。
# エンジン本体（やねうら王）は従来どおり GPLv3。
#
# バイナリはリポジトリに入れない（YaneuraOu本体と同じ扱い）。このスクリプトが
# App/Resources/Eval/ に配置し、XcodeGenがアプリバンドル直下に同梱する。
set -euo pipefail

cd "$(dirname "$0")"

URL="https://storage.yaneu.com/yaneuraou/TuyouraOu11mini-SFNN_ka2_4096_8_64_progress8-epoch0010-20261003.7z"
DEST_DIR="../App/Resources/Eval"
# 配布物のハッシュ（2026-10-15 取得時）。ファイルが差し替わったら気づけるように照合する
NN_SHA256="45323c65135da65d6c2c364eea93a5af6a285c27ebfb07eab4afbe737ef74508"
PROGRESS_SHA256="a2d18f0564639c945b5d6469e9b437cd64a526ad4fbcef02ab1d8f547d08e5f1"
# 展開に py7zr（MLTraining venv）を使う。macOS標準に7z展開ツールが無いため
PY="../MLTraining/.venv/bin/python"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# 既に正しいファイルが揃っていれば何もしない。
# 旧評価関数（水匠5の nn.bin）が残っている場合はハッシュが違うので取り直す
if [ -f "$DEST_DIR/nn.bin" ] && [ -f "$DEST_DIR/progress.bin" ] \
    && [ "$(sha "$DEST_DIR/nn.bin")" = "$NN_SHA256" ] \
    && [ "$(sha "$DEST_DIR/progress.bin")" = "$PROGRESS_SHA256" ]; then
    echo "既に配置済みです: $DEST_DIR/nn.bin, progress.bin"
    exit 0
fi

echo "== つようら王11miniをダウンロード =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/archive" "$TMP/out"
curl -L --fail -o "$TMP/archive/eval.7z" "$URL"

echo "== 展開 =="
"$PY" -I -c "import py7zr, sys; py7zr.SevenZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$TMP/archive/eval.7z" "$TMP/out"

for name in nn.bin progress.bin; do
    if [ ! -f "$TMP/out/$name" ]; then
        echo "エラー: アーカイブ内に $name が見つかりません" >&2
        exit 1
    fi
done
if [ "$(sha "$TMP/out/nn.bin")" != "$NN_SHA256" ] \
    || [ "$(sha "$TMP/out/progress.bin")" != "$PROGRESS_SHA256" ]; then
    echo "エラー: 配布ファイルのハッシュが記録と違います（配布元で差し替えられた可能性）。" >&2
    echo "  中身を確認してから NN_SHA256 / PROGRESS_SHA256 を更新してください" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
mv "$TMP/out/nn.bin" "$DEST_DIR/nn.bin"
mv "$TMP/out/progress.bin" "$DEST_DIR/progress.bin"
echo "配置しました: $DEST_DIR/nn.bin（$(du -h "$DEST_DIR/nn.bin" | cut -f1)）, progress.bin"
