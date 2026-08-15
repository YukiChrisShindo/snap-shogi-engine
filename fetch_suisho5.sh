#!/bin/bash
# 水匠5評価関数ファイル（NNUE halfKP256）を公式リリースから取得する。
#
# 取得元: https://github.com/yaneurao/YaneuraOu/releases/tag/suisho5
#   Suisho5.7z（約24MB）→ 展開して nn.bin（約64MB）
#
# nn.bin はリポジトリに入れない（YaneuraOu本体と同じ扱い。60MB超のバイナリを
# git履歴に積まないため）。このスクリプトが App/Resources/Eval/nn.bin に配置し、
# XcodeGenがアプリバンドルに同梱する。
#
# ライセンス: 水匠はGPLv3（やねうら王のGPLv3リリースの一部として配布されている。
# 詳細は docs/エンジンライセンス調査.md）。アプリ内のライセンス表記にも記載する。
set -euo pipefail

cd "$(dirname "$0")"

URL="https://github.com/yaneurao/YaneuraOu/releases/download/suisho5/Suisho5.7z"
DEST_DIR="../App/Resources/Eval"
DEST="$DEST_DIR/nn.bin"
# 展開に py7zr（MLTraining venv）を使う。macOS標準に7z展開ツールが無いため
PY="../MLTraining/.venv/bin/python"

if [ -f "$DEST" ]; then
    echo "既に存在します: $DEST（$(du -h "$DEST" | cut -f1)）"
    exit 0
fi

echo "== 水匠5をダウンロード =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -L --fail -o "$TMP/Suisho5.7z" "$URL"

echo "== 展開 =="
"$PY" - "$TMP" <<'EOF'
import sys
from pathlib import Path
import py7zr

tmp = Path(sys.argv[1])
with py7zr.SevenZipFile(tmp / "Suisho5.7z") as z:
    z.extractall(tmp)
# アーカイブ内のnn.binを探す（ディレクトリ階層は問わない）
hits = list(tmp.rglob("nn.bin"))
if not hits:
    raise SystemExit("エラー: アーカイブ内に nn.bin が見つかりません")
print(hits[0])
EOF
NN_BIN=$("$PY" -c "
from pathlib import Path
print(next(Path('$TMP').rglob('nn.bin')))
")

mkdir -p "$DEST_DIR"
mv "$NN_BIN" "$DEST"
echo "配置しました: $DEST（$(du -h "$DEST" | cut -f1)）"
