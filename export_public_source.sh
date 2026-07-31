#!/bin/bash
# GPLv3の開示用に、エンジン統合部のソース一式を公開リポジトリへ反映する。
#
# SnapShogi本体のリポジトリはprivateのままにし、公開リポジトリ
# （snap-shogi-engine）にはこのスクリプトが選んだファイルだけを置く。
# エンジン統合部を変更したら再実行して公開側を更新すること。
#
# 使い方:
#   ./export_public_source.sh          # 公開リポジトリをcloneして差分を反映（コミットはするがpushは手動）
#   ./export_public_source.sh --push   # 反映してpushまで行う
#
# 注意: 出力先はこのスクリプトが管理する一時cloneであり、本体リポジトリの
# 作業ツリー内でgit操作をしてはいけない（.gitが無いディレクトリでgitを打つと
# 親の本体リポジトリに作用してしまう事故が実際に起きた）
set -euo pipefail

cd "$(dirname "$0")"
ENGINE_DIR="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
PUBLIC_REPO="https://github.com/YukiChrisShindo/snap-shogi-engine.git"
OUT="$ENGINE_DIR/build/public-engine-source"
DO_PUSH="${1:-}"

# 公開リポジトリのcloneを用意（既存cloneがあれば最新化）
if [ -d "$OUT/.git" ]; then
    git -C "$OUT" fetch -q origin
    git -C "$OUT" checkout -q main
    git -C "$OUT" reset -q --hard origin/main
else
    rm -rf "$OUT"
    git clone -q "$PUBLIC_REPO" "$OUT"
fi

# 公開対象ファイルを反映（.git以外を入れ替える）
find "$OUT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp "$ENGINE_DIR/build_ios.sh"   "$OUT/"
cp "$ENGINE_DIR/usi_bridge.cpp" "$OUT/"
cp "$ENGINE_DIR/README.md"      "$OUT/"
cp "$ENGINE_DIR/LICENSE"        "$OUT/"
cp "$REPO_ROOT/App/Core/USIEngine.swift" "$OUT/"
cp "$ENGINE_DIR/export_public_source.sh" "$OUT/"

# 参照しているやねうら王のcommitを控える
COMMIT=$(grep -m1 '^YANEURAOU_COMMIT=' "$ENGINE_DIR/build_ios.sh" | cut -d'"' -f2)
LEVEL=$(grep -oE 'MATERIAL_LEVEL=[0-9]+' "$ENGINE_DIR/build_ios.sh" | head -1 | cut -d= -f2)
cat > "$OUT/YANEURAOU_VERSION.txt" <<EOF
このソースがリンクするやねうら王のバージョン

リポジトリ: https://github.com/yaneurao/YaneuraOu
commit    : $COMMIT
ビルド構成: YANEURAOU_ENGINE_MATERIAL / MATERIAL_LEVEL=$LEVEL（駒得＋利き評価）
評価関数  : 同梱なし
定跡      : 同梱なし（BookFile=no_book）

build_ios.sh を実行すると、上記commitを自動でcloneしてビルドします。
EOF

# 変更が無ければ何もしない
if git -C "$OUT" diff --quiet && [ -z "$(git -C "$OUT" status --porcelain)" ]; then
    echo "公開リポジトリは最新です（変更なし）"
    exit 0
fi

git -C "$OUT" add -A
git -C "$OUT" -c user.name="Yuki Shindo" -c user.email="yuki.chris.shindo@gmail.com" \
    commit -q -m "エンジン統合部を本体リポジトリと同期"
echo "コミット済み: $(git -C "$OUT" log --oneline -1)"

if [ "$DO_PUSH" = "--push" ]; then
    git -C "$OUT" push -q origin main
    echo "pushしました: $PUBLIC_REPO"
else
    echo "pushするには: cd $OUT && git push origin main"
    echo "（または ./export_public_source.sh --push で再実行）"
fi
