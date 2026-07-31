#!/bin/bash
# GPLv3の開示用に、エンジン統合部のソース一式を書き出す。
#
# SnapShogi本体のリポジトリはprivateのままにし、このスクリプトが生成した
# ディレクトリの中身だけを公開リポジトリへpushする。
# エンジン統合部を変更したら再実行して公開側を更新すること。
#
# 使い方: ./export_public_source.sh [出力先ディレクトリ]
#   省略時は ../build/public-engine-source
set -euo pipefail

cd "$(dirname "$0")"
ENGINE_DIR="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
OUT="${1:-$ENGINE_DIR/build/public-engine-source}"

rm -rf "$OUT"
mkdir -p "$OUT"

# GPLv3の「対応するソースコード」本体
cp "$ENGINE_DIR/build_ios.sh"   "$OUT/"
cp "$ENGINE_DIR/usi_bridge.cpp" "$OUT/"
cp "$ENGINE_DIR/README.md"      "$OUT/"
cp "$ENGINE_DIR/LICENSE"        "$OUT/"

# 参考公開: USI境界のアプリ側クライアント
cp "$REPO_ROOT/App/Core/USIEngine.swift" "$OUT/"

# 公開物にはエクスポート自体のスクリプトも含める（再現性のため）
cp "$ENGINE_DIR/export_public_source.sh" "$OUT/"

# 参照しているやねうら王のcommitを控える
COMMIT=$(grep -m1 '^YANEURAOU_COMMIT=' "$ENGINE_DIR/build_ios.sh" | cut -d'"' -f2)
cat > "$OUT/YANEURAOU_VERSION.txt" <<EOF
このソースがリンクするやねうら王のバージョン

リポジトリ: https://github.com/yaneurao/YaneuraOu
commit    : $COMMIT
ビルド構成: YANEURAOU_ENGINE_MATERIAL / MATERIAL_LEVEL=1（駒得評価版）
評価関数  : 同梱なし
定跡      : 同梱なし（BookFile=no_book）

build_ios.sh を実行すると、上記commitを自動でcloneしてビルドします。
EOF

echo "書き出し完了: $OUT"
ls -1 "$OUT"
echo
echo "次の手順:"
echo "  1. 公開リポジトリ（例: snap-shogi-engine）を作る"
echo "  2. 上記ディレクトリの中身をpushする"
echo "  3. そのURLを App/Features/About/AboutView.swift の engineSourceURL に設定する"
