#!/bin/bash
# やねうら王（駒得評価版）をiOS向け静的ライブラリとしてビルドする。
# 使い方: ./build_ios.sh [simulator|device]
#   simulator: iOSシミュレータ用（このMacはIntelなので x86_64）
#   device   : 実機用（arm64）
#
# ライセンス: このスクリプトは SnapShogi のエンジン統合部の一部で、GPLv3で提供される。
# 詳細は同ディレクトリの README.md と LICENSE を参照。
set -euo pipefail

cd "$(dirname "$0")"
MODE="${1:-simulator}"

# 参照するやねうら王のcommit。
# GPLv3の「対応するソースコード」は配布バイナリを再現できる必要があるため、
# HEADではなくcommitを固定する。更新する際はこの値だけを変更すること。
YANEURAOU_COMMIT="1308ab3803e0011979473296741e56a6981c46ba"
YANEURAOU_REPO="https://github.com/yaneurao/YaneuraOu.git"

# ソース未取得ならクローン（リポジトリにはやねうら王本体を含めない）
if [ ! -d YaneuraOu/source ]; then
    git clone "$YANEURAOU_REPO" YaneuraOu
fi

# 固定commitに合わせる（既存クローンが別commitを指していても揃える）
CURRENT_COMMIT=$(git -C YaneuraOu rev-parse HEAD 2>/dev/null || echo "")
if [ "$CURRENT_COMMIT" != "$YANEURAOU_COMMIT" ]; then
    echo "== やねうら王を固定commitへ合わせる: ${YANEURAOU_COMMIT:0:12} =="
    git -C YaneuraOu fetch --depth 1 origin "$YANEURAOU_COMMIT" 2>/dev/null \
        || git -C YaneuraOu fetch origin
    git -C YaneuraOu checkout --quiet "$YANEURAOU_COMMIT"
    # ソースが変わったので中間生成物を捨てる
    rm -rf build/obj-simulator build/obj-device
fi

if [ "$MODE" = "device" ]; then
    SDK=iphoneos
    TARGET=arm64-apple-ios17.0
    ARCH_FLAGS="-DIS_64BIT -DUSE_NEON=8"
    OUT=build/libyaneuraou-ios-arm64.a
else
    SDK=iphonesimulator
    TARGET=x86_64-apple-ios17.0-simulator
    ARCH_FLAGS="-DIS_64BIT -DUSE_SSE42 -msse4.2"
    OUT=build/libyaneuraou-sim-x86_64.a
fi

SYSROOT=$(xcrun -sdk $SDK --show-sdk-path)
CXX="xcrun -sdk $SDK clang++"

SRC=YaneuraOu/source
OBJ=build/obj-$MODE
mkdir -p "$OBJ" build

# Makefile の YANEURAOU_ENGINE_NNUE（標準NNUE型 halfKP256）構成と同じソース一覧。
# 評価関数は水匠5（App/Resources/Eval/nn.bin。fetch_suisho5.sh で取得）
SOURCES=(
    main.cpp types.cpp bitboard.cpp misc.cpp movegen.cpp position.cpp
    usi.cpp usioption.cpp thread.cpp tt.cpp movepick.cpp timeman.cpp
    memory.cpp engine.cpp search.cpp score.cpp benchmark.cpp tune.cpp
    book/book.cpp book/apery_book.cpp book/policybook.cpp
    book/makebook.cpp book/makebook2025.cpp
    extra/bitop.cpp extra/long_effect.cpp extra/sfen_packer.cpp
    mate/mate.cpp mate/mate1ply_without_effect.cpp
    mate/mate1ply_with_effect.cpp mate/mate_solver.cpp
    eval/evaluate_bona_piece.cpp eval/evaluate.cpp eval/evaluate_io.cpp
    eval/evaluate_mir_inv_tools.cpp eval/material/evaluate_material.cpp
    eval/nnue/evaluate_nnue.cpp eval/nnue/nnue_test_command.cpp
    eval/nnue/features/k.cpp eval/nnue/features/p.cpp eval/nnue/features/a2.cpp
    eval/nnue/features/half_kp.cpp eval/nnue/features/half_ka1.cpp
    eval/nnue/features/half_ka_hm1.cpp eval/nnue/features/half_ka2.cpp
    eval/nnue/features/half_ka_hm2.cpp eval/nnue/features/half_kp_vm.cpp
    eval/nnue/features/half_relative_kp.cpp eval/nnue/features/half_kpe9.cpp
    eval/nnue/features/pe9.cpp
    testcmd/unit_test.cpp testcmd/mate_test_cmd.cpp testcmd/normal_test_cmd.cpp
    engine/yaneuraou-engine/yaneuraou-search.cpp
)

# 2026-08-15: MATERIAL_LEVEL=4 から標準NNUE型（水匠5）へ変更。
# 同じ1秒思考での棋力を桁違いに上げるため（経緯は docs/エンジン棋力の検討.md）
CPPFLAGS="-std=c++17 -fno-exceptions -fno-rtti -fpermissive -O3 -ffast-math -DNDEBUG \
 -Wno-unused-parameter -D_LINUX -DUNICODE -DNO_EXCEPTIONS \
 -DYANEURAOU_ENGINE_NNUE -DTARGET_CPU=\"iOS\" \
 $ARCH_FLAGS -Dmain=yaneuraou_main \
 -target $TARGET -isysroot $SYSROOT"

# コンパイルフラグが前回と違ったら中間ファイルを全部捨てる。
# 差分ビルドはソースの新旧しか見ないため、フラグ変更（例: MATERIAL→NNUE）が
# 反映されず新旧混在の壊れたライブラリができる事故が実際にあった
FLAGS_FILE="$OBJ/.cppflags"
if [ ! -f "$FLAGS_FILE" ] || [ "$(cat "$FLAGS_FILE")" != "$CPPFLAGS" ]; then
    echo "== フラグが変わったので $OBJ をクリーンする =="
    rm -rf "$OBJ"
    mkdir -p "$OBJ"
    printf '%s' "$CPPFLAGS" > "$FLAGS_FILE"
fi

echo "== コンパイル ($MODE / $TARGET) =="
PIDS=()
for src in "${SOURCES[@]}"; do
    obj="$OBJ/$(echo "$src" | tr '/' '_' | sed 's/\.cpp$/.o/')"
    if [ ! -f "$obj" ] || [ "$SRC/$src" -nt "$obj" ]; then
        $CXX $CPPFLAGS -c "$SRC/$src" -o "$obj" &
        PIDS+=($!)
        # 8並列まで
        if [ ${#PIDS[@]} -ge 8 ]; then
            wait "${PIDS[0]}"; PIDS=("${PIDS[@]:1}")
        fi
    fi
done
# ブリッジ
$CXX $CPPFLAGS -c usi_bridge.cpp -o "$OBJ/usi_bridge.o" &
PIDS+=($!)
for pid in "${PIDS[@]}"; do wait "$pid"; done

echo "== アーカイブ =="
rm -f "$OUT"
xcrun -sdk $SDK libtool -static -o "$OUT" "$OBJ"/*.o 2>&1 | grep -v "has no symbols" || true
ls -lh "$OUT"
echo "完了: $OUT"
