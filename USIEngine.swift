import Foundation
import OSLog

/// USIエンジンのエラー
enum USIEngineError: Error, LocalizedError {
    case timeout(waitingFor: String)
    /// エンジンに渡すと落ちる・壊れた結果を返す局面（玉が無い、二歩など）
    case unsafePosition(reason: String)

    var errorDescription: String? {
        switch self {
        case .timeout(let waitingFor):
            return "エンジンの応答がありません（\(waitingFor) 待ちでタイムアウト）"
        case .unsafePosition(let reason):
            return "この局面は解析できません: \(reason)"
        }
    }
}

/// アプリ内で動くやねうら王とUSIプロトコルで通信するブリッジ。
///
/// エンジンは専用スレッドで `snapshogi_engine_start()`（＝リネームしたmain関数）を実行し、
/// 標準入出力をパイプに差し替えて対話する（配線は `USIEngineTransport`）。
///
/// このactorが守っていること:
/// - **解析は一度に1本**。`analyze` が並行して呼ばれても順番に処理する。
///   以前は待ち手を「bestmoveで始まる行」で登録していたため、2本同時に走ると
///   最初の bestmove 行で両方が解決し、2本目が1本目の局面の答えを受け取っていた
/// - **キャンセル**に応じる。解析中の Task が取り消されたら `stop` を送り、
///   bestmove が返るまで待ってプロトコルの同期を保ってから CancellationError を投げる
/// - **エンジンが落ちる局面を渡さない**。玉が無い局面はNNUEの玉位置が盤外になり
///   SIGSEGVで落ちる（2026-09-02に実測）。エンジンは同一プロセスなのでアプリごと終了する。
///   UIを経由しない呼び出し（テスト等）も守るため、ここでも局面を検証する
actor USIEngine {
    static let shared = USIEngine()

    private let transport = USIEngineTransport()
    private static let logger = Logger(subsystem: "com.snapshogi.app", category: "engine")

    private var readerTask: Task<Void, Never>?
    private var prepared = false
    private var preparing: Task<Void, Error>?

    /// 応答行を待っている呼び出し。同じ接頭辞の待ち手が複数あっても、
    /// 1行につき先頭の1つだけを解決する（エンジンはコマンドを順番に処理するため）
    private struct Waiter {
        let id: UUID
        let prefix: String
        let continuation: CheckedContinuation<String, Error>
    }
    private var waiters: [Waiter] = []
    /// 直近の go 以降に受け取った info 行（読み筋・評価値の抽出用）
    private var infoLines: [String] = []

    /// 解析の直列化（1本ずつ）
    private var searching = false
    private var turnQueue: [CheckedContinuation<Void, Never>] = []

    // MARK: - 起動

    private func startIfNeeded() {
        guard readerTask == nil else { return }
        let lines = transport.start()
        readerTask = Task { [weak self] in
            for await line in lines {
                await self?.handle(line: line)
            }
        }
    }

    /// USIハンドシェイクとオプション設定（初回のみ）。
    /// 同時に呼ばれても握手は一度しか行わない
    func prepare() async throws {
        startIfNeeded()
        if prepared { return }
        if let preparing {
            try await preparing.value
            return
        }
        let task = Task { try await self.performPrepare() }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func performPrepare() async throws {
        send("usi")
        _ = try await waitFor(prefix: "usiok", timeout: 10)
        // 置換表64MB: 16MBは駒得評価時代の設定で、NNUEの探索には手狭
        // （読み直しが増えて同じ思考時間でも浅くなる）。定跡ファイルは無効化
        send("setoption name USI_Hash value 64")
        send("setoption name Threads value 2")
        send("setoption name BookFile value no_book")
        // NNUE評価関数（水匠5）はバンドル直下の nn.bin を読む
        // （XcodeGenがApp/Resources/Eval/nn.binをバンドル直下に配置する）。
        // FV_SCALE=24 は水匠5の推奨値（配布ページ記載）
        if let evalDir = Bundle.main.resourcePath {
            send("setoption name EvalDir value \(evalDir)")
            send("setoption name FV_SCALE value 24")
        }
        // isreadyで評価関数ファイル（約61MB）の読み込みが走るため、タイムアウトは長めに
        send("isready")
        _ = try await waitFor(prefix: "readyok", timeout: 30)
        prepared = true
    }

    // MARK: - 通信

    /// コマンドを1行送る（改行は付けなくてよい）
    func send(_ command: String) {
        startIfNeeded()
        transport.send(command)
    }

    /// 指定プレフィックスで始まる行が届くまで待つ
    private func waitFor(prefix: String, timeout: TimeInterval) async throws -> String {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, prefix: prefix, continuation: continuation))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.timeOut(waiterID: id, prefix: prefix)
            }
        }
    }

    private func timeOut(waiterID: UUID, prefix: String) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: USIEngineError.timeout(waitingFor: prefix))
    }

    private func handle(line: String) {
        if line.hasPrefix("info ") {
            infoLines.append(line)
        }
        if let index = waiters.firstIndex(where: { line.hasPrefix($0.prefix) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: line)
        }
    }

    // MARK: - 直列化

    private func acquireTurn() async {
        if !searching {
            searching = true
            return
        }
        await withCheckedContinuation { turnQueue.append($0) }
    }

    private func releaseTurn() {
        if turnQueue.isEmpty {
            searching = false
        } else {
            turnQueue.removeFirst().resume()
        }
    }

    // MARK: - 解析

    /// 局面を解析して最善手（USI表記。例: "7g7f"）を返す
    func bestMove(sfen: String, movetimeMs: Int = 1000) async throws -> String {
        try await analyze(sfen: sfen, movetimeMs: movetimeMs, multiPV: 1).bestMove
    }

    /// エンジンに渡してよい局面か検証する。問題があれば `unsafePosition` を投げる
    static func validateForEngine(sfen: String) throws -> Position {
        let position = try SFEN.parse(sfen)
        let issues = PositionValidator.validate(position)
        if let first = issues.first {
            throw USIEngineError.unsafePosition(reason: first.errorDescription ?? "\(first)")
        }
        return position
    }

    /// 局面を解析して、最善手＋候補手（MultiPV）＋読み筋＋評価値を返す。
    /// 呼び出し元の Task が取り消されたら探索を止めて CancellationError を投げる
    func analyze(sfen: String, movetimeMs: Int = 1000, multiPV: Int = 3) async throws -> AnalysisResult {
        let position = try Self.validateForEngine(sfen: sfen)
        try await prepare()
        try Task.checkCancellation()

        await acquireTurn()
        defer { releaseTurn() }

        send("setoption name MultiPV value \(multiPV)")
        infoLines.removeAll()
        send("position sfen \(sfen)")
        send("go movetime \(movetimeMs)")

        let timeout = TimeInterval(movetimeMs) / 1000 + 10
        let transport = self.transport
        // 取り消されたら stop を送る。bestmove は必ず返るので、そこまでは待って
        // 次の解析とプロトコルがずれないようにする
        let line = try await withTaskCancellationHandler {
            try await waitFor(prefix: "bestmove", timeout: timeout)
        } onCancel: {
            transport.send("stop")
        }
        try Task.checkCancellation()

        let parts = line.split(separator: " ")
        let best = parts.count >= 2 ? String(parts[1]) : ""

        // multipvごとに最後（最深）のinfo行を採用する
        var latest: [Int: PVLine] = [:]
        for infoLine in infoLines {
            if let parsed = USIInfoParser.parse(infoLine) {
                latest[parsed.multipv] = parsed
            }
        }
        return AnalysisResult(
            bestMove: best,
            lines: latest.values.sorted { $0.multipv < $1.multipv },
            sideToMove: position.sideToMove
        )
    }
}

/// エンジンスレッドとパイプの配線。行単位に切って順序どおりに流す。
///
/// プロセス全体のstdin/stdoutを乗っ取るため、エンジン起動後は標準出力への書き込み
/// （`print()` など）もエンジン応答として流れてくる。**アプリ側では `print()` を使わず
/// `os.Logger` を使うこと**（CLAUDE.md の規約）
final class USIEngineTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    /// アプリ → エンジン(stdin)
    private let commandPipe = Pipe()
    /// エンジン(stdout) → アプリ
    private let responsePipe = Pipe()
    private var lineBuffer = ""
    /// 差し替え前のstdout。テストランナー等がfd 1に依存しているため、
    /// 複製して生かしておき、エンジン出力もここへ転送する（ログにも残る）
    private var savedStdout: Int32 = -1

    /// エンジンを起動し、応答を1行ずつ流すストリームを返す（一度だけ呼ぶ）
    func start() -> AsyncStream<String> {
        lock.lock()
        defer { lock.unlock() }
        precondition(!started, "USIEngineTransport.start() は一度しか呼べません")
        started = true

        let (stream, continuation) = AsyncStream<String>.makeStream()

        // 標準入出力をパイプへ差し替えてからエンジンスレッドを起動する。
        // 元のstdoutは複製して維持する（fd 1の参照が消えると、テストランナーの
        // 出力パイプがEOFになりプロセス異常終了と誤認されるため）
        savedStdout = dup(STDOUT_FILENO)
        dup2(commandPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        dup2(responsePipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let savedStdout = self.savedStdout
        // readabilityHandler は FileHandle 側で直列に呼ばれるので、行の順序はここで保たれる
        responsePipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // 元のstdoutにも転送（Xcodeのログで確認できるように）
            if savedStdout >= 0 {
                data.withUnsafeBytes { _ = write(savedStdout, $0.baseAddress, $0.count) }
            }
            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            for line in self.splitLines(text) {
                continuation.yield(line)
            }
        }

        let thread = Thread {
            _ = snapshogi_engine_start()
            continuation.finish()
        }
        thread.name = "yaneuraou-engine"
        thread.stackSize = 8 << 20   // 探索の再帰が深いためスタックを広めに確保
        thread.start()
        return stream
    }

    func send(_ command: String) {
        if let data = (command + "\n").data(using: .utf8) {
            commandPipe.fileHandleForWriting.write(data)
        }
    }

    /// 受信テキストを行に分ける（途中で切れた行は次回に持ち越す）
    private func splitLines(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        lineBuffer += text
        var lines: [String] = []
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(..<newlineRange.upperBound)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
