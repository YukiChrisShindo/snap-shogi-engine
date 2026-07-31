// SnapShogi エンジン統合部 — やねうら王をアプリ内エンジンとして起動するためのブリッジ。
//
// Copyright (C) 2026 SnapShogi
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// やねうら王本体は無改変で、ビルド時に -Dmain=yaneuraou_main で main() を
// リネームしてあるだけ。ここから通常の関数として呼び出す。
// アプリ側はこのC関数と、標準入出力に流れるUSIプロトコルのテキストだけを見る。

extern int yaneuraou_main(int argc, char* argv[]);

extern "C" int snapshogi_engine_start(void) {
    static char arg0[] = "yaneuraou";
    char* argv[] = { arg0, nullptr };
    return yaneuraou_main(1, argv);
}
